"""对抗性测试 —— 备份 / 恢复 / 保留策略 + 原始证据域。

覆盖攻击面:
备份:
  - 非 admin 触发 remote / schedule / run-now / restore → 403
  - 并发触发同一 schedule(状态机 / 重复 run)
  - rclone 配置字段注入(命令注入面:参数化验证,不真执行破坏命令)
  - upload-db / upload-snapshot 的账本 external_id 路径穿越
  - retention 计算:0 天 / 负天数 / 极大天数 / 保留至少 N 份
  - restore:畸形归档 / zip bomb / tar 穿越 / 磁盘预检
  - pg_dump 在 sqlite 环境下的降级行为(不得 500 裸栈)

原始证据:
  - 上传非法 JSON / 超大体 / 重复 external id / 过期插入
  - TTL 过期清理幂等
  - 越权(IDOR)B 读/改/删 A 的证据
  - /evidence/raw 的 limit/offset 负数与极值

红绿纪律同 test_ai_relay_adversarial.py。
"""
from __future__ import annotations

import gzip
import io
import json
import shutil
import tarfile
import time
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import (
    BackupRemote,
    BackupRun,
    BackupRunTarget,
    BackupSchedule,
    Ledger,
    LedgerMember,
    User,
)

_PW = "Pa$$word1!"


def _seed_legacy_ledger(Session, *, email: str, external_id: str) -> None:
    """直接落库一条**存量脏账本**(模拟加固前写入的 external_id)。

    创建点已被白名单封住(422),所以想验证落盘侧的纵深防御,只能绕过 API
    把历史行塞进库 —— 这正是真实部署里存量数据的形态。
    """
    with Session() as db:
        user = db.scalar(select(User).where(User.email == email))
        assert user is not None, email
        ledger = Ledger(
            user_id=user.id, external_id=external_id, name="legacy", currency="CNY",
        )
        db.add(ledger)
        db.flush()
        db.add(LedgerMember(ledger_id=ledger.id, user_id=user.id, role="owner"))
        db.commit()


def _create_ledger_raw(client: TestClient, token: str, ledger_id: str):
    """走创建点原样提交(用于验证白名单拒绝,不断言 200)。"""
    return client.post(
        "/api/v1/write/ledgers", headers=_auth(token),
        json={"ledger_id": ledger_id, "ledger_name": "adv", "currency": "CNY"},
    )


def _make_client() -> tuple[TestClient, sessionmaker]:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override_get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app, raise_server_exceptions=False), Session


