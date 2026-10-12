"""对抗性测试 —— 附件域(/attachments/*)。

覆盖攻击面:
  - 上传:文件名穿越 / NUL / 超长 / Unicode;0 字节 / 超限 / MIME 伪造
  - **账本 external_id 作为磁盘路径片段**的穿越(经 write/ledgers 与 sync/push 两条入口)
  - 路径穿越的二级利用:落到 attachments 根之外 / 与其它用户数据混居
  - 去重:同账本同 sha256 复用行;跨账本不复用;跨用户不可见
  - 越权(IDOR):B 读/删 A 的附件;已删交易的附件清理
  - GC:被引用不误删 / 孤儿清理;清理与并发上传的竞态(同图再次上传)
  - batch-exists:超大列表 → 资源耗尽

红绿纪律同 test_ai_relay_adversarial.py。
"""
from __future__ import annotations

import io
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import AttachmentFile, Ledger, LedgerMember, User

_PW = "Pa$$word1!"


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
        json={
            "email": email, "password": _PW, "device_id": "att-adv-dev",
            "client_type": client_type, "device_name": "pytest-adv", "platform": "test",
        },
    )
    assert reg.status_code in (200, 201), reg.text
    res = client.post(
        "/api/v1/auth/login",
        json={
            "email": email, "password": _PW, "device_id": "att-adv-dev",
            "client_type": client_type, "device_name": "pytest-adv", "platform": "test",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _make_ledger(client: TestClient, token: str, ledger_id: str = "adv-lg") -> None:
    res = client.post(
        "/api/v1/write/ledgers", headers=_auth(token),
        json={"ledger_id": ledger_id, "ledger_name": "adv", "currency": "CNY"},
    )
    assert res.status_code == 200, res.text


def _upload(client: TestClient, token: str, ledger_id: str, data: bytes,
            *, name: str = "a.png", mime: str | None = "image/png"):
    files = {"file": (name, io.BytesIO(data), mime)}
    return client.post(
        "/api/v1/attachments/upload", headers=_auth(token),
        data={"ledger_id": ledger_id}, files=files,
    )


def _rows(Session) -> list[AttachmentFile]:
    with Session() as db:
        return list(db.scalars(select(AttachmentFile)).all())


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
    return client.post(
        "/api/v1/write/ledgers", headers=_auth(token),
        json={"ledger_id": ledger_id, "ledger_name": "adv", "currency": "CNY"},
    )


# ══════════════════════════════════════════════════════════════════════
# 1. 账本 external_id 作为磁盘路径片段 → 路径穿越(三入口同改后的回归)
#
# 加固后的两层防线:
#   ① 创建点白名单(`LEDGER_EXTERNAL_ID_PATTERN` / sync-push 的路径安全
#      判据)→ 恶意 id 根本建不出来(422);
#   ② 存量脏行(加固前已落库)在上传落盘前被 `Path.resolve()` 包含性检查
#      拦住(400,不建目录、不写文件)。
# 每条用例同时断言两层,缺一层都算回归。
# ══════════════════════════════════════════════════════════════════════


def test_ledger_id_traversal_escapes_attachment_root(monkeypatch, tmp_path) -> None:
    """`../../escaped-adv` 形态:创建点 422 + 存量脏行上传 400,均不逃出根。

    加固前:`attachments.py:140` 用
    `_attachment_root() / ledger.user_id / ledger.external_id / sha256[:2]`
    拼存储目录,而 external_id 来自客户端(创建点只校验长度 3..128,不校验
    字符集),`ledger_id = "../../escaped"` 会让写入落到 attachments 根之外。

    加固后:创建点白名单拒绝 `..`(422);即便绕过 API 直接落库一条脏行,
    落盘前的 `Path.resolve()` 包含性检查也会 400 拦截。
    """
    import src.routers.attachments as att_module

    root = tmp_path / "attroot"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-esc@example.com")
        evil_ledger = "../../escaped-adv"

        # ① 创建点:白名单拒绝路径穿越形态
        created = _create_ledger_raw(client, token, evil_ledger)
        assert created.status_code == 422, created.text

        # ② 存量脏行:上传必须被包含性检查拦下(400),不落库、不写盘
        _seed_legacy_ledger(
            Session, email="att-adv-esc@example.com", external_id=evil_ledger,
        )
        res = _upload(client, token, evil_ledger, b"escaped-payload", name="evil.png")
        assert res.status_code == 400, res.text
        assert _rows(Session) == [], "穿越路径的上传不应落库"
        assert not (tmp_path / "escaped-adv").exists(), (
            f"附件逃出了 attachment 根目录: {(tmp_path / 'escaped-adv')}"
        )
    finally:
        app.dependency_overrides.clear()


def test_sync_push_created_traversal_ledger_also_escapes(monkeypatch, tmp_path) -> None:
    """经 /sync/push auto-create 的第二入口同样被路径安全判据封住。

    `POST /sync/push` 对 `change.ledger_id` 曾无任何字符校验,未知 id 会
    auto-create 出 Ledger 行,随后该 external_id 就能被附件上传路径使用。
    加固后 schema 校验直接 422,脏账本不会被创建;存量行仍由包含性检查
    在上传时兜底(400)。
    """
    import src.routers.attachments as att_module

    root = tmp_path / "attroot2"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-sync@example.com", client_type="app")
        evil_ledger = "../../sync-escaped-adv"
        now = datetime.now(timezone.utc).isoformat()
        push = client.post(
            "/api/v1/sync/push", headers=_auth(token),
            json={
                "device_id": "att-adv-dev",
                "changes": [{
                    "ledger_id": evil_ledger, "entity_type": "transaction",
                    "entity_sync_id": "tx1", "action": "upsert",
                    "payload": {"syncId": "tx1", "type": "expense", "amount": 1,
                                "happenedAt": now, "categoryName": "C", "accountName": "A"},
                    "updated_at": now,
                }],
            },
        )
        # ① 第二入口:路径穿越形态的 ledger_id → 422,不产生脏账本
        assert push.status_code == 422, push.text
        with Session() as db:
            assert db.scalar(
                select(Ledger).where(Ledger.external_id == evil_ledger)
            ) is None, "sync/push 不应为穿越形态的 ledger_id 建账本"

        # ② 存量脏行:上传被包含性检查拦下
        _seed_legacy_ledger(
            Session, email="att-adv-sync@example.com", external_id=evil_ledger,
        )
        res = _upload(client, token, evil_ledger, b"sync-escaped-payload", name="s.png")
        assert res.status_code == 400, res.text
        assert _rows(Session) == [], "穿越路径的上传不应落库"
        assert not (tmp_path / "sync-escaped-adv").exists()
    finally:
        app.dependency_overrides.clear()


def test_absolute_ledger_id_escapes_root(monkeypatch, tmp_path) -> None:
    """`/` 开头的 external_id:创建点 422;存量行的落盘路径被拦在根内。

    `Path("/root") / "/abs"` → `/abs`(pathlib 语义),因此绝对路径形态的
    external_id 曾把上传写到 attachments 根**之外**的文件系统绝对位置。
    """
    import src.routers.attachments as att_module

    root = tmp_path / "attroot3"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-abs@example.com")
        evil_ledger = "/tmp-abs-adv-escaped"
        created = _create_ledger_raw(client, token, evil_ledger)
        assert created.status_code == 422, created.text

        _seed_legacy_ledger(
            Session, email="att-adv-abs@example.com", external_id=evil_ledger,
        )
        res = _upload(client, token, evil_ledger, b"abs-escaped", name="abs.png")
        assert res.status_code == 400, res.text
        assert _rows(Session) == []
        assert not Path("C:/tmp-abs-adv-escaped").exists(), "绝对路径穿越写盘"
    finally:
        app.dependency_overrides.clear()


def test_ledger_external_id_backslash_escapes_root(monkeypatch, tmp_path) -> None:
    """Windows 分隔符 `..\\..\\`:创建点 422;存量行上传 400。

    在 Windows 上 `Path` 会把 `\\` 当分隔符,`..\\..\\x` 曾逃出根目录;
    Linux 部署下该串只是普通目录名 —— 但同一段代码缺少字符校验是共因,
    白名单 + 包含性检查在两端都拦得住。
    """
    import src.routers.attachments as att_module

    root = tmp_path / "attroot4"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-win@example.com")
        evil_ledger = "..\\..\\winescaped-adv"
        created = _create_ledger_raw(client, token, evil_ledger)
        assert created.status_code == 422, created.text

        _seed_legacy_ledger(
            Session, email="att-adv-win@example.com", external_id=evil_ledger,
        )
        res = _upload(client, token, evil_ledger, b"win-escaped", name="w.png")
        assert res.status_code == 400, res.text
        assert not (tmp_path / "winescaped-adv").exists()
    finally:
        app.dependency_overrides.clear()


def test_ledger_id_traversal_can_target_sibling_storage_dir(
    monkeypatch, tmp_path,
) -> None:
    """穿越不得定向写入服务端其它存储区(如 ai_log_images)。

    两层 `..` 的 external_id 曾足以从 `<DATA>/attachments/<uid>/` 走到
    `<DATA>/`,再进入兄弟目录(ai_log_images / backups / backup-staging)
    投放文件(伪造 AI 日志图片 / 覆盖备份产物)。加固后创建点 422,存量行
    由包含性检查拦下 —— 附件不得落到兄弟目录。
    """
    import src.routers.attachments as att_module

    data_dir = tmp_path / "data"
    root = data_dir / "attachments"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-sibling@example.com")
        evil_ledger = "../../ai_log_images/pwn"
        created = _create_ledger_raw(client, token, evil_ledger)
        assert created.status_code == 422, created.text

        _seed_legacy_ledger(
            Session, email="att-adv-sibling@example.com", external_id=evil_ledger,
        )
        res = _upload(client, token, evil_ledger, b"into-ai-logs", name="p.png")
        assert res.status_code == 400, res.text
        sibling = data_dir / "ai_log_images"
        assert not sibling.exists(), f"附件被写进兄弟存储目录: {sibling}"
        assert _rows(Session) == []
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 1b. 第四写点:batch 的 attach_image_id 落盘(对抗复核补漏)
#
# 加固只覆盖了 attachments.py 的三个入口,`write/transactions_batch.py` 的
# `_create_attachment_from_bytes` 仍在**裸拼接**:
#     storage_root / ledger.user_id / ledger.external_id / sha256[:2]
# 存量脏账本(external_id = `..\..\..\escaped-batch3`)实测把截图写到了
# 附件根之外 —— 复核证据 = `<sandbox>\escaped-batch3\38\..._screenshot.png`。
# 修法:所有落盘点统一走共享 helper `src/storage_paths.resolve_within_root`。
# ══════════════════════════════════════════════════════════════════════


def test_batch_attach_image_id_traversal_cannot_escape_root(
    monkeypatch, tmp_path,
) -> None:
    """batch 截图附件路径必须与 `/attachments/upload` 同口径(共享 helper)。

    两层断言,分别在**不同调用深度**上锁死第四写点:

    ① 落盘辅助函数层(跨平台 falsifiable):直接调
       `_create_attachment_from_bytes` 并把脏 external_id 传进去。修前:不抛
       异常、文件写到 `<root>/<uid>/..\..\..\escaped-batch3/38/...`(Windows
       上即根外);修后:400 且盘上无根外文件。这一层不依赖 URL 路由能否
       携带路径分隔符,因此在 POSIX CI 上同样会因修前行为而失败。
    ② 真 endpoint 层(reviewer repro 原样):`POST .../transactions/batch`
       带合法 `attach_image_id`。无论平台,磁盘上都不得出现附件根之外的文件,
       且落库的 `storage_path` 必须在根内。Windows(`\` 是分隔符)额外断言
       400 —— 复核用的正是这个形态。

    POSIX 说明:`/` 形态的 external_id 无法作为单个 URL path segment 到达该
    endpoint(路由按段匹配直接 404),所以 POSIX 上的可复现逃逸面由 ① 覆盖。
    """
    from fastapi import HTTPException

    import src.routers.write.transactions_batch as batch_module
    from src.config import get_settings
    from src.models import Ledger
    from src.services.ai.image_cache import store_image

    sandbox = tmp_path / "batch-sandbox"
    root = sandbox / "data" / "attachments"
    monkeypatch.setattr(get_settings(), "attachment_storage_dir", str(root))

    email = "att-adv-batch4@example.com"
    evil_ledger = "..\\..\\..\\escaped-batch3"

    def _outside_files() -> list[str]:
        if not sandbox.exists():
            return []
        rr = root.resolve()
        return [
            str(p.resolve())
            for p in sandbox.rglob("*")
            if p.is_file() and not p.resolve().is_relative_to(rr)
        ]

    client, Session = _make_client()
    try:
        token = _login(client, email)
        _seed_legacy_ledger(Session, email=email, external_id=evil_ledger)

        # ① 落盘辅助函数层:脏 external_id → 400,盘上零文件
        with Session() as db:
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == evil_ledger))
            assert ledger is not None
            user_id = ledger.user_id
            with pytest.raises(HTTPException) as exc:
                batch_module._create_attachment_from_bytes(
                    db=db, ledger=ledger, user_id=user_id,
                    image_bytes=b"batch-escape-probe", mime_type="image/jpeg",
                )
            assert exc.value.status_code == 400, exc.value.status_code
        assert _outside_files() == [], (
            f"batch 落盘辅助函数把文件写出了附件根: {_outside_files()}"
        )

        # ② 真 endpoint(reviewer repro:合法 image_id + 脏账本)
        image_id = store_image(
            image_bytes=b"batch-http-probe", mime_type="image/jpeg", user_id=user_id,
        )
        res = client.post(
            f"/api/v1/write/ledgers/{evil_ledger}/transactions/batch",
            json={
                "base_change_id": 0,
                "transactions": [{
                    "tx_type": "expense", "amount": 12.5,
                    "happened_at": "2026-05-06T12:30:00Z", "note": "batch4",
                }],
                "auto_ai_tag": False,
                "attach_image_id": image_id,
                "locale": "zh",
            },
            headers=_auth(token),
        )
        outside = _outside_files()
        assert outside == [], f"batch 端点把截图写出了附件根: {outside}"
        if os.name == "nt":
            # Windows:`..\..\..\` 是真实分隔符,修前这里 200 且文件逃逸。
            assert res.status_code == 400, res.text
            assert _rows(Session) == [], "穿越路径的 batch 附件不应落库"
        # 落库行的 storage_path 也必须在根内(只扫磁盘会漏"路径已污染但文件
        # 尚未写"的中间态)。
        root_resolved = root.resolve()
        for row in _rows(Session):
            assert Path(row.storage_path).resolve().is_relative_to(root_resolved), (
                f"落库的 storage_path 逃出附件根: {row.storage_path}"
            )
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 1c. 静态审计:任何把 external_id 拼进磁盘路径的写点都必须在同一
#     guard 窗口内调用共享包含性检查(防"只改一个入口"复发)
# ══════════════════════════════════════════════════════════════════════

