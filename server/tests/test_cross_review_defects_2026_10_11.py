"""跨复核缺陷回归 —— 2026-10-11 终审确认的 4 个缺陷(data_cleanup / ai_config / sync payload)。

本文件是**回归护栏**:每个用例都对应一个经公开 HTTP API 复现确认、已修复的
缺陷。它们必须在修复前失败、修复后通过(每条 docstring 记录了「修复前的红」)。

- **P1 (安全, 任意文件删除)**:`POST /admin/data-cleanup/clean` 把客户端回传的
  `file_path`(以及 DB 的 `storage_path`)直接交给 `os.remove`,**没有**包含性
  校验。修复前实测:`{"type":"disk_file_no_row","file_path":"C:\\\\…\\\\victim.txt"}`
  → `200 {"success_count":1}` 且文件真的被删;`GET /data-cleanup/scan` 也会把
  出根 `storage_path` 当 `attachment_no_ref` 报出来,回传即删。
- **P2 (可用性)**:存量 `ai_config_json` 超过 `MAX_AI_CONFIG_BYTES`(CJK 字段
  可达 ~488 KiB)时,`DELETE /ai/providers/{id}` 与 `POST /ai/providers` 都因
  落库边界回 400 `AI_CONFIG_TOO_LARGE` —— 用户唯一自助出口只剩非显然的
  `PATCH /profile/me`。
- **P3 (单位错配)**:schema 的 `max_length` 数**字符**、存储上限数**字节**,
  CJK 下同一配置差 3 倍(503 KB > 文档的 256 KB)。现统一按字节判。
- **P4 (round-trip)**:`_strip_internal_payload_keys` / `_public_payload` 只处理
  **顶层** `__` 键 → `{"nested": {"__rawUpdatedAt": …}}` 被 /sync/pull 原样回显。
  现两侧递归剔除(显式栈,有界)。

可用 `python -m pytest tests/test_cross_review_defects_2026_10_11.py -q` 单跑。
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import AttachmentFile, User, UserProfile
from src.services.ai.ai_config_store import (
    AIConfigBoundsError,
    ai_config_json_bytes,
    enforce_ai_config_bounds,
)

_PW = "Pa$$word1!"
# 单列 TEXT 的列名(自愈 / 断言用)
_AI_CONFIG_ATTR = "ai_config_json"


def _make_client() -> tuple[TestClient, sessionmaker]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
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


def _register_web(client: TestClient, email: str) -> dict:
    res = client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": _PW,
            "client_type": "web",
            "device_name": f"{email}-dev",
            "platform": "test",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()


def _register_app(client: TestClient, email: str) -> dict:
    res = client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": _PW,
            "device_id": f"dev-{email}",
            "client_type": "app",
            "device_name": "pytest-app",
            "platform": "test",
        },
    )
    assert res.status_code == 200, res.text
    body = res.json()
    body["device_id"] = f"dev-{email}"
    return body


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _promote_admin(Session, user_id: str) -> None:
    with Session() as db:
        user = db.scalar(select(User).where(User.id == user_id))
        assert user is not None
        user.is_admin = True
        db.add(user)
        db.commit()


def _stored_ai_config(Session, email: str) -> str | None:
    with Session() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
        profile = db.scalar(select(UserProfile).where(UserProfile.user_id == uid))
        return None if profile is None else getattr(profile, _AI_CONFIG_ATTR)


def _provider(pid: str, *, api_key: str = "", name: str | None = None) -> dict:
    return {
        "id": pid,
        "name": name or f"P-{pid}",
        "isBuiltIn": False,
        "apiKey": api_key,
        "baseUrl": "https://api.example.com/v1",
        "textModel": "m",
        "visionModel": "m",
        "audioModel": "m",
        "protocol": "openai",
        "visionConcurrency": 3,
    }


# ══════════════════════════════════════════════════════════════════════
# P1 —— 清理器不得删除附件根之外的文件(客户端回传 file_path / DB storage_path)
# ══════════════════════════════════════════════════════════════════════


@pytest.fixture
def attach_root(tmp_path: Path, monkeypatch) -> Path:
    """把附件根指向 tmp_path 下的真实目录(测试与生产同"根内/根外"语义)。"""
    from src import config

    root = tmp_path / "attachments"
    root.mkdir()
    monkeypatch.setattr(config.get_settings(), "attachment_storage_dir", str(root))
    return root


def test_clean_disk_file_no_row_rejects_path_outside_root(
    attach_root: Path, tmp_path: Path
) -> None:
    """P1:客户端回传的**根外绝对路径**必须被拒(修复前:200 success_count=1 且文件消失)。

    修复后:该 record 记入 failures(错误串带被拒路径),受害文件原样存在。
    """
    client, Session = _make_client()
    try:
        auth = _register_web(client, "p1-escape@example.com")
        _promote_admin(Session, auth["user"]["id"])

        victim = tmp_path / "victim.txt"  # 在 attach_root 之外(兄弟目录)
        victim.write_text("SECRET", encoding="utf-8")

        res = client.post(
            "/api/v1/admin/data-cleanup/clean",
            headers=_auth(auth["access_token"]),
            json={
                "records": [
                    {
                        "type": "disk_file_no_row",
                        "title": "x",
                        "subtitle": "y",
                        "file_path": str(victim),
                    }
                ]
            },
        )
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["success_count"] == 0, f"根外路径不得算成功: {body}"
        assert len(body["failures"]) == 1, body
        # 拒绝原因要能让操作员看懂(带被拒路径)
        err = body["failures"][0]["error"]
        assert "victim.txt" in err, body
        assert "outside the attachment storage root" in err, body
        assert victim.exists(), "根外文件被删除了 —— 包含性校验失效"
        assert victim.read_text(encoding="utf-8") == "SECRET"
    finally:
        app.dependency_overrides.clear()


def test_clean_attachment_no_ref_rejects_storage_path_outside_root(
    attach_root: Path, tmp_path: Path
) -> None:
    """P1:DB 行 `storage_path` 逃出根(如 `..\\..` 或盘符)时,B1 清理必须拒绝,
    且 **DB 行保留**(修复前:行被删 + 文件被删,200 success_count=1)。
    """
    client, Session = _make_client()
    try:
        auth = _register_web(client, "p1-dbrow@example.com")
        _promote_admin(Session, auth["user"]["id"])
        uid = auth["user"]["id"]

        outside = tmp_path / "outside-secret.bin"
        outside.write_bytes(b"OUTSIDE")

        with Session() as db:
            db.add(
                AttachmentFile(
                    id="att-outside",
                    user_id=uid,
                    ledger_id=None,
                    sha256="d" * 64,
                    size_bytes=7,
                    file_name="outside.bin",
                    storage_path=str(outside),
                    attachment_kind="transaction",
                )
            )
            db.commit()

        # scan 不得把它当作「可删的普通孤儿」:标出根外
        scan = client.get(
            "/api/v1/admin/data-cleanup/scan",
            headers=_auth(auth["access_token"]),
        )
        assert scan.status_code == 200, scan.text
        hit = [
            o
            for o in scan.json()["file_orphans"]
            if o.get("file_path") == str(outside)
        ]
        assert hit, "根外 storage_path 仍应被列出(操作员要能看到异常)"
        assert (hit[0].get("extra") or {}).get("path_outside_root") is True, hit[0]

        # 回传到 /clean(客户端会原样 echo scan 结果)→ 必须拒绝
        res = client.post(
            "/api/v1/admin/data-cleanup/clean",
            headers=_auth(auth["access_token"]),
            json={
                "records": [
                    {
                        "type": "attachment_no_ref",
                        "title": "x",
                        "subtitle": "y",
                        "row_id": "att-outside",
                        "file_path": str(outside),
                    }
                ]
            },
        )
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["success_count"] == 0, body
        assert body["failures"], body
        assert outside.exists(), "根外文件被删除了"
        with Session() as db:
            assert db.get(AttachmentFile, "att-outside") is not None, (
                "被拒的 record 必须回滚,DB 行不能丢"
            )
    finally:
        app.dependency_overrides.clear()


def test_clean_disk_file_no_row_still_deletes_inside_root(
    attach_root: Path,
) -> None:
    """P1 反向:根**内**的合法孤儿文件照常删除(包含性校验不能把正常清理打死)。"""
    client, Session = _make_client()
    try:
        auth = _register_web(client, "p1-inside@example.com")
        _promote_admin(Session, auth["user"]["id"])

        target = attach_root / "u1" / "stray.png"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"x")

        res = client.post(
            "/api/v1/admin/data-cleanup/clean",
            headers=_auth(auth["access_token"]),
            json={
                "records": [
                    {
                        "type": "disk_file_no_row",
                        "title": "stray.png",
                        "subtitle": "磁盘文件无 DB 行",
                        "file_path": str(target),
                    }
                ]
            },
        )
        assert res.status_code == 200, res.text
        body = res.json()
        assert body == {"success_count": 1, "failures": []}, body
        assert not target.exists(), "根内合法清理失效了"
    finally:
        app.dependency_overrides.clear()


def test_clean_disk_file_no_row_rejects_traversal_string(attach_root: Path) -> None:
    """P1:`..` 相对逃逸串同样被拒(判据必须消解 `..`,不能只看前缀)。"""
    client, Session = _make_client()
    try:
        auth = _register_web(client, "p1-dotdot@example.com")
        _promote_admin(Session, auth["user"]["id"])
        escaped = attach_root / ".." / "escaped.txt"
        (attach_root.parent / "escaped.txt").write_text("X", encoding="utf-8")

        res = client.post(
            "/api/v1/admin/data-cleanup/clean",
            headers=_auth(auth["access_token"]),
            json={
                "records": [
                    {
                        "type": "disk_file_no_row",
                        "title": "e",
                        "subtitle": "y",
                        "file_path": str(escaped),
                    }
                ]
            },
        )
        assert res.status_code == 200, res.text
        assert res.json()["success_count"] == 0, res.text
        assert (attach_root.parent / "escaped.txt").exists()
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# P2 —— 存量超限 ai_config 的缩容豁免(逐个删 provider 必须可用)
# ══════════════════════════════════════════════════════════════════════


def _over_limit_cfg(n: int = 24) -> dict:
    """n 个 CJK 满配 apiKey 的自建 provider —— 序列化后**远超** 256 KB。

    单个 4096 字符 CJK apiKey = 12288 字节;n=24 时整体 ≈ 300 KB > 262144。
    (走 POST 建不出来,只能直接落库模拟存量行 —— 这正是缺陷的可达前提。)
    """
    big = "密" * 4096
    return {"providers": [_provider(f"p{i}", api_key=big) for i in range(n)], "binding": {}}


def test_enforce_bounds_exempts_shrinking_writes() -> None:
    """P2 单元面:结果 ≤ 已存字节数 → 放行(即使它仍大于绝对上限);
    更大的结果 → 仍抛 `AIConfigBoundsError`(硬上界只对增长生效)。"""
    cfg = _over_limit_cfg()
    dumped = json.dumps(cfg, ensure_ascii=False, sort_keys=True)
    stored_bytes = len(dumped.encode("utf-8"))
    assert stored_bytes > 262144, f"fixture 不够大: {stored_bytes}"

    # 缩容:删掉一个 provider(结果仍 > 256 KB)→ 放行
    shrunk = {"providers": cfg["providers"][:-1], "binding": {}}
    shrunk_bytes = ai_config_json_bytes(shrunk)
    assert shrunk_bytes > 262144, "缩容后仍应 > 上限(否则测不到豁免)"
    enforce_ai_config_bounds(shrunk, stored_bytes=stored_bytes)  # 不抛 = 通过

    # 增长:加一个 provider → 拒
    grown = {"providers": [*cfg["providers"], _provider("extra", api_key="k" * 4096)], "binding": {}}
    with pytest.raises(AIConfigBoundsError):
        enforce_ai_config_bounds(grown, stored_bytes=stored_bytes)

    # 等大(不变)→ 放行(幂等重写不能被拒)
    enforce_ai_config_bounds(cfg, stored_bytes=stored_bytes)


def test_over_limit_account_can_delete_providers_one_by_one() -> None:
    """P2 端到端:存量超限账户能**通过 DELETE /ai/providers/{id} 逐个删**回到上限内。

    修复前:`DELETE` → 400 `AI_CONFIG_TOO_LARGE`(derive:落库边界对结果一刀切),
    用户被困(唯一出口 PATCH /profile/me)。
    """
    client, Session = _make_client()
    try:
        auth = _register_web(client, "p2-shrink@example.com")
        headers = _auth(auth["access_token"])
        uid = auth["user"]["id"]

        cfg = _over_limit_cfg()
        dumped = json.dumps(cfg, ensure_ascii=False, sort_keys=True)
        assert len(dumped.encode("utf-8")) > 262144
        with Session() as db:
            db.add(
                UserProfile(
                    user_id=uid,
                    ai_config_json=dumped,
                    ai_config_version=1,
                )
            )
            db.commit()

        # GET 列表必须可用(读端点不得被写侧上限打死;播种失败也不影响服务)
        res = client.get("/api/v1/ai/providers", headers=headers)
        assert res.status_code == 200, res.text

        stored_now = _stored_ai_config(Session, "p2-shrink@example.com")
        assert stored_now is not None
        # 逐个删,直到落回上限之内
        deleted = 0
        remaining = [p["id"] for p in cfg["providers"]]
        for pid in remaining:
            res = client.delete(f"/api/v1/ai/providers/{pid}", headers=headers)
            assert res.status_code == 200, f"delete {pid} 被拒: {res.status_code} {res.text[:300]}"
            deleted += 1
            current = _stored_ai_config(Session, "p2-shrink@example.com")
            assert current is not None
            if len(current.encode("utf-8")) <= 262144:
                break
        assert deleted >= 1, "一个都没删掉"

        final = _stored_ai_config(Session, "p2-shrink@example.com")
        assert final is not None
        assert len(final.encode("utf-8")) <= 262144, (
            f"删到 {deleted} 个仍未回到上限内({len(final.encode('utf-8'))} bytes)"
        )
        # 缩回上限内后,普通的**增长**写入恢复可用(硬上界没有被削弱)
        res = client.post(
            "/api/v1/ai/providers",
            headers=headers,
            json=_provider("after-shrink", api_key="sk-new"),
        )
        assert res.status_code == 201, res.text
    finally:
        app.dependency_overrides.clear()


def test_over_limit_account_post_is_refused_until_shrunk() -> None:
    """P2 边界:超限账户的**增长**写入(POST 新 provider)必须仍被拒
    (豁免只覆盖缩容,不能变成「超限账户随便写」的后门)。"""
    client, Session = _make_client()
    try:
        auth = _register_web(client, "p2-growth@example.com")
        headers = _auth(auth["access_token"])
        with Session() as db:
            db.add(
                UserProfile(
                    user_id=auth["user"]["id"],
                    ai_config_json=json.dumps(
                        _over_limit_cfg(), ensure_ascii=False, sort_keys=True
                    ),
                    ai_config_version=1,
                )
            )
            db.commit()

        res = client.post(
            "/api/v1/ai/providers",
            headers=headers,
            json=_provider("grow", api_key="sk-" + "A" * 4092),
        )
        assert res.status_code == 400, res.text
        assert res.json().get("error_code") == "AI_CONFIG_TOO_LARGE", res.text
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# P3 —— 字节 / 字符口径统一
# ══════════════════════════════════════════════════════════════════════


def test_size_limit_is_counted_in_bytes_not_chars() -> None:
    """P3:上限是 **UTF-8 字节**口径,与 schema 的 `max_length`(字符)必须显式
    区分 —— 判据若混用字符口径,CJK 下会放行 3 倍字节量的配置。

    这里锁两条:(a) `ai_config_json_bytes` 就是存储串的 UTF-8 字节数;
    (b) 「字符数 < 上限 但 字节数 > 上限」的配置必须被拒(旧注释按字符/ASCII
    描述上限,会得出「256 KB 能装 32 个满配」的错误结论)。
    """
    # 3 个 4096 字符 CJK provider:字符口径 ~37 KB(远小于 256 KB)
    cfg = {"providers": [_provider(f"c{i}", api_key="密" * 4096) for i in range(3)], "binding": {}}
    chars = len(json.dumps(cfg, ensure_ascii=False, sort_keys=True))
    bytes_ = ai_config_json_bytes(cfg)
    assert bytes_ > chars * 2, f"fixture 未体现 CJK 膨胀: chars={chars} bytes={bytes_}"
    # 字节口径 = schema 与落库边界共用的那个数
    assert bytes_ == len(json.dumps(cfg, ensure_ascii=False, sort_keys=True).encode("utf-8"))

    # 构造一个「字符 < 256K 但字节 > 256K」的配置:必须被写侧边界拒
    n_needed = (262144 // (12288 + 40)) + 2  # 每个 CJK provider 约 12.3 KB
    big = {"providers": [_provider(f"b{i}", api_key="密" * 4096) for i in range(n_needed)], "binding": {}}
    assert len(json.dumps(big, ensure_ascii=False, sort_keys=True)) < 262144, (
        "字符数应小于上限(证明旧口径会放行)"
    )
    assert ai_config_json_bytes(big) > 262144
    with pytest.raises(AIConfigBoundsError):
        enforce_ai_config_bounds(big)


def test_shrink_baseline_is_bytes_not_chars() -> None:
    """P3(载重面):缩容豁免的比较基准必须是**字节**。

    若基准误用字符数,CJK 存量配置的字符数(~98 KB)会远低于其字节数
    (~300 KB),「字符不变、字节变大」的写入(4 字节 emoji 替换 3 字节 CJK)
    就会被错误放行 —— 那是豁免被当成增长后门。这里用 PATCH 直接把一个
    provider 的 key 换成**同字符数、更多字节**的串,必须仍被拒。
    """
    client, Session = _make_client()
    try:
        auth = _register_web(client, "p3-baseline@example.com")
        headers = _auth(auth["access_token"])
        cfg = _over_limit_cfg()  # 24 × CJK 4096 字符 ≈ 300 KB 字节 / ~98 K 字符
        stored = json.dumps(cfg, ensure_ascii=False, sort_keys=True)
        with Session() as db:
            db.add(
                UserProfile(
                    user_id=auth["user"]["id"],
                    ai_config_json=stored,
                    ai_config_version=1,
                )
            )
            db.commit()

        stored_bytes = len(stored.encode("utf-8"))
        stored_chars = len(stored)
        assert stored_bytes > 262144 and stored_chars < 262144, (
            f"fixture 需「字节超限、字符不超」: chars={stored_chars} bytes={stored_bytes}"
        )

        # 同字符数(4096)、但每字符 4 字节(emoji)→ 字节增长 4096;字符数不变
        emoji_key = "😀" * 4096
        assert len(emoji_key) == 4096 and len(emoji_key.encode("utf-8")) == 16384
        res = client.patch(
            "/api/v1/ai/providers/p0",
            headers=headers,
            json={"apiKey": emoji_key},
        )
        assert res.status_code == 400, (
            f"「字符不变、字节变大」必须按字节判为增长并拒绝: {res.status_code} {res.text[:200]}"
        )
        assert res.json().get("error_code") == "AI_CONFIG_TOO_LARGE", res.text

        # 而真正缩容(删 provider)必须放行 —— 字节基准不能把豁免一起打死
        res = client.delete("/api/v1/ai/providers/p0", headers=headers)
        assert res.status_code == 200, res.text
        after = _stored_ai_config(Session, "p3-baseline@example.com")
        assert after is not None
        assert len(after.encode("utf-8")) < stored_bytes
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# P4 —— 嵌套 `__` 内部键不得 round-trip
# ══════════════════════════════════════════════════════════════════════


def test_nested_internal_keys_are_stripped_from_persisted_payload_and_pull() -> None:
    """P4:入站 payload 里的**嵌套** `__` 键必须被 strip(不落库、不出站)。

    修复前:顶层 strip 只删 `payload["__rawUpdatedAt"]`,嵌套
    `payload["nested"]["__rawUpdatedAt"]` 原样入库并由 /sync/pull 回显。
    """
    client, Session = _make_client()
    try:
        auth = _register_app(client, "p4-nested@example.com")
        headers = _auth(auth["access_token"])
        device = auth["device_id"]

        res = client.post(
            "/api/v1/sync/push",
            headers=headers,
            json={
                "device_id": device,
                "changes": [
                    {
                        "entity_type": "category",
                        "entity_sync_id": "cat-p4",
                        "action": "upsert",
                        "updated_at": "2026-10-11T00:00:00+00:00",
                        "payload": {
                            "sync_id": "cat-p4",
                            "name": "Coffee",
                            # 顶层(旧的 strip 能拦)
                            "__rawUpdatedAt": "2999-01-01T00:00:00+00:00",
                            # 嵌套 dict(旧的 strip 漏网)
                            "nested": {"__rawUpdatedAt": "2999-01-01T00:00:00+00:00",
                                       "keep": "ok"},
                            # list 套 dict(附件形态)
                            "attachments": [
                                {"fileName": "a.jpg", "__secret": 1},
                                {"fileName": "b.jpg"},
                            ],
                        },
                    }
                ],
            },
        )
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 1, res.text

        with Session() as db:
            from src.models import SyncChange

            row = db.scalar(
                select(SyncChange).where(SyncChange.entity_sync_id == "cat-p4")
            )
            assert row is not None
            payload = row.payload_json
            if isinstance(payload, str):
                payload = json.loads(payload)
            assert "__rawUpdatedAt" not in payload, payload
            assert "__rawUpdatedAt" not in (payload.get("nested") or {}), payload
            assert (payload.get("nested") or {}).get("keep") == "ok", payload
            assert "__secret" not in payload["attachments"][0], payload
            assert payload["attachments"][0]["fileName"] == "a.jpg"

        # 出站同样不得回显(另一台设备 pull;不传 device_id → 不被「过滤自己推的
        # 变更」影响,直接看服务端实际下发的 payload 形态)
        pull = client.get(
            "/api/v1/sync/pull?since=0",
            headers=headers,
        )
        assert pull.status_code == 200, pull.text
        changes = [
            c for c in pull.json()["changes"] if c["entity_sync_id"] == "cat-p4"
        ]
        assert changes, pull.text
        out = changes[0]["payload"]
        assert "__rawUpdatedAt" not in out, out
        assert "__rawUpdatedAt" not in (out.get("nested") or {}), out
        assert "__secret" not in out["attachments"][0], out
    finally:
        app.dependency_overrides.clear()


def test_public_payload_recurses_without_mutating_source() -> None:
    """P4 单元面:出站副本递归剔除且**不改动入参**(调用方可能仍持有原对象)。"""
    from src.routers.sync._shared import _public_payload, _strip_internal_payload_keys

    original = {
        "a": 1,
        "__top": 2,
        "nested": {"b": 3, "__inner": 4, "deep": {"__x": 5, "c": 6}},
        "items": [{"d": 7, "__y": 8}, {"e": 9}],
    }
    copy = _public_payload(original)
    assert copy == {
        "a": 1,
        "nested": {"b": 3, "deep": {"c": 6}},
        "items": [{"d": 7}, {"e": 9}],
    }
    # 入参未被修改
    assert original["__top"] == 2
    assert original["nested"]["__inner"] == 4
    assert original["items"][0]["__y"] == 8
    # 标量按引用共享不产生影响
    assert copy is not original

    payload = {
        "__rawUpdatedAt": "x",
        "nested": {"__rawUpdatedAt": "y", "keep": 1},
        "items": [{"__z": 2}, {"ok": 3}],
        "scalar": "s",
    }
    removed = _strip_internal_payload_keys(payload)
    assert removed == 3, removed  # 顶层 1 + nested 1 + items[0] 1
    # 就地删除:list 元素本身保留(只删键 → items[0] 变空 dict)
    assert payload == {"nested": {"keep": 1}, "items": [{}, {"ok": 3}], "scalar": "s"}


def test_public_payload_handles_non_dict_and_empty() -> None:
    """P4 兼容面:非 dict/list 原样返回(list 现在也会被拷贝过滤,不再是原样返回)。"""
    from src.routers.sync._shared import _public_payload

    assert _public_payload(None) is None
    assert _public_payload("s") == "s"
    assert _public_payload(7) == 7
    assert _public_payload({}) == {}
    assert _public_payload([]) == []
    # list 顶层:过滤元素内的内部键
    assert _public_payload([{"a": 1, "__b": 2}]) == [{"a": 1}]


def test_nested_internal_keys_do_not_break_replay_idempotency() -> None:
    """P4 一致性:递归 strip 不得破坏幂等重放判定。

    幂等四元组的 payload_hash 只剔**顶层** `__` 键(push.py,本批不可改)。
    因为入站已递归 strip,同一请求两次的规范化结果完全一致(都无嵌套键),
    第二次必须仍被识别为重放(**不新增** SyncChange 行)—— 这是 F-01 的既有
    契约,`tests/test_sync_concurrency.py` 亦覆盖;此处补「payload 含嵌套
    `__` 键」这一新形态。
    """
    client, Session = _make_client()
    try:
        auth = _register_app(client, "p4-replay@example.com")
        headers = _auth(auth["access_token"])
        change = {
            "entity_type": "category",
            "entity_sync_id": "cat-replay",
            "action": "upsert",
            "updated_at": "2026-10-11T00:00:00+00:00",
            "payload": {
                "sync_id": "cat-replay",
                "name": "Coffee",
                "nested": {"__rawUpdatedAt": "2999-01-01T00:00:00+00:00"},
            },
        }
        body = {"device_id": auth["device_id"], "changes": [change]}

        first = client.post("/api/v1/sync/push", headers=headers, json=body)
        assert first.status_code == 200, first.text
        assert first.json()["accepted"] == 1, first.text

        second = client.post("/api/v1/sync/push", headers=headers, json=body)
        assert second.status_code == 200, second.text
        assert second.json()["accepted"] == 1, second.text

        with Session() as db:
            from src.models import SyncChange

            rows = list(
                db.scalars(
                    select(SyncChange).where(SyncChange.entity_sync_id == "cat-replay")
                ).all()
            )
            assert len(rows) == 1, (
                f"重放被当成新变更(嵌套 __ 键破坏了 payload_hash 一致性): {len(rows)} 行"
            )
    finally:
        app.dependency_overrides.clear()