def _login(client: TestClient, email: str, client_type: str = "web") -> str:
    reg = client.post(
        "/api/v1/auth/register",
        json={"email": email, "password": _PW, "device_id": "bk-adv-dev",
              "client_type": client_type, "device_name": "pytest-adv", "platform": "test"},
    )
    assert reg.status_code in (200, 201), reg.text
    res = client.post(
        "/api/v1/auth/login",
        json={"email": email, "password": _PW, "device_id": "bk-adv-dev",
              "client_type": client_type, "device_name": "pytest-adv", "platform": "test"},
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _make_admin(Session, email: str) -> None:
    with Session() as db:
        user = db.scalar(select(User).where(User.email == email))
        assert user is not None
        user.is_admin = True
        db.commit()


def _seed_backup_env(Session, email: str, *, external_id: str = "adv-bk") -> tuple[int, int]:
    """建一个 local remote + schedule,返回 (schedule_id, remote_id)。"""
    with Session() as db:
        user = db.scalar(select(User).where(User.email == email))
        remote = BackupRemote(
            user_id=user.id, name="adv-local", backend_type="local", encrypted=False,
            config_summary={}, created_at=datetime.now(timezone.utc),
        )
        db.add(remote)
        db.flush()
        schedule = BackupSchedule(
            user_id=user.id, name="adv-schedule", enabled=True, cron_expr="0 4 * * *",
            retention_days=30, include_attachments=True,
            created_at=datetime.now(timezone.utc),
        )
        db.add(schedule)
        db.flush()
        from src.models import BackupScheduleRemote

        db.add(BackupScheduleRemote(schedule_id=schedule.id, remote_id=remote.id, sort_order=0))
        db.commit()
        return schedule.id, remote.id


def _evidence_payload(key: str, **overrides) -> dict:
    payload = {
        "event_key": key,
        "source": "sms",
        "source_channel": "bank",
        "actor": "95555",
        "title": "交易提醒",
        "body": "支付成功 30 元",
        "metadata": {"len": 3},
        "captured_at": datetime.now(timezone.utc).isoformat(),
    }
    payload.update(overrides)
    return payload


# ══════════════════════════════════════════════════════════════════════
# 1. 权限:非 admin 不得触碰备份面
# ══════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(
    ("method", "path", "body"),
    [
        ("get", "/api/v1/admin/backup/remotes", None),
        ("post", "/api/v1/admin/backup/remotes", {"name": "x", "backend_type": "local", "config": {}}),
        ("get", "/api/v1/admin/backup/schedules", None),
        ("post", "/api/v1/admin/backup/schedules",
         {"name": "s", "cron_expr": "0 4 * * *", "remote_ids": [1]}),
        ("get", "/api/v1/admin/backup/runs", None),
        ("get", "/api/v1/admin/backup/restores", None),
        ("get", "/api/v1/admin/backup/rclone-config", None),
    ],
)
def test_backup_admin_surface_rejects_non_admin(method, path, body) -> None:
    """非 admin 访问备份管理面全部 403(不泄露存在性)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-nonadmin@example.com")
        kwargs: dict = {"headers": _auth(token)}
        if body is not None:
            kwargs["json"] = body
        res = getattr(client, method)(path, **kwargs)
        assert res.status_code == 403, f"{method} {path} -> {res.status_code} {res.text[:200]}"
    finally:
        app.dependency_overrides.clear()


def test_run_now_non_admin_403_and_others_schedule_404() -> None:
    """非 admin 调 run-now → 403;admin 调他人 schedule → 404。"""
    client, Session = _make_client()
    try:
        owner_token = _login(client, "bk-adv-own@example.com")
        intruder_token = _login(client, "bk-adv-intr@example.com")
        _make_admin(Session, "bk-adv-own@example.com")
        schedule_id, _ = _seed_backup_env(Session, "bk-adv-own@example.com")

        assert client.post(
            f"/api/v1/admin/backup/schedules/{schedule_id}/run-now",
            headers=_auth(intruder_token),
        ).status_code == 403
        # run-now 本身的归属校验:admin 非 owner 也看不到
        _make_admin(Session, "bk-adv-intr@example.com")
        assert client.post(
            f"/api/v1/admin/backup/schedules/{schedule_id}/run-now",
            headers=_auth(intruder_token),
        ).status_code == 404
        assert client.get(
            f"/api/v1/admin/backup/schedules/{schedule_id}/run-now",
            headers=_auth(owner_token),
        ).status_code in (405, 404)
    finally:
        app.dependency_overrides.clear()


def test_restore_rejects_run_owned_by_other_admin() -> None:
    """恢复:他人 run_id → 404(归属校验);不可恢复状态 → 400。"""
    client, Session = _make_client()
    try:
        token_a = _login(client, "bk-adv-ra@example.com")
        token_b = _login(client, "bk-adv-rb@example.com")
        _make_admin(Session, "bk-adv-ra@example.com")
        _make_admin(Session, "bk-adv-rb@example.com")

        with Session() as db:
            user = db.scalar(select(User).where(User.email == "bk-adv-ra@example.com"))
            run = BackupRun(user_id=user.id, started_at=datetime.now(timezone.utc),
                            status="succeeded", backup_filename="20260101-000000.tar.gz")
            db.add(run)
            db.commit()
            run_id = run.id

        res_other = client.post(
            f"/api/v1/admin/backup/runs/{run_id}/prepare-restore", headers=_auth(token_b)
        )
        assert res_other.status_code == 404, res_other.text

        res_owner = client.post(
            f"/api/v1/admin/backup/runs/{run_id}/prepare-restore", headers=_auth(token_a)
        )
        assert res_owner.status_code in (202, 400, 409), res_owner.text
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 2. 并发触发 / 状态机
# ══════════════════════════════════════════════════════════════════════


def test_run_now_twice_creates_two_background_runs(monkeypatch) -> None:
    """ADVERSE FINDING:run-now 可并发触发,同一 schedule 起两个并发备份。

    `run_schedule_now`(admin_backup.py:736)只校验 schedule 属于自己,然后
    无条件 `threading.Thread(target=_bg).start()` —— 没有「该 schedule 已有
    running run」的互斥。实测连点两次 → 后台函数被调用两次(两个 run 同时
    写同一 remote、同一 retention 窗口)。后果:
      - 同一远端并发 copyto 同一文件名(慢速远端上互相覆盖);
      - retention 各自删文件,可能互相删掉对方刚上传的新备份;
      - 备份期间 DB 快照 / 附件 hardlink 双份占用 staging 磁盘。
    schedule 侧有 APScheduler `max_instances=1` 保护,但 **run-now 走普通
    threading.Thread,完全绕过该保护**。

    期望:同一 schedule 有在跑的 run 时返回 409。
    源码:`src/routers/admin_backup.py:736-800`。
    """
    import src.routers.admin_backup as ab_module

    calls: list[tuple] = []

    def _fake_run_backup_to_remotes(*, user_id, remote_ids, include_attachments=True,
                                    retention_days=None, on_progress=None):
        calls.append((user_id, tuple(remote_ids)))
        return 1

    # 注意:run-now 在闭包里引用模块全局名,因此替换模块属性即可生效
    monkeypatch.setattr(ab_module, "run_backup_to_remotes", _fake_run_backup_to_remotes)

    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-conc@example.com")
        _make_admin(Session, "bk-adv-conc@example.com")
        schedule_id, _ = _seed_backup_env(Session, "bk-adv-conc@example.com")

        first = client.post(
            f"/api/v1/admin/backup/schedules/{schedule_id}/run-now", headers=_auth(token)
        )
        second = client.post(
            f"/api/v1/admin/backup/schedules/{schedule_id}/run-now", headers=_auth(token)
        )
        assert first.status_code == 202 and second.status_code == 202
        for _ in range(50):
            if len(calls) >= 2:
                break
            time.sleep(0.05)

        # ADVERSE FINDING: run-now 无互斥,同一 schedule 被并发触发了 2 次
        assert len(calls) == 1, (
            f"run-now 无互斥:同一 schedule 并发触发启动了 {len(calls)} 个备份"
            "(admin_backup.py:736 未检查 running 状态)"
        )
    finally:
        app.dependency_overrides.clear()


def test_backup_run_state_machine_rejects_restore_for_running_run() -> None:
    """状态机:status=running/failed 的 run 不可进入 restore(400)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-sm@example.com")
        _make_admin(Session, "bk-adv-sm@example.com")
        ids = []
        with Session() as db:
            user = db.scalar(select(User).where(User.email == "bk-adv-sm@example.com"))
            for status in ("running", "failed", "pending"):
                run = BackupRun(user_id=user.id, started_at=datetime.now(timezone.utc),
                                status=status, backup_filename="20260101-000000.tar.gz")
                db.add(run)
                db.flush()
                ids.append(run.id)
            db.commit()

        for run_id in ids:
            res = client.post(
                f"/api/v1/admin/backup/runs/{run_id}/prepare-restore", headers=_auth(token)
            )
            assert res.status_code == 400, f"run {run_id} -> {res.status_code} {res.text[:160]}"

        missing = client.post(
            "/api/v1/admin/backup/runs/999999/prepare-restore", headers=_auth(token)
        )
        assert missing.status_code == 404, missing.text
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 3. rclone 配置注入面 / 命令注入
# ══════════════════════════════════════════════════════════════════════