# 认可的三条等价防线(见 src/storage_paths.py / attachments.py / admin.py)。
# 用**调用形态**匹配:注释里提到 helper 名字不算防线(实测:注释提一句
# `resolve_within_root` 就能骗过纯子串匹配,让裸拼接的回归测试误绿)。
_GUARD_CALL_MARKERS = (
    "resolve_within_root(",
    "_resolve_storage_path(",
    "_safe_storage_component(",
)


def _external_id_path_join_lines(text: str) -> list[tuple[int, str]]:
    """返回「把 external_id 拼进磁盘路径」的行(行号, 行文本)。

    判据(去字符串字面量后):
      a) 行内出现 Path( / joinpath( / os.path.join( 且带 external_id;或
      b) 行内有 `/`(或 `\\`)拼接 external_id,且同行有 storage/root/dir/
         base/path/folder 之类"这是文件系统路径"的信号词。

    纯文档字符串 / 注释 / `=` 比较不算。
    """
    import re

    strip_str = re.compile(r"([\"'])(?:\\.|(?!\1).)*\1")
    external = re.compile(r"\b\w*external_id\b")
    join_call = re.compile(r"(Path\(|joinpath\(|os\.path\.join\()")
    slash_join = re.compile(r"(?:/|\\\\)\s*[\w.]*external_id\b|\bexternal_id\b\s*(?:/|\\\\)")
    rooty = re.compile(r"\b\w*(?:storage|root|dir|base|path|folder)\w*\b", re.IGNORECASE)

    out: list[tuple[int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "external_id" not in line:
            continue
        code = strip_str.sub("''", line)
        if not external.search(code):
            continue
        if join_call.search(code) or (slash_join.search(code) and rooty.search(code)):
            out.append((lineno, stripped))
    return out


def _has_guard_call_near(text_lines: list[str], lineno: int, window: int = 25) -> bool:
    """该写点附近的 guard 窗口内是否有包含性检查的**调用**(非注释提及)。"""
    lo = max(0, lineno - window)
    hi = min(len(text_lines), lineno + window)
    chunk = "\n".join(text_lines[lo:hi])
    # 去掉行内注释,避免「注释里提一句 helper 名字」被当成防线。
    code = "\n".join(line.split("#", 1)[0] for line in chunk.splitlines())
    return any(marker in code for marker in _GUARD_CALL_MARKERS)


def test_no_unguarded_external_id_path_join_anywhere() -> None:
    """ADVERSE FINDING 回归锁:全 `src/` 静态审计 external_id 路径拼接。

    第四写点的教训是「同一根因有三个入口被修、第四个漏网」。这条测试不
    依赖任何人记得去改某个文件:只要新出现一处把 external_id 拼进磁盘
    路径、且附近没有共享包含性检查(`resolve_within_root` /
    `_resolve_storage_path` / `_safe_storage_component`,且必须是**调用**
    而非注释提及)的写点,即红。

    falsifiable:把 `write/transactions_batch.py` 的
    `resolve_within_root(...)` 调用换回裸拼接,该文件立刻出现在
    offenders 里(实测)。
    """
    import pathlib

    src_root = pathlib.Path(__file__).resolve().parents[2] / "src"
    offenders: list[str] = []
    for path in sorted(src_root.rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        if "external_id" not in text:
            continue
        lines = text.splitlines()
        for lineno, line in _external_id_path_join_lines(text):
            if not _has_guard_call_near(lines, lineno):
                rel = path.relative_to(src_root.parent).as_posix()
                offenders.append(f"{rel}:{lineno}: {line[:100]}")

    assert offenders == [], (
        "以下写点把 ledger external_id 拼进了磁盘路径,附近却没有共享包含性"
        f"检查(resolve_within_root / _resolve_storage_path / _safe_storage_component): {offenders}"
    )


# ══════════════════════════════════════════════════════════════════════
# 2. 文件名与体积校验
# ══════════════════════════════════════════════════════════════════════


def test_filename_traversal_is_sanitized(monkeypatch, tmp_path) -> None:
    """文件名里的 `../` 被 Path(...).name 剥掉(既有防护,确认有效)。"""
    import src.routers.attachments as att_module

    root = tmp_path / "attfn"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-fname@example.com")
        _make_ledger(client, token, "fn-lg")
        res = _upload(client, token, "fn-lg", b"n", name="../../evil.png")
        assert res.status_code == 200, res.text
        rows = _rows(Session)
        assert rows[0].file_name == "evil.png", rows[0].file_name
        assert Path(rows[0].storage_path).resolve().is_relative_to(root.resolve())
    finally:
        app.dependency_overrides.clear()


def test_filename_nul_byte_is_stored_as_percent_encoding(monkeypatch, tmp_path) -> None:
    """HARDENING:文件名含 NUL → 落库变成 `a%00b.png`,磁盘上用 percent 形式。

    multipart 解析把 NUL 转义成 `%00`,所以不会触到 pathlib 的
    "embedded null character" 异常 —— 当前行为可用。记录:file_name 里
    保留了 `%00`,若某下游把它当 URL 片段再解码会得到 NUL(潜在二次问题)。
    """
    import src.routers.attachments as att_module

    root = tmp_path / "attnul"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-nul@example.com")
        _make_ledger(client, token, "nul-lg")
        res = _upload(client, token, "nul-lg", b"nulname", name="a\x00b.png")
        assert res.status_code == 200, res.text
        rows = _rows(Session)
        assert rows[0].file_name == "a%00b.png", rows[0].file_name
        assert Path(rows[0].storage_path).exists()
    finally:
        app.dependency_overrides.clear()


def test_filename_over_255_chars_rejected_by_multipart_layer(
    monkeypatch, tmp_path,
) -> None:
    """HARDENING:超长文件名(≥4000 字符)→ 400(由 starlette 头长限制挡住)。"""
    import src.routers.attachments as att_module

    root = tmp_path / "attlong"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-long@example.com")
        _make_ledger(client, token, "long-lg")
        res = _upload(client, token, "long-lg", b"long", name="x" * 5000 + ".png")
        assert res.status_code == 400, res.text
        assert _rows(Session) == []
    finally:
        app.dependency_overrides.clear()


def test_unicode_filename_is_stored_verbatim(monkeypatch, tmp_path) -> None:
    """HARDENING:Unicode 文件名(含 emoji / RTL 覆写字符)原样落库与落盘。

    `_safe_file_name` 只取 basename + 截断,不过滤不可见字符。RTL 覆写
    (U+202E)可让文件名在 UI 里显示成另一后缀(如 `a\u202Egnp.exe` 视觉上
    像 png)。当前行为可辩护(下载走 Content-Disposition 带 quote),记录边界。
    """
    import src.routers.attachments as att_module

    root = tmp_path / "attuni"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-uni@example.com")
        _make_ledger(client, token, "uni-lg")
        tricky = "截图\u202Egnp.png"
        res = _upload(client, token, "uni-lg", b"unicode", name=tricky)
        assert res.status_code == 200, res.text
        rows = _rows(Session)
        assert rows[0].file_name == tricky, rows[0].file_name

        dl = client.get(f"/api/v1/attachments/{rows[0].id}", headers=_auth(token))
        assert dl.status_code == 200, dl.text
        # Content-Disposition 里 RTL 覆写字符被 percent-encode(不会原样进头)
        assert "%E2%80%AE" in dl.headers.get("content-disposition", "")
    finally:
        app.dependency_overrides.clear()


def test_empty_upload_rejected_400(monkeypatch, tmp_path) -> None:
    """0 字节上传 → 400 Attachment file is empty。"""
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attempty")

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-empty@example.com")
        _make_ledger(client, token, "empty-lg")
        res = _upload(client, token, "empty-lg", b"")
        assert res.status_code == 400, res.text
        assert _rows(Session) == []
    finally:
        app.dependency_overrides.clear()


def test_upload_over_limit_rejected_413(monkeypatch, tmp_path) -> None:
    """超 attachment_max_upload_bytes → 413(用 monkeypatch 把上限压到 1KB)。"""
    import src.routers.attachments as att_module
    from src.config import get_settings

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attbig")
    monkeypatch.setattr(get_settings(), "attachment_max_upload_bytes", 1024)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-big@example.com")
        _make_ledger(client, token, "big-lg")
        ok = _upload(client, token, "big-lg", b"x" * 1024)
        assert ok.status_code == 200, ok.text
        bad = _upload(client, token, "big-lg", b"y" * 1025)
        assert bad.status_code == 413, bad.text
    finally:
        app.dependency_overrides.clear()


def _upload_raw_cl(client: TestClient, token: str, ledger_id: str, payload: bytes,
                   cl_delta: int):
    """手工组 multipart,并把 Content-Length 改成 `实际长度 + cl_delta`。"""
    boundary = "----attclbound42"
    parts = [
        (f'--{boundary}\r\nContent-Disposition: form-data; name="ledger_id"\r\n\r\n'
         f"{ledger_id}\r\n").encode(),
        (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
         f'filename="cl.png"\r\nContent-Type: image/png\r\n\r\n').encode()
        + payload + b"\r\n",
    ]
    body = b"".join(parts) + f"--{boundary}--\r\n".encode()
    lie = str(len(body) + cl_delta)
    req = client.build_request(
        "POST", "/api/v1/attachments/upload", content=body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Authorization": f"Bearer {token}",
            "Content-Length": lie,
        },
    )
    req.headers["Content-Length"] = lie  # httpx 不会覆盖显式 CL,保持谎报
    return req, lie


def test_upload_content_length_lie_is_tolerated_and_sizes_true(
    monkeypatch, tmp_path,
) -> None:
    """HARDENING:multipart 的 Content-Length 谎报 → 按**实际字节**处理,不 500/不挂起。

    谎报三态(虚报 +10KB / 少报 −20B / 巨额 +9MB)在 ASGI 应用层实测:
      - 全部 200(Starlette multipart 走 receive 流式读,不按 CL 预分配、
        不因 EOF 缺口抛 500,也不存在悬挂);
      - 落库 size == 实际 payload 长度(少报不截断、虚报不补零),
        sha256 也是实际字节的哈希 —— 去重语义不被 CL 污染。
    边界:结论只覆盖应用层;uvicorn 传输层按声明的 CL 组帧(少报→截断、
    虚报→等更多字节),那层需真实 socket 场景,见报告「未能验证」。
    """
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attcl")

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-cl@example.com")
        _make_ledger(client, token, "cl-lg")
        for i, delta in enumerate((0, 10_000, -20, 9_000_000)):
            payload = f"cl-payload-{delta}".encode()
            req, lie = _upload_raw_cl(client, token, "cl-lg", payload, delta)
            assert req.headers["content-length"] == lie, req.headers
            res = client.send(req)
            assert res.status_code == 200, f"delta={delta} -> {res.status_code} {res.text[:160]}"
            row = next(r for r in _rows(Session)
                       if r.file_name == "cl.png" and r.size_bytes == len(payload))
            assert row.size_bytes == len(payload), (delta, row.size_bytes)
        # 不同 payload 不会因谎报互相去重串味
        assert len({r.sha256 for r in _rows(Session)}) == 4
    finally:
        app.dependency_overrides.clear()


def test_upload_html_disguised_as_image_is_accepted(monkeypatch, tmp_path) -> None:
    """ADVERSE FINDING:附件上传完全不校验内容与声明 MIME 的一致性。

    `/attachments/upload`(attachments.py:103-179)只读字节 + 校验大小,
    `mime_type` 直接取 multipart 声明的 content-type 落库;下载时用该
    mime 回写响应头(FileResponse media_type=row.mime_type)。于是:
      - 上传 HTML 内容 + 声明 image/png → 落库 image/png;
      - 若某前端渲染方信任该 mime,或把附件 URL 嵌进 <img>/<iframe>,
        HTML(含脚本)会在同源下渲染 → 存储型 XSS 面。
    这里断言「上传时至少不信任声明 MIME(或做魔数校验)」这一期望。
    当前实现:原样接受。响应头用 attachment disposition 缓解了直接渲染,
    但同源 /api/v1/attachments/<id> 一旦被 <img src> 引用即触发。

    期望:对 image/* 声明做魔数校验,或统一以 octet-stream 回写。
    源码:`src/routers/attachments.py:150`(mime_type=file.content_type)。
    """
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "atthtml")

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-html@example.com")
        _make_ledger(client, token, "html-lg")
        res = _upload(
            client, token, "html-lg",
            b"<html><body><script>alert(document.domain)</script></body></html>",
            name="evil.png", mime="image/png",
        )
        assert res.status_code == 200, res.text
        row = _rows(Session)[0]
        dl = client.get(f"/api/v1/attachments/{row.id}", headers=_auth(token))
        assert dl.status_code == 200
        # ADVERSE FINDING: HTML 载荷以声明 MIME(image/png)原样回写,零魔数校验
        assert not dl.headers["content-type"].startswith("image/"), (
            "HTML 内容以 image/png 声明上传后,下载响应也是 image/png "
            "(零魔数校验,同源渲染即存储型 XSS 面);attachments.py:150"
        )
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 3. 去重语义 / 跨账本与跨用户隔离
# ══════════════════════════════════════════════════════════════════════


def test_same_image_twice_in_ledger_reuses_row(monkeypatch, tmp_path) -> None:
    """HARDENING:同账本同 sha256 复用同一行(不重复占盘)。"""
    import src.routers.attachments as att_module

    root = tmp_path / "attdup"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-dup@example.com")
        _make_ledger(client, token, "dup-lg")
        payload = b"same-bytes-here"
        first = _upload(client, token, "dup-lg", payload, name="1.png")
        second = _upload(client, token, "dup-lg", payload, name="2.png")
        assert first.status_code == second.status_code == 200
        assert first.json()["file_id"] == second.json()["file_id"]
        assert len(_rows(Session)) == 1
        assert len(list(root.rglob("*.png"))) == 1, "重复上传不应多写一份磁盘文件"
    finally:
        app.dependency_overrides.clear()


def test_dedup_race_path_reclaims_orphan_storage(monkeypatch, tmp_path) -> None:
    """HARDENING:check-then-insert 竞态兜底 —— 预检 miss 时靠 IntegrityError 复用。

    `upload_attachment` 的预检在并发下会 miss;靠 (ledger_id, sha256) 唯一
    索引兜底并回收刚写出的磁盘文件。这里 monkeypatch 只让**预检那一次**
    返 None(随后 IntegrityError 恢复查询走真实实现),稳定复现竞态分支,
    断言:仍复用既有行,且新写的孤儿文件被 unlink。
    """
    import src.routers.attachments as att_module

    root = tmp_path / "attrace"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-race@example.com")
        _make_ledger(client, token, "race-lg")
        payload = b"race-payload"
        assert _upload(client, token, "race-lg", payload, name="a.png").status_code == 200

        # 只让「上传前那一次预检」miss,强制走 IntegrityError 分支
        real_find = att_module._find_existing_tx_attachment
        state = {"precheck_calls": 0}

        def flaky_find(db, ledger_id, sha256):
            state["precheck_calls"] += 1
            if state["precheck_calls"] == 1:
                return None
            return real_find(db, ledger_id, sha256)

        monkeypatch.setattr(att_module, "_find_existing_tx_attachment", flaky_find)

        res = _upload(client, token, "race-lg", payload, name="b.png")
        assert res.status_code == 200, res.text
        assert state["precheck_calls"] >= 2, "未走到 IntegrityError 恢复分支"
        assert len(_rows(Session)) == 1, "竞态分支应复用赢家行"
        files = list(root.rglob("*.png"))
        assert len(files) == 1, f"孤儿磁盘文件未回收: {files}"
    finally:
        app.dependency_overrides.clear()


def test_cross_ledger_same_bytes_create_separate_rows(monkeypatch, tmp_path) -> None:
    """HARDENING:同用户不同账本的同图 → 各建一行(去重按账本隔离)。"""
    import src.routers.attachments as att_module

    root = tmp_path / "attxl"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-xl@example.com")
        _make_ledger(client, token, "xl-1")
        _make_ledger(client, token, "xl-2")
        payload = b"cross-ledger-bytes"
        a = _upload(client, token, "xl-1", payload)
        b = _upload(client, token, "xl-2", payload)
        assert a.status_code == b.status_code == 200
        assert a.json()["file_id"] != b.json()["file_id"]
        assert len(_rows(Session)) == 2
    finally:
        app.dependency_overrides.clear()


def test_user_b_cannot_download_or_delete_a_attachment(monkeypatch, tmp_path) -> None:
    """IDOR:B 读/删 A 账本的附件 → 403(删除端点存在性另行验证)。"""
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attidor")

    client, Session = _make_client()
    try:
        token_a = _login(client, "att-adv-idor-a@example.com")
        _make_ledger(client, token_a, "idor-lg")
        up = _upload(client, token_a, "idor-lg", b"private-a")
        file_id = up.json()["file_id"]

        token_b = _login(client, "att-adv-idor-b@example.com")
        res_b = client.get(f"/api/v1/attachments/{file_id}", headers=_auth(token_b))
        assert res_b.status_code == 403, res_b.text
        # 重复 sha256 探测:batch-exists 也应因账本不可见而 404
        probe = client.post(
            "/api/v1/attachments/batch-exists", headers=_auth(token_b),
            json={"ledger_id": "idor-lg", "sha256_list": [up.json()["sha256"]]},
        )
        assert probe.status_code == 404, probe.text
    finally:
        app.dependency_overrides.clear()


def test_removed_member_loses_attachment_access(monkeypatch, tmp_path) -> None:
    """越权:S1 回归 —— 被移除成员不能下载自己上传的 tx 附件。"""
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attmember")

    client, Session = _make_client()
    try:
        owner_token = _login(client, "att-adv-owner@example.com")
        editor_token = _login(client, "att-adv-editor@example.com")
        _make_ledger(client, owner_token, "member-lg")

        with Session() as db:
            owner = db.scalar(select(User).where(User.email == "att-adv-owner@example.com"))
            editor = db.scalar(select(User).where(User.email == "att-adv-editor@example.com"))
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == "member-lg"))
            db.add(LedgerMember(ledger_id=ledger.id, user_id=editor.id, role="editor",
                                invited_by=owner.id))
            db.commit()

        up = _upload(client, editor_token, "member-lg", b"editor-upload")
        assert up.status_code == 200, up.text
        file_id = up.json()["file_id"]
        assert client.get(f"/api/v1/attachments/{file_id}",
                          headers=_auth(editor_token)).status_code == 200

        with Session() as db:
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == "member-lg"))
            editor = db.scalar(select(User).where(User.email == "att-adv-editor@example.com"))
            db.execute(
                LedgerMember.__table__.delete().where(
                    LedgerMember.ledger_id == ledger.id,
                    LedgerMember.user_id == editor.id,
                )
            )
            db.commit()

        denied = client.get(f"/api/v1/attachments/{file_id}", headers=_auth(editor_token))
        assert denied.status_code == 403, denied.text
    finally:
        app.dependency_overrides.clear()