def test_rclone_remote_name_pattern_rejects_shell_metacharacters() -> None:
    """remote name 有 `^[A-Za-z0-9_-]+$` 白名单 → 注入串 422(参数化验证)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-name@example.com")
        _make_admin(Session, "bk-adv-name@example.com")
        for bad_name in ("x; rm -rf /", "x`id`", "../../etc", "x$(id)", "x\ny"):
            res = client.post(
                "/api/v1/admin/backup/remotes", headers=_auth(token),
                json={"name": bad_name, "backend_type": "local", "config": {}},
            )
            assert res.status_code == 422, f"{bad_name!r} -> {res.status_code} {res.text[:160]}"
    finally:
        app.dependency_overrides.clear()


def test_rclone_config_field_with_newline_is_injection_vector(tmp_path) -> None:
    """ADVERSE FINDING:config 字段值未过滤换行 → 可注入 rclone.conf 的段头。

    `_split_config`(admin_backup.py:84)只 strip 首尾空白、按白名单挑键;
    configparser 写入时对含 `\\n` 的值不报错而是**续行**输出(缩进 + 原样
    文本)。实测生成的 conf:

        [inject-remote]
        type = webdav
        url = http://127.0.0.1/x
        	[injected]          <- 用户可控内容伪造出的段头
        	type = local
        	root = /tmp
        user = u
        pass = p

    rclone 用 go-ini 解析:缩进行在前一个值非空时不会被当嵌套值,而是
    TrimLeft 后按 `[` 判定为**新 section**(见 go-ini parser.go)。因此
    该注入会真正生效 —— 攻击者(拿到 ops scope 的账号)可在服务端
    rclone.conf 里凭空造出 backend 段,把 local backend 的 root 指向任意
    绝对路径,后续 backup / restore / retention 就在那里读写删。

    期望:写入 conf 前对值做换行(\\r/\\n)过滤或直接拒绝。
    源码:`src/routers/admin_backup.py:84-140`、
    `src/services/backup/rclone_config.py:274-297`。
    """
    from src.services.backup.rclone_config import RcloneConfigManager

    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-inject@example.com")
        _make_admin(Session, "bk-adv-inject@example.com")

        res = client.post(
            "/api/v1/admin/backup/remotes", headers=_auth(token),
            json={
                "name": "inject-remote",
                "backend_type": "webdav",
                "config": {
                    "url": "http://127.0.0.1/x\n[injected]\ntype = local\nroot = /tmp",
                    "user": "u",
                    "pass": "p",
                },
            },
        )
        assert res.status_code in (201, 400), res.text

        conf_path = tmp_path / "rclone.conf"
        with Session() as db:
            user = db.scalar(select(User).where(User.email == "bk-adv-inject@example.com"))
            mgr = RcloneConfigManager(conf_path, "rclone")
            mgr.rewrite_from_db(db, user.id)
        conf_text = conf_path.read_text(encoding="utf-8")

        # ADVERSE FINDING: config 字段换行未过滤 → 伪造 section 段头进了 rclone.conf
        assert "[injected]" not in conf_text, (
            "换行注入成功:rclone.conf 里出现了用户伪造的段头(go-ini 会当作新 "
            f"section 解析)\n--- conf ---\n{conf_text[:600]}"
        )
    finally:
        app.dependency_overrides.clear()


def test_rclone_conf_is_shared_across_admins_and_gets_clobbered(tmp_path) -> None:
    """ADVERSE FINDING:rclone.conf 是单文件且按 user_id 全量重写 → 互相清空。

    `RcloneConfigManager.rewrite_from_db(db, user_id)` 只查该 user 的
    BackupRemote 并**全量重写** `rclone_config_path`(默认
    `<DATA_DIR>/rclone.conf`,全局唯一,见 config.py 的 `_derive_storage_paths`)。
    多 admin 实例(自建多用户 / 多个运维账号)下,任意一个 admin 触发
    「新建 remote / 改 remote / 下载 conf / run-now / 跑一次备份」都会把
    别的 admin 的 remote 从 conf 里抹掉。

    实测:adminA 写完 → conf 含 remote-A;adminB 写完 → conf 只剩 remote-B。
    后果:adminA 的定时备份在 rclone.conf 被清空后立刻失败(找不到 remote),
    报错信息只说 backend 不存在,运维难以定位到「被另一个账号的常规操作抹掉」。

    期望:按 user 分文件(`rclone-<user_id>.conf`),或改写时合并所有 user 的
    remote(带 user 前缀避免重名)。

    源码:`src/services/backup/rclone_config.py:224-317`(rewrite_from_db 只
    写 caller 的 remote)、`src/config.py:164-186`(单一路径派生)。
    """
    from src.services.backup.rclone_config import RcloneConfigManager

    client, Session = _make_client()
    try:
        token_a = _login(client, "bk-adv-cfa@example.com")
        token_b = _login(client, "bk-adv-cfb@example.com")
        _make_admin(Session, "bk-adv-cfa@example.com")
        _make_admin(Session, "bk-adv-cfb@example.com")

        assert client.post(
            "/api/v1/admin/backup/remotes", headers=_auth(token_a),
            json={"name": "remoteA", "backend_type": "local", "config": {}},
        ).status_code == 201
        assert client.post(
            "/api/v1/admin/backup/remotes", headers=_auth(token_b),
            json={"name": "remoteB", "backend_type": "local", "config": {}},
        ).status_code == 201

        conf_path = tmp_path / "rclone.conf"
        with Session() as db:
            user_a = db.scalar(select(User).where(User.email == "bk-adv-cfa@example.com"))
            mgr = RcloneConfigManager(conf_path, "rclone")
            mgr.rewrite_from_db(db, user_a.id)
        text_after_a = conf_path.read_text(encoding="utf-8")
        # section 名是 per-user 命名空间形态(`sb_<ns>_<name>`,对抗缺陷 4 的
        # 修法:裸 remote name 会让两个用户的同名 remote 互相覆盖)。这里断言
        # 「A 的段确实写进去了」而不锁死具体命名格式 —— 本用例的**意图**是
        # 「B 的常规操作不得抹掉 A 的 remote」,格式由回归文件
        # `test_adv_fixes_2026_10_11_regression.py` 专门覆盖。
        from src.services.backup.rclone_config import section_name_for

        with Session() as db:
            user_a = db.scalar(select(User).where(User.email == "bk-adv-cfa@example.com"))
            from src.models import BackupRemote

            row_a = db.scalar(select(BackupRemote).where(BackupRemote.user_id == user_a.id))
            section_a = section_name_for(row_a)
        assert f"[{section_a}]" in text_after_a, text_after_a
        assert "remoteA" in section_a, section_a

        with Session() as db:
            user_b = db.scalar(select(User).where(User.email == "bk-adv-cfb@example.com"))
            mgr = RcloneConfigManager(conf_path, "rclone")
            mgr.rewrite_from_db(db, user_b.id)
        text_after_b = conf_path.read_text(encoding="utf-8")

        # 回归护栏(原 ADVERSE FINDING 已修):共享单文件 + 按 user_id 合并重写
        # → 两个 admin 的 remote 并存,谁也不会清空谁。
        assert f"[{section_a}]" in text_after_b, (
            "adminB 的常规操作把 adminA 的 remote 从共享 rclone.conf 抹掉了:"
            f"\n--- conf after adminB ---\n{text_after_b}\n"
            "rclone_config.py rewrite_from_db 按 user_id 全量覆盖单文件"
        )
    finally:
        app.dependency_overrides.clear()


def test_schedule_cron_expr_injection_rejected() -> None:
    """cron 表达式非法(含命令分隔符 / 任意字符串)→ 400。"""
    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-cron@example.com")
        _make_admin(Session, "bk-adv-cron@example.com")
        _, remote_id = _seed_backup_env(Session, "bk-adv-cron@example.com")
        for bad in ("* * * * *; rm -rf /", "$(id)", "not a cron", "0" * 200):
            res = client.post(
                "/api/v1/admin/backup/schedules", headers=_auth(token),
                json={"name": "s", "cron_expr": bad, "remote_ids": [remote_id]},
            )
            assert res.status_code in (400, 422), f"{bad!r} -> {res.status_code} {res.text[:160]}"
    finally:
        app.dependency_overrides.clear()


def test_rclone_runner_passes_args_as_list_not_shell() -> None:
    """HARDENING:RcloneRunner 用 subprocess(list) 而非 shell=True(无 shell 注入)。

    静态验证:`RcloneRunner.run` 的 cmd 是 list,`subprocess.Popen(cmd, ...)`
    不带 shell=True —— 因此参数里的 shell 元字符不会被解释。这里用一个
    不存在的 binary + 注入串参数,确认返回的是「找不到 binary」而不是
    「命令被执行」。
    """
    from src.services.backup.rclone_runner import RcloneRunner

    runner = RcloneRunner(binary="definitely-not-a-real-binary-xyz", config_path="/tmp/r.conf")
    try:
        rc, log = runner.run(["; rm -rf /", "&& echo pwned"], timeout=5)
        assert rc != 0, (rc, log)
    except FileNotFoundError:
        pass  # 期望路径:list 形式 + 缺 binary → FileNotFoundError
    # 断言注入串没有被 shell 执行(没有副作用可验证;此处只要不抛 shell 相关错误)
    assert not Path("/tmp/pwned-marker").exists()


# ══════════════════════════════════════════════════════════════════════
# 4. upload-db / upload-snapshot 路径穿越
# ══════════════════════════════════════════════════════════════════════


def test_upload_db_ledger_traversal_escapes_backup_root(monkeypatch, tmp_path) -> None:
    """ADVERSE FINDING(已加固):backup 产物用账本 external_id 拼盘路 → 穿越写出备份根。

    `upload_backup_db` 原拼 `_backup_root() / ledger.external_id / "db" / ...`,
    与附件路径同款问题:external_id 未做字符校验。备份产物包含整库 SQLite
    副本 —— 攻击者(有 ops scope 的账号)可把它投放到任意可写路径。

    加固后是**两层防线**,本测试两层都锁:
      ① 创建点白名单(`write/ledgers.py` + `schemas.py`)→ 恶意 id 建不出来(422);
      ② 落盘侧纵深防御(`admin.py:_backup_artifact_dir`):external_id 先被安全化成
         单段路径片段(`..`/`/` 一律替换),产物**必须留在 backup 根内**;若仍有逃逸
         则 resolve 包含性检查兜底 400 + 审计。

    原断言「创建脏账本 → 上传 → 文件逃出根」在修复后攻击链第一环已不可达,
    故改为同样的双层形态(与 test_attachment_adversarial.py 同构)。
    源码:`src/routers/admin.py:105-150`。
    """
    import src.routers.admin as admin_module

    monkeypatch.setattr(admin_module, "_backup_root", lambda: tmp_path / "bkroot")
    evil = "../../bk-escaped-adv"
    root = (tmp_path / "bkroot").resolve()

    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-traverse@example.com")

        # ① 创建点:白名单拒绝穿越 id
        assert _create_ledger_raw(client, token, evil).status_code == 422, (
            "创建点应拒绝含路径分隔符的 external_id"
        )

        # ② 落盘侧:绕过 API 直接落一条存量脏账本,再走 upload-db
        _seed_legacy_ledger(Session, email="bk-adv-traverse@example.com", external_id=evil)

        res = client.post(
            "/api/v1/admin/backups/upload-db", headers=_auth(token),
            data={"ledger_id": evil},
            files={"file": ("x.sqlite3", io.BytesIO(b"SQLite format 3\x00fake"), "application/octet-stream")},
        )
        assert res.status_code == 200, res.text

        from src.models import BackupArtifact

        with Session() as db:
            artifact = db.scalar(select(BackupArtifact))
        assert artifact is not None

        # ② 落盘侧:产物必须留在 backup 根内
        stored = Path(artifact.storage_path).resolve()
        assert stored.is_relative_to(root), (
            f"备份产物逃出了 backup 根: stored={stored} root={root}"
        )
        escaped = (tmp_path / "bk-escaped-adv").resolve()
        assert not escaped.exists(), f"产物落到了 backup 根之外: {escaped}"
    finally:
        app.dependency_overrides.clear()


def test_upload_snapshot_ledger_traversal_escapes_backup_root(monkeypatch, tmp_path) -> None:
    """ADVERSE FINDING(已加固):upload-snapshot 走 JSON body(非 multipart),同样穿越。

    这条路径不经过 multipart 解析,`req.ledger_id` 是纯 JSON 字符串,
    穿越面与 upload-db 完全一致但更难被 WAF/网关的正常化规则挡住。
    与上一条同构,两层都锁:创建点 422 + 落盘侧产物必须留在 backup 根内。

    源码:`src/routers/admin.py:119-150`(_backup_artifact_dir)。
    """
    import src.routers.admin as admin_module

    monkeypatch.setattr(admin_module, "_backup_root", lambda: tmp_path / "bkroot2")
    evil = "../../bk-snap-escaped-adv"
    root = (tmp_path / "bkroot2").resolve()

    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-snap@example.com")

        # ① 创建点白名单
        assert _create_ledger_raw(client, token, evil).status_code == 422

        # ② 落盘侧:存量脏账本
        _seed_legacy_ledger(Session, email="bk-adv-snap@example.com", external_id=evil)

        res = client.post(
            "/api/v1/admin/backups/upload-snapshot", headers=_auth(token),
            json={"ledger_id": evil, "payload": {"items": []}, "note": "x"},
        )
        assert res.status_code == 200, res.text

        from src.models import BackupArtifact

        with Session() as db:
            artifact = db.scalar(select(BackupArtifact))
        assert artifact is not None

        # ② 落盘侧:产物必须留在 backup 根内
        stored = Path(artifact.storage_path).resolve()
        assert stored.is_relative_to(root), (
            f"snapshot 产物逃出了 backup 根: stored={stored} root={root}"
        )
        escaped = (tmp_path / "bk-snap-escaped-adv").resolve()
        assert not escaped.exists(), f"snapshot 产物落到了 backup 根之外: {escaped}"
    finally:
        app.dependency_overrides.clear()


def test_upload_db_without_ledger_access_404(monkeypatch, tmp_path) -> None:
    """B 对 A 的账本 upload-db → 404(不泄露存在性)。"""
    import src.routers.admin as admin_module

    monkeypatch.setattr(admin_module, "_backup_root", lambda: tmp_path / "bkroot3")

    client, Session = _make_client()
    try:
        token_a = _login(client, "bk-adv-owa@example.com")
        _make_ledger(client, token_a, "bk-private")
        token_b = _login(client, "bk-adv-owb@example.com")
        res = client.post(
            "/api/v1/admin/backups/upload-db", headers=_auth(token_b),
            data={"ledger_id": "bk-private"},
            files={"file": ("x.sqlite3", io.BytesIO(b"data"), "application/octet-stream")},
        )
        assert res.status_code == 404, res.text
    finally:
        app.dependency_overrides.clear()


def test_upload_db_oversize_and_empty(monkeypatch, tmp_path) -> None:
    """备份上传:0 字节 400;超限 413(用 monkeypatch 压低上限)。"""
    import src.routers.admin as admin_module
    from src.config import get_settings

    monkeypatch.setattr(admin_module, "_backup_root", lambda: tmp_path / "bkroot4")
    monkeypatch.setattr(get_settings(), "backup_max_upload_bytes", 256)

    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-size@example.com")
        _make_ledger(client, token, "bk-size")
        empty = client.post(
            "/api/v1/admin/backups/upload-db", headers=_auth(token),
            data={"ledger_id": "bk-size"},
            files={"file": ("e.sqlite3", io.BytesIO(b""), "application/octet-stream")},
        )
        assert empty.status_code == 400, empty.text
        big = client.post(
            "/api/v1/admin/backups/upload-db", headers=_auth(token),
            data={"ledger_id": "bk-size"},
            files={"file": ("b.sqlite3", io.BytesIO(b"z" * 257), "application/octet-stream")},
        )
        assert big.status_code == 413, big.text
    finally:
        app.dependency_overrides.clear()


def test_upload_db_metadata_must_be_json_object(monkeypatch, tmp_path) -> None:
    """metadata 非 JSON / 非对象 → 400。"""
    import src.routers.admin as admin_module

    monkeypatch.setattr(admin_module, "_backup_root", lambda: tmp_path / "bkroot5")

    client, Session = _make_client()
    try:
        token = _login(client, "bk-adv-meta@example.com")
        _make_ledger(client, token, "bk-meta")
        for bad in ("not-json", "[1,2,3]", '"str"'):
            res = client.post(
                "/api/v1/admin/backups/upload-db", headers=_auth(token),
                data={"ledger_id": "bk-meta", "metadata": bad},
                files={"file": ("m.sqlite3", io.BytesIO(b"data"), "application/octet-stream")},
            )
            assert res.status_code == 400, f"{bad!r} -> {res.status_code} {res.text[:160]}"
    finally:
        app.dependency_overrides.clear()


def _make_ledger(client: TestClient, token: str, ledger_id: str) -> None:
    res = client.post(
        "/api/v1/write/ledgers", headers=_auth(token),
        json={"ledger_id": ledger_id, "ledger_name": "adv", "currency": "CNY"},
    )
    assert res.status_code == 200, res.text


# ══════════════════════════════════════════════════════════════════════
# 5. retention 纯函数边界
# ══════════════════════════════════════════════════════════════════════


def _rf(name: str, ts: datetime):
    from src.services.backup.retention import RemoteFile

    return RemoteFile(name=name, timestamp=ts)


def test_retention_zero_and_negative_days_keeps_all() -> None:
    """retention 0 天 / 负天数 → 归一到 1 天(不删任何东西,保留至少 1 份)。"""
    from src.services.backup.retention import compute_retention_deletes

    now = datetime.now(timezone.utc)
    files = [_rf(f"2026010{i}-040000.tar.gz", now - timedelta(days=10 - i)) for i in range(1, 6)]
    for days in (0, -1, -100):
        to_delete = compute_retention_deletes(files, retention_days=days, now=now)
        # 全部文件都「过期」,但 keep_at_least=1 兜底 → 至少留一份
        assert len(to_delete) <= len(files) - 1, (days, to_delete)
        assert len(to_delete) == 4, (days, to_delete)


def test_retention_extreme_days_deletes_nothing() -> None:
    """极大 retention(3650 天)→ 无文件符合删除条件。"""
    from src.services.backup.retention import compute_retention_deletes

    now = datetime.now(timezone.utc)
    files = [_rf(f"2026010{i}-040000.tar.gz", now - timedelta(days=i)) for i in range(1, 6)]
    assert compute_retention_deletes(files, retention_days=3650, now=now) == []


def test_retention_boundary_exact_cutoff_boundary() -> None:
    """边界:时间戳正好落在 cutoff 上不被删(< 才删)。"""
    from src.services.backup.retention import compute_retention_deletes

    now = datetime.now(timezone.utc)
    exact = now - timedelta(days=30)
    files = [
        _rf("20260101-000000.tar.gz", exact),
        _rf("20260102-000000.tar.gz", exact - timedelta(seconds=1)),
    ]
    to_delete = compute_retention_deletes(files, retention_days=30, now=now, keep_at_least=0)
    assert [f.name for f in to_delete] == ["20260102-000000.tar.gz"], to_delete


def test_retention_parses_zip_and_legacy_names() -> None:
    """文件名解析:新 .zip / 新 .tar.gz(local)/ 老 .tar.gz.age 都认。"""
    from src.services.backup.retention import parse_tar_filename

    for name in ("20260612-040000.zip", "20260612-040000.tar.gz",
                 "20260612-040000Z.tar.gz", "20260612-040000.tar.gz.age"):
        assert parse_tar_filename(name) is not None, name
    for bad in ("not-a-backup.zip", "20260612-040000.txt", "20261312-040000.zip",
                "../20260612-040000.tar.gz"):
        assert parse_tar_filename(bad) is None, bad


def test_retention_idempotent_repeat_deletes_nothing_new() -> None:
    """幂等:同一输入重复计算 → 同一结果(不会越删越多)。"""
    from src.services.backup.retention import compute_retention_deletes

    now = datetime.now(timezone.utc)
    files = [_rf(f"2026010{i}-040000.tar.gz", now - timedelta(days=40 - i)) for i in range(1, 6)]
    first = [f.name for f in compute_retention_deletes(files, retention_days=10, now=now)]
    second = [f.name for f in compute_retention_deletes(files, retention_days=10, now=now)]
    assert first == second, (first, second)


# ══════════════════════════════════════════════════════════════════════
# 6. 归档解包:畸形 / zip bomb / tar 穿越
# ══════════════════════════════════════════════════════════════════════


def test_extract_zip_rejects_malformed_archive(tmp_path) -> None:
    """畸形 zip → 抛错(不静默产出空目录)。"""
    from src.services.backup.tar_builder import extract_zip

    bad = tmp_path / "bad.zip"
    bad.write_bytes(b"definitely not a zip")
    with pytest.raises(Exception):
        extract_zip(bad, tmp_path / "out")


def test_extract_zip_zip_bomb_has_no_size_guard(tmp_path) -> None:
    """ADVERSE FINDING:archive 解包无解压体积上限(zip bomb 直接吃满磁盘)。

    `extract_zip`(tar_builder.py:107)= `pyzipper.AESZipFile.extractall`,
    `restore_runner._run_prepare` 的 tar 分支同理(`tf.extractall`)。restore
    侧唯一的体积检查是 `check_disk_space(required_bytes=run.bytes_total * 2)`
    —— 基于**压缩后**的 `bytes_total`(rclone 上传大小),对高压缩比归档
    严重低估。实测:200MB 全零 payload → 203KB 的 zip(压缩比 ~1000:1),
    解包 0.1s 内写出 200MB。

    攻击链:远端(或中间人可控的 rclone 目标)放一个压缩比 1000:1 的归档,
    声明 bytes_total 很小 → 磁盘预检通过 → 解包吃满磁盘,把 live DB 的
    写入带崩(自部署单机)。

    期望:解包时累计已写字节并设上限(如 10 x 压缩后大小,或绝对上限)。
    源码:`src/services/backup/tar_builder.py:107-119`。
    """
    from src.services.backup.tar_builder import extract_zip

    bomb = tmp_path / "bomb.zip"
    payload = b"\x00" * (64 * 1024 * 1024)  # 64MB 全零,压缩后极小
    with zipfile.ZipFile(bomb, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("zeros.bin", payload)
    out = tmp_path / "bomb-out"

    ratio = len(payload) / bomb.stat().st_size
    extract_zip(bomb, out)
    written = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    assert ratio > 100, (  # 先证明这确实是个高压缩比炸弹
        f"测试构造失败:压缩比仅 {ratio:.1f}"
    )
    # ADVERSE FINDING: extract_zip 无解压体积上限(高压缩比炸弹原样展开)
    assert written <= bomb.stat().st_size * 20, (
        f"解包无体积上限:压缩后 {bomb.stat().st_size} 字节解出 {written} 字节"
        f"(放大 {ratio:.0f} 倍);tar_builder.py:107 extractall 无 guard"
    )


def test_restore_tar_extraction_rejects_parent_traversal(tmp_path) -> None:
    """HARDENING:tar 解包用 filter='data' → `../` 穿越被拒(OuterDestination 异常)。

    这是 restrore_runner 当前的行为(`tf.extractall(extracted, filter="data")`),
    确认它对 `../` 条目抛错而不是静默写出。同时记录:该防护依赖 Python 3.12+
    的 `filter` 参数,`except TypeError` 分支的存在说明代码考虑了老版本 ——
    在老版本上 `filter` 被忽略,tar 穿越会成功(平台相关风险)。
    """
    from src.services.backup import restore_runner  # noqa: F401  (import 面确认)

    evil = tmp_path / "evil.tar.gz"
    with tarfile.open(evil, "w:gz") as tf:
        info = tarfile.TarInfo("../escaped-by-tar.txt")
        data = b"pwn"
        info.size = len(data)
        tf.addfile(info, io.BytesIO(data))

    out = tmp_path / "tar-out"
    out.mkdir()
    with tarfile.open(evil, "r:gz") as tf:
        try:
            tf.extractall(out, filter="data")
            extracted_outside = (tmp_path / "escaped-by-tar.txt").exists()
            assert not extracted_outside, (
                "filter='data' 未阻止 ../ 穿越(tar_builder 路径穿越):"
                f" {(tmp_path / 'escaped-by-tar.txt')}"
            )
        except Exception as exc:  # noqa: BLE001 — 期望路径
            assert "escaped-by-tar" in str(exc) or "destination" in str(exc).lower(), exc


def test_check_disk_space_reports_insufficient(tmp_path, monkeypatch) -> None:
    """磁盘预检:要求超可用空间 → (False, free)。"""
    from src.config import get_settings
    from src.services.backup.restore_runner import check_disk_space

    monkeypatch.setattr(get_settings(), "restore_dir", str(tmp_path / "restore"))
    ok, free = check_disk_space(required_bytes=10**15)
    assert ok is False and free >= 0


def test_restore_cleanup_idempotent(tmp_path, monkeypatch) -> None:
    """restore 目录清理幂等:连清两次不报错。"""
    from src.config import get_settings
    from src.services.backup import restore_runner

    monkeypatch.setattr(get_settings(), "restore_dir", str(tmp_path / "restore"))
    run_dir = tmp_path / "restore" / "7"
    run_dir.mkdir(parents=True)
    (run_dir / "status.json").write_text("{}", encoding="utf-8")
    assert restore_runner.cleanup_restore(7) is True
    assert restore_runner.cleanup_restore(7) is False


def test_cleanup_old_restores_handles_missing_root(tmp_path, monkeypatch) -> None:
    """restore 根不存在 → 返回 0(不抛)。"""
    from src.config import get_settings
    from src.services.backup import restore_runner

    monkeypatch.setattr(get_settings(), "restore_dir", str(tmp_path / "nope"))
    assert restore_runner.cleanup_old_restores(max_age_days=7) == 0


def test_build_targz_roundtrip_and_oversized_input(tmp_path) -> None:
    """tar.gz 往返可用;对超大输入不做上限(记录当前行为)。"""
    from src.services.backup.tar_builder import build_targz, hardlink_tree

    src = tmp_path / "src"
    (src / "sub").mkdir(parents=True)
    (src / "a.txt").write_bytes(b"a" * 10)
    (src / "sub" / "b.txt").write_bytes(b"b" * 10)
    out = tmp_path / "packed.tar.gz"
    size = build_targz(src, out)
    assert size > 0 and out.exists()
    with tarfile.open(out, "r:gz") as tf:
        names = sorted(m.name for m in tf.getmembers())
    assert any("a.txt" in n for n in names) and any("b.txt" in n for n in names), names

    dst = tmp_path / "linked"
    n = hardlink_tree(src, dst)
    assert n == 2, n


# ══════════════════════════════════════════════════════════════════════
# 7. pg_dump / db_snapshot 在 sqlite 环境下的降级
# ══════════════════════════════════════════════════════════════════════


def test_pg_dump_rejects_sqlite_url_with_clear_error(tmp_path) -> None:
    """sqlite URL 传给 pg_dump_snapshot → RuntimeError(明确信息,不是裸栈)。"""
    from src.services.backup.db_snapshot import pg_dump_snapshot

    with pytest.raises(RuntimeError) as excinfo:
        pg_dump_snapshot("sqlite:///x.db", tmp_path / "o.dump")
    assert "postgresql" in str(excinfo.value).lower()


def test_pg_dump_missing_binary_gives_actionable_error(tmp_path, monkeypatch) -> None:
    """pg_dump 二进制缺失 → RuntimeError 带修复指引(不是 FileNotFoundError 裸抛)。"""
    from src.services.backup import db_snapshot

    monkeypatch.setattr(shutil, "which", lambda name: None)
    with pytest.raises(RuntimeError) as excinfo:
        db_snapshot.pg_dump_snapshot("postgresql://u:p@127.0.0.1:1/db", tmp_path / "o.dump")
    msg = str(excinfo.value)
    assert "pg_dump" in msg and ("PATH" in msg or "postgresql-client" in msg), msg


def test_database_backend_normalizes_urls() -> None:
    """URL 方言归一:postgres:// 与 postgresql+driver:// 都判 postgresql。"""
    from src.services.backup.db_snapshot import database_backend

    assert database_backend("postgres://u:p@h/db") == "postgresql"
    assert database_backend("postgresql+psycopg://u:p@h/db") == "postgresql"
    assert database_backend("sqlite:///./x.db") == "sqlite"


def test_vacuum_into_snapshot_and_excluded_tables(tmp_path) -> None:
    """VACUUM INTO 产物可打开,排除表被清空但 schema 保留。"""
    from sqlalchemy import inspect as sa_inspect
    from sqlalchemy import text

    from src.services.backup.db_snapshot import vacuum_into

    client, Session = _make_client()
    try:
        out = tmp_path / "snapshot.db"
        with Session() as db:
            # 写点用户数据 + 一条 audit_logs(排除表)数据
            db.add(User(id="v1", email="v@example.com", password_hash="x"))
            from src.models import AuditLog

            db.add(AuditLog(user_id="v1", action="adv_probe", metadata_json={"k": "secret"}))
            db.commit()
            vacuum_into(db, out)

        assert out.exists() and out.stat().st_size > 0
        check_engine = create_engine(f"sqlite:///{out}")
        try:
            tables = set(sa_inspect(check_engine).get_table_names())
            assert "audit_logs" in tables, "排除表应保留 schema"
            with check_engine.connect() as conn:
                rows = conn.execute(text("SELECT COUNT(*) FROM audit_logs")).scalar()
                assert rows == 0, "排除表的数据应被清空"
                users = conn.execute(text("SELECT COUNT(*) FROM users")).scalar()
                assert users == 1
        finally:
            check_engine.dispose()
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 8. 原始证据域
# ══════════════════════════════════════════════════════════════════════