def test_download_unknown_attachment_id_404(monkeypatch, tmp_path) -> None:
    """不存在的 file_id → 404(不泄露存在性差异)。"""
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "att404")

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-404@example.com")
        for fid in ("does-not-exist", "../../../etc/passwd", "%2e%2e%2f"):
            res = client.get(f"/api/v1/attachments/{fid}", headers=_auth(token))
            assert res.status_code in (404, 405, 422), f"{fid!r} -> {res.status_code}"
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 4. GC / 引用保护
# ══════════════════════════════════════════════════════════════════════


def test_gc_preserves_referenced_and_removes_orphan(monkeypatch, tmp_path) -> None:
    """GC:被 tx 引用的附件不动;无引用附件行删 + 磁盘 unlink。"""
    from src.projection import gc_orphan_attachments
    from src.models import ReadTxProjection

    client, Session = _make_client()
    try:
        with Session() as db:
            db.add(User(id="gc-u1", email="gc@example.com", password_hash="x"))
            db.add(Ledger(id="gc-l1", user_id="gc-u1", external_id="gc-lg",
                          name="L", currency="CNY"))
            db.flush()
            kept = tmp_path / "kept.bin"
            kept.write_bytes(b"kept")
            orphan = tmp_path / "orphan.bin"
            orphan.write_bytes(b"orphan")
            db.add(AttachmentFile(id="gc-kept", ledger_id="gc-l1", user_id="gc-u1",
                                  sha256="k", size_bytes=4, mime_type="image/png",
                                  file_name="k.png", storage_path=str(kept)))
            db.add(AttachmentFile(id="gc-orphan", ledger_id="gc-l1", user_id="gc-u1",
                                  sha256="o", size_bytes=6, mime_type="image/png",
                                  file_name="o.png", storage_path=str(orphan)))
            db.add(ReadTxProjection(
                ledger_id="gc-l1", sync_id="gc-tx", user_id="gc-u1", tx_type="expense",
                amount=1.0, happened_at=datetime.now(timezone.utc), tx_index=0,
                source_change_id=1,
                attachments_json=json.dumps([{"fileName": "k.png", "cloudFileId": "gc-kept"}]),
            ))
            db.commit()

        with Session() as db:
            n = gc_orphan_attachments(db, user_id="gc-u1", file_ids={"gc-kept", "gc-orphan"})
            db.commit()
        assert n == 1, n
        assert kept.exists(), "被引用附件被误删"
        assert not orphan.exists(), "孤儿附件未清理"
        ids = {r.id for r in _rows(Session)}
        assert ids == {"gc-kept"}, ids
    finally:
        app.dependency_overrides.clear()