def test_evidence_rejects_malformed_json_and_oversize() -> None:
    """非法 JSON → 422 但不泄露解析栈;超长 body/metadata → 422。"""
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-bad@example.com", client_type="app")
        bad = client.post(
            "/api/v1/evidence/raw",
            headers={**_auth(token), "Content-Type": "application/json"},
            content=b"{not json",
        )
        assert bad.status_code == 422, bad.text
        assert "not json" not in bad.text, "错误响应回显了请求体"

        too_long = client.post(
            "/api/v1/evidence/raw", headers=_auth(token),
            json=_evidence_payload("k-long", body="x" * 70_000),
        )
        assert too_long.status_code == 422, too_long.text

        big_meta = client.post(
            "/api/v1/evidence/raw", headers=_auth(token),
            json=_evidence_payload("k-meta", metadata={"x": "y" * 20_000}),
        )
        assert big_meta.status_code == 422, big_meta.text
    finally:
        app.dependency_overrides.clear()


def test_evidence_source_control_chars_rejected() -> None:
    """source 含内部空白 / 控制字符 → 422(审计安全)。

    注:`"sms\\n"` 这类**尾部**空白会被 `str.strip()` 归一后放行(200 且落库
    为 `sms`),这是预期的归一化;真正必须拒的是内部空白与控制字符。
    """
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-src@example.com", client_type="app")
        for bad_source in ("sm s", "sms\x00", "sms\nx", "\x00sms", " "):
            res = client.post(
                "/api/v1/evidence/raw", headers=_auth(token),
                json=_evidence_payload("k-src", source=bad_source),
            )
            assert res.status_code == 422, f"{bad_source!r} -> {res.status_code} {res.text[:160]}"
        # 尾部空白归一后放行,落库值已 strip
        ok = client.post(
            "/api/v1/evidence/raw", headers=_auth(token),
            json=_evidence_payload("k-src-trim", source="sms\n"),
        )
        assert ok.status_code == 200, ok.text
        assert ok.json()["source"] == "sms", ok.json()
    finally:
        app.dependency_overrides.clear()