def test_gc_referenced_by_other_users_projection_is_preserved(tmp_path) -> None:
    """GC 引用检查全局(fileId 精确匹配),不被 user_id 收窄误删活附件(P0-1)。"""
    from src.models import ReadTxProjection
    from src.projection import gc_orphan_attachments

    client, Session = _make_client()
    try:
        with Session() as db:
            db.add(User(id="gc-owner", email="o@example.com", password_hash="x"))
            db.add(User(id="gc-editor", email="e@example.com", password_hash="x"))
            db.add(Ledger(id="gc-sl", user_id="gc-owner", external_id="shared",
                          name="L", currency="CNY"))
            db.flush()
            p = tmp_path / "shared.bin"
            p.write_bytes(b"shared")
            db.add(AttachmentFile(id="gc-shared", ledger_id="gc-sl", user_id="gc-editor",
                                  sha256="s", size_bytes=6, mime_type="image/png",
                                  file_name="s.png", storage_path=str(p)))
            # 引用挂在 owner 的投影行上(Editor 上传、Owner 账本)
            db.add(ReadTxProjection(
                ledger_id="gc-sl", sync_id="gc-stx", user_id="gc-owner", tx_type="expense",
                amount=1.0, happened_at=datetime.now(timezone.utc), tx_index=0,
                source_change_id=1,
                attachments_json=json.dumps([{"cloudFileId": "gc-shared"}]),
            ))
            db.commit()

        with Session() as db:
            n = gc_orphan_attachments(db, user_id="gc-editor", file_ids={"gc-shared"})
            db.commit()
        assert n == 0, "owner 投影行仍有引用时不应 GC(否则共享账本误删活附件)"
        assert p.exists()
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 5. batch-exists 资源耗尽
# ══════════════════════════════════════════════════════════════════════