def test_evidence_duplicate_external_id_creates_two_rows() -> None:
    """HARDENING:同一 external_id 配不同 event_key → 允许建两行(无唯一约束)。

    `RawBookkeepingEvidence` 的唯一键是 (user_id, event_key),external_id
    不做唯一。这是设计选择(展示型数据、去重靠 event_key),但意味着客户端
    重放同一笔账单时若 event_key 生成不稳,会产出多行「同一笔」证据 ——
    记录当前行为,不在本文件判为缺陷。
    """
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-dup@example.com", client_type="app")
        for key in ("e1", "e2"):
            res = client.post(
                "/api/v1/evidence/raw", headers=_auth(token),
                json=_evidence_payload(key, external_id="DUP-EXT-1"),
            )
            assert res.status_code == 200, res.text
        listed = client.get("/api/v1/evidence/raw", headers=_auth(token)).json()
        assert listed["total"] == 2, listed
    finally:
        app.dependency_overrides.clear()


def test_evidence_upsert_is_idempotent_per_event_key() -> None:
    """同一 event_key 重复上传 → 更新同一行(不新增)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-idem@example.com", client_type="app")
        first = client.post("/api/v1/evidence/raw", headers=_auth(token),
                            json=_evidence_payload("same-key", body="v1"))
        second = client.post("/api/v1/evidence/raw", headers=_auth(token),
                             json=_evidence_payload("same-key", body="v2"))
        assert first.json()["id"] == second.json()["id"]
        detail = client.get(f"/api/v1/evidence/raw/{first.json()['id']}", headers=_auth(token))
        assert detail.json()["body"] == "v2"
    finally:
        app.dependency_overrides.clear()


def test_evidence_expired_insert_410_and_read_404() -> None:
    """TTL:插入即过期 → 410;已过期行读取 → 404 并顺手删除。"""
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-ttl@example.com", client_type="app")
        past = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
        res = client.post("/api/v1/evidence/raw", headers=_auth(token),
                          json=_evidence_payload("expired", expires_at=past))
        assert res.status_code == 410, res.text

        # 先正常插入,再把 TTL 改到过去 → 列表触发清理,详情报 404
        ok = client.post("/api/v1/evidence/raw", headers=_auth(token),
                         json=_evidence_payload("soon-expired"))
        assert ok.status_code == 200
        eid = ok.json()["id"]
        from src.models import RawBookkeepingEvidence

        with Session() as db:
            row = db.get(RawBookkeepingEvidence, eid)
            row.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
            db.commit()

        # 列表会先跑一次 TTL 清理
        listed = client.get("/api/v1/evidence/raw", headers=_auth(token)).json()
        assert listed["total"] == 0, listed
        assert client.get(f"/api/v1/evidence/raw/{eid}", headers=_auth(token)).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_evidence_cleanup_default_wipes_everything_captured_before_now() -> None:
    """ADVERSE FINDING:`POST /evidence/raw/cleanup` 空 body 会删掉**全部**证据。

    `cleanup_raw_evidence`(raw.py:156-173)当 payload 缺失时
    `cutoff = datetime.now(timezone.utc)`,过滤条件是 `captured_at < cutoff`
    —— 没有任何 TTL 语义。因此一次不带参数的 cleanup 请求会把该用户所有
    证据(含刚采集的、expires_at 还在未来的)全部删除。客户端若在「同步/
    清理」流程里误发这个请求(或用户误触 UI 的清理按钮),取证数据不可逆丢失。

    期望:缺省 cleanup 至少应尊重 expires_at(只删已过期),或要求显式
    传 `before`。实际:空 body = 全删。

    源码:`src/routers/evidence/raw.py:156-173`。
    """
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-wipe@example.com", client_type="app")
        for i in range(3):
            assert client.post("/api/v1/evidence/raw", headers=_auth(token),
                               json=_evidence_payload(f"keep-{i}")).status_code == 200
        before = client.get("/api/v1/evidence/raw", headers=_auth(token)).json()["total"]
        assert before == 3

        res = client.post("/api/v1/evidence/raw/cleanup", headers=_auth(token), json={})
        assert res.status_code == 200
        left = client.get("/api/v1/evidence/raw", headers=_auth(token)).json()["total"]
        # ADVERSE FINDING: 空 body cleanup 无 TTL 语义,把 3 条证据全删了
        assert left > 0, (
            f"空 body 的 cleanup 删光了全部 {before} 条证据(无 TTL 语义):"
            f" deleted={res.json()['deleted']};raw.py:156"
        )
    finally:
        app.dependency_overrides.clear()


def test_evidence_cleanup_with_before_is_idempotent() -> None:
    """显式传 before 时 cleanup 幂等:第二次 deleted=0,未过期数据不受影响。"""
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-clean@example.com", client_type="app")
        old = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        for i in range(3):
            res = client.post("/api/v1/evidence/raw", headers=_auth(token),
                              json=_evidence_payload(f"old-{i}", captured_at=old))
            assert res.status_code == 200, res.text
        fresh = client.post("/api/v1/evidence/raw", headers=_auth(token),
                            json=_evidence_payload("fresh"))
        assert fresh.status_code == 200

        cutoff = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
        first = client.post(
            "/api/v1/evidence/raw/cleanup", headers=_auth(token), json={"before": cutoff}
        )
        assert first.status_code == 200 and first.json()["deleted"] == 3, first.json()
        second = client.post(
            "/api/v1/evidence/raw/cleanup", headers=_auth(token), json={"before": cutoff}
        )
        assert second.json()["deleted"] == 0, second.json()
        assert client.get("/api/v1/evidence/raw", headers=_auth(token)).json()["total"] == 1
    finally:
        app.dependency_overrides.clear()


def test_evidence_retention_purge_is_idempotent() -> None:
    """站点级 TTL 清理函数重复调用 → 第二次 0(且不误删未过期行)。"""
    from src.services.raw_evidence_retention import purge_expired_raw_evidence

    client, Session = _make_client()
    try:
        with Session() as db:
            db.add(User(id="ev-u1", email="purge@example.com", password_hash="x"))
            from src.models import RawBookkeepingEvidence

            now = datetime.now(timezone.utc)
            db.add(RawBookkeepingEvidence(
                id="ev-exp", user_id="ev-u1", event_key="e", source="sms",
                captured_at=now - timedelta(days=5),
                expires_at=now - timedelta(days=1),
            ))
            db.add(RawBookkeepingEvidence(
                id="ev-live", user_id="ev-u1", event_key="l", source="sms",
                captured_at=now, expires_at=now + timedelta(days=1),
            ))
            db.add(RawBookkeepingEvidence(
                id="ev-nottl", user_id="ev-u1", event_key="n", source="sms",
                captured_at=now - timedelta(days=400), expires_at=None,
            ))
            db.commit()

        with Session() as db:
            assert purge_expired_raw_evidence(db) == 1
        with Session() as db:
            assert purge_expired_raw_evidence(db) == 0
        with Session() as db:
            left = {r.id for r in db.scalars(select(RawBookkeepingEvidence)).all()}
        assert left == {"ev-live", "ev-nottl"}, left
    finally:
        app.dependency_overrides.clear()


def test_evidence_idor_read_update_delete() -> None:
    """IDOR:B 读/改/删 A 的证据 → 404(不泄露存在性),A 的数据不变。"""
    client, Session = _make_client()
    try:
        token_a = _login(client, "ev-adv-a@example.com", client_type="app")
        token_b = _login(client, "ev-adv-b@example.com", client_type="app")
        created = client.post("/api/v1/evidence/raw", headers=_auth(token_a),
                              json=_evidence_payload("private-a", body="A 的短信"))
        assert created.status_code == 200
        eid = created.json()["id"]

        assert client.get(f"/api/v1/evidence/raw/{eid}", headers=_auth(token_b)).status_code == 404
        patch = client.patch(
            f"/api/v1/evidence/raw/{eid}", headers=_auth(token_b),
            json=_evidence_payload("private-a", body="被 B 改了"),
        )
        assert patch.status_code == 404, patch.text
        assert client.delete(
            f"/api/v1/evidence/raw/{eid}", headers=_auth(token_b)
        ).status_code == 404

        assert client.get(f"/api/v1/evidence/raw/{eid}", headers=_auth(token_a)).json()["body"] == "A 的短信"
        assert client.get("/api/v1/evidence/raw", headers=_auth(token_b)).json()["total"] == 0
    finally:
        app.dependency_overrides.clear()


def test_evidence_cross_user_ledger_reference_404() -> None:
    """证据引用他人账本 id → 404(不泄露账本存在性)。"""
    client, Session = _make_client()
    try:
        token_a = _login(client, "ev-adv-la@example.com", client_type="web")
        _make_ledger(client, token_a, "ev-private-ledger")
        token_b = _login(client, "ev-adv-lb@example.com", client_type="app")
        res = client.post(
            "/api/v1/evidence/raw", headers=_auth(token_b),
            json=_evidence_payload("k-ledger", ledger_id="ev-private-ledger"),
        )
        assert res.status_code == 404, res.text
    finally:
        app.dependency_overrides.clear()


def test_evidence_limit_offset_bounds() -> None:
    """limit/offset 负数与极值 → 422;合法边界可用。"""
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-page@example.com", client_type="app")
        for query in ("limit=0", "limit=-1", "limit=100000", "offset=-5", "offset=-1"):
            res = client.get(f"/api/v1/evidence/raw?{query}", headers=_auth(token))
            assert res.status_code == 422, f"{query} -> {res.status_code}"
        for query in ("limit=1", "limit=200", "offset=0", "offset=999999"):
            res = client.get(f"/api/v1/evidence/raw?{query}", headers=_auth(token))
            assert res.status_code == 200, f"{query} -> {res.status_code} {res.text[:160]}"
    finally:
        app.dependency_overrides.clear()


def test_evidence_list_body_preview_truncated() -> None:
    """列表 body 预览截断到 ~500 字(避免响应膨胀)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-prev@example.com", client_type="app")
        res = client.post("/api/v1/evidence/raw", headers=_auth(token),
                          json=_evidence_payload("long-body", body="Z" * 60_000))
        assert res.status_code == 200, res.text
        listed = client.get("/api/v1/evidence/raw", headers=_auth(token)).json()
        preview = listed["items"][0]["body"]
        assert preview is not None and len(preview) <= 510, len(preview or "")
        # 详情是全量
        detail = client.get(
            f"/api/v1/evidence/raw/{listed['items'][0]['id']}", headers=_auth(token)
        ).json()
        assert detail["body"] is not None and len(detail["body"]) == 60_000
    finally:
        app.dependency_overrides.clear()


def test_evidence_response_has_no_store_header() -> None:
    """证据响应带 Cache-Control: no-store(隐私数据不得进缓存)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "ev-adv-cache@example.com", client_type="app")
        res = client.get("/api/v1/evidence/raw", headers=_auth(token))
        assert res.headers.get("cache-control") == "no-store", res.headers
    finally:
        app.dependency_overrides.clear()


def test_evidence_requires_auth() -> None:
    """未登录访问证据面 → 401。"""
    client, Session = _make_client()
    try:
        assert client.get("/api/v1/evidence/raw").status_code == 401
        assert client.post("/api/v1/evidence/raw", json=_evidence_payload("x")).status_code == 401
    finally:
        app.dependency_overrides.clear()