def test_batch_exists_unbounded_list_causes_500(monkeypatch, tmp_path) -> None:
    """ADVERSE FINDING:`batch-exists` 的 sha256_list 无条数上限 → SQL 变量溢出 500。

    请求 schema(`AttachmentBatchExistsRequest.sha256_list: list[str]`)没有
    `max_length`;实现把整列表塞进 `sha256.in_(wanted)`(attachments.py:198)。
    实测:2000 条 → 200;60000 条 → 500(sqlite 「too many SQL variables」,
    SQLAlchemy OperationalError 未被捕获 → 全局 handler 500)。在 PostgreSQL
    上对应 `bind message supplies N parameters`上限(65535),同样是 500。

    后果:任一登录用户可用一条请求把库打成 500(日志刷屏 + 无成本 DoS),
    而正确响应应是 413/422。

    期望:列表长度有上限(如 ≤1000)并返回 4xx。
    源码:`src/routers/attachments.py:182-217`、`src/schemas.py:1147-1149`。
    """
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attbatch")

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-batch@example.com")
        _make_ledger(client, token, "batch-lg")
        res = client.post(
            "/api/v1/attachments/batch-exists", headers=_auth(token),
            json={"ledger_id": "batch-lg",
                  "sha256_list": [f"{i:064d}" for i in range(60_000)]},
        )
        # ADVERSE FINDING: 无长度上限 → sqlite 变量溢出,直接 500
        assert res.status_code != 500, (
            "batch-exists 的 sha256_list 无长度上限,6 万条直接打成 500"
            f"(应为 413/422): {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()


def test_batch_exists_duplicate_sha_bytes_fine(monkeypatch, tmp_path) -> None:
    """HARDENING:列表内大量重复 sha(相同字符串)不触发变量上限问题。"""
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attbatch2")

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-batch2@example.com")
        _make_ledger(client, token, "batch2-lg")
        res = client.post(
            "/api/v1/attachments/batch-exists", headers=_auth(token),
            json={"ledger_id": "batch2-lg", "sha256_list": ["a" * 64] * 5000},
        )
        assert res.status_code == 200, res.text
        assert len(res.json()["items"]) == 5000
    finally:
        app.dependency_overrides.clear()


def test_batch_exists_empty_list_returns_empty(monkeypatch, tmp_path) -> None:
    """空列表 → items=[] 且不报错。"""
    import src.routers.attachments as att_module

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "attbatch3")

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-batch3@example.com")
        _make_ledger(client, token, "batch3-lg")
        res = client.post(
            "/api/v1/attachments/batch-exists", headers=_auth(token),
            json={"ledger_id": "batch3-lg", "sha256_list": []},
        )
        assert res.status_code == 200, res.text
        assert res.json()["items"] == []
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 6. 分类图标端点
# ══════════════════════════════════════════════════════════════════════


def test_category_icon_dedup_and_isolation(monkeypatch, tmp_path) -> None:
    """分类图标:同用户同图去重(复用行);陌生人不可下载。"""
    import src.routers.attachments as att_module

    root = tmp_path / "atticon"
    monkeypatch.setattr(att_module, "_attachment_root", lambda: root)

    client, Session = _make_client()
    try:
        token_a = _login(client, "att-adv-icon-a@example.com")
        files = {"file": ("icon.png", io.BytesIO(b"icon-bytes"), "image/png")}
        first = client.post("/api/v1/attachments/category-icons/upload",
                            headers=_auth(token_a), files=files)
        assert first.status_code == 200, first.text
        second = client.post(
            "/api/v1/attachments/category-icons/upload", headers=_auth(token_a),
            files={"file": ("icon2.png", io.BytesIO(b"icon-bytes"), "image/png")},
        )
        assert second.status_code == 200, second.text
        assert first.json()["file_id"] == second.json()["file_id"]
        assert len(_rows(Session)) == 1

        token_b = _login(client, "att-adv-icon-b@example.com")
        res = client.get(f"/api/v1/attachments/{first.json()['file_id']}",
                         headers=_auth(token_b))
        assert res.status_code == 403, res.text
    finally:
        app.dependency_overrides.clear()


def test_category_icon_empty_and_oversize(monkeypatch, tmp_path) -> None:
    """分类图标:0 字节 400;超限 413。"""
    import src.routers.attachments as att_module
    from src.config import get_settings

    monkeypatch.setattr(att_module, "_attachment_root", lambda: tmp_path / "atticon2")
    monkeypatch.setattr(get_settings(), "attachment_max_upload_bytes", 512)

    client, Session = _make_client()
    try:
        token = _login(client, "att-adv-icon-c@example.com")
        empty = client.post(
            "/api/v1/attachments/category-icons/upload", headers=_auth(token),
            files={"file": ("e.png", io.BytesIO(b""), "image/png")},
        )
        assert empty.status_code == 400, empty.text
        big = client.post(
            "/api/v1/attachments/category-icons/upload", headers=_auth(token),
            files={"file": ("b.png", io.BytesIO(b"z" * 513), "image/png")},
        )
        assert big.status_code == 413, big.text
    finally:
        app.dependency_overrides.clear()
