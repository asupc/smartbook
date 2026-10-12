"""令牌 / 作用域对抗测试 —— PAT 生命周期、JWT↔PAT 分流、scope 提升、
Idempotency-Key 语义、app scope 与 rw 端点的隔离。

标注约定:
  ADVERSE FINDING  —— 真实缺陷(测试保持失败)
  HARDENING        —— 行为可辩护但脆弱(断言当前行为并通过)
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.mcp import auth as mcp_auth
from src.models import PersonalAccessToken, SyncPushIdempotency

PASSWORD = "Pa$$word1!"


def _make_client() -> tuple[TestClient, sessionmaker]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    TS = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override():
        db = TS()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override
    # MCP middleware 不走 FastAPI dep tree,直接用模块级 SessionLocal。
    mcp_auth.SessionLocal = TS
    return TestClient(app, raise_server_exceptions=False), TS


@pytest.fixture()
def client():
    c, TS = _make_client()
    yield c, TS
    app.dependency_overrides.clear()


def _register(client, email: str, client_type: str = "web", device_id: str | None = None) -> dict:
    body = {
        "email": email,
        "password": PASSWORD,
        "client_type": client_type,
        "device_name": "pytest",
        "platform": "test",
    }
    if device_id:
        body["device_id"] = device_id
    res = client.post("/api/v1/auth/register", json=body)
    assert res.status_code == 200, res.text
    return res.json()


def _auth(token: str, device: str = "d-web") -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": device}


def _create_pat(client, token: str, *, name: str = "adv", scopes=None, expires_in_days=90):
    body = {"name": name, "scopes": scopes if scopes is not None else ["mcp:read"]}
    if expires_in_days is not None:
        body["expires_in_days"] = expires_in_days
    return client.post("/api/v1/profile/pats", headers=_auth(token), json=body)


def _mcp_headers(pat: str) -> dict:
    return {
        "Authorization": f"Bearer {pat}",
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
    }


def _mcp_post(client, pat: str, payload: dict):
    return client.post("/api/v1/mcp", headers=_mcp_headers(pat), json=payload)


def _mcp_tools_list_ok(pat: str) -> bool:
    """PAT 是否通过 MCP 中间件(PATAuthMiddleware)。

    直接调用 `mcp_server.app`(ASGI)并用 stub 替换 session_manager 的
    handle_request —— 避免真实 anyio task group 需要 lifespan
    (`with TestClient(app)` 会触发 startup,对真实 DB 跑备份调度器等,污染
    测试环境)。做法与 tests/test_mcp_streamable_http.py 一致。
    """
    import anyio

    from src.mcp import server as mcp_server

    captured: dict = {}

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    sent: list = []

    async def send(message):
        sent.append(message)

    async def main():
        async def fake_handle_request(scope, receive_, send_):
            captured["reached"] = True
            await send_({"type": "http.response.start", "status": 202, "headers": []})
            await send_({"type": "http.response.body", "body": b""})

        original = mcp_server.mcp.session_manager.handle_request
        mcp_server.mcp.session_manager.handle_request = fake_handle_request
        try:
            await mcp_server.app(
                {
                    "type": "http",
                    "method": "POST",
                    "path": "/api/v1/mcp",
                    "raw_path": b"/api/v1/mcp",
                    "headers": [(b"authorization", f"Bearer {pat}".encode())],
                    "query_string": b"",
                    "client": ("test", 1),
                    "server": ("test", 80),
                    "scheme": "http",
                    "root_path": "",
                },
                receive,
                send,
            )
        finally:
            mcp_server.mcp.session_manager.handle_request = original

    anyio.run(main)
    return bool(captured.get("reached"))


# --------------------------------------------------------------------------
# PAT 生命周期
# --------------------------------------------------------------------------


def test_pat_create_list_revoke_delete_flow(client):
    """PAT 全生命周期:创建返明文一次 → 列表只有 prefix → 删除后彻底失效。"""
    c, _ = client
    tok = _register(c, "pat-flow@example.com")["access_token"]
    created = _create_pat(c, tok, name="Claude")
    assert created.status_code == 201
    pat = created.json()["token"]
    assert pat.startswith("bcmcp_")
    assert created.json()["prefix"] == pat[:14]

    listed = c.get("/api/v1/profile/pats", headers=_auth(tok))
    assert listed.status_code == 200
    items = listed.json()
    assert len(items) == 1
    assert "token" not in items[0]
    assert pat not in json.dumps(items)

    deleted = c.delete(f"/api/v1/profile/pats/{created.json()['id']}", headers=_auth(tok))
    assert deleted.status_code == 204
    assert c.get("/api/v1/profile/pats", headers=_auth(tok)).json() == []


def test_pat_cannot_be_created_by_pat(client):
    """PAT 不能自管 PAT(防泄漏后自我续期/升权)。"""
    c, _ = client
    tok = _register(c, "pat-self@example.com")["access_token"]
    pat = _create_pat(c, tok).json()["token"]
    assert c.get("/api/v1/profile/pats", headers=_auth(pat)).status_code == 403
    assert _create_pat(c, pat, name="self", scopes=["mcp:write"]).status_code == 403


def test_pat_cannot_be_used_on_regular_api(client):
    """PAT 走常规 API → 403(严格分流)。"""
    c, _ = client
    tok = _register(c, "pat-mix@example.com")["access_token"]
    pat = _create_pat(c, tok).json()["token"]
    for path in ("/api/v1/read/ledgers", "/api/v1/profile/me", "/api/v1/devices"):
        assert c.get(path, headers=_auth(pat)).status_code == 403, path
    # 写路径同样拒绝(POST /write/ledgers 需要 web_write)
    assert c.post(
        "/api/v1/write/ledgers", headers=_auth(pat), json={"ledger_name": "x"}
    ).status_code == 403


def test_jwt_cannot_be_used_on_mcp_endpoint(client):
    """JWT access token 打 MCP → 403。"""
    c, _ = client
    tok = _register(c, "jwt-mcp@example.com")["access_token"]
    assert _mcp_post(c, tok, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code == 403


def test_mcp_requires_pat_and_rejects_anonymous(client):
    c, _ = client
    # 无 Authorization
    assert c.post(
        "/api/v1/mcp",
        headers={"Accept": "application/json, text/event-stream", "Content-Type": "application/json"},
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    ).status_code == 401
    # 幽灵 PAT
    assert _mcp_post(c, "bcmcp_deadbeefdeadbeef", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code == 401


def test_deleted_pat_is_immediately_rejected(client):
    c, _ = client
    tok = _register(c, "pat-del@example.com")["access_token"]
    created = _create_pat(c, tok).json()
    pat, pid = created["token"], created["id"]
    assert c.delete(f"/api/v1/profile/pats/{pid}", headers=_auth(tok)).status_code == 204
    assert _mcp_post(c, pat, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code == 401


def test_expired_pat_rejected(client):
    c, TS = client
    tok = _register(c, "pat-exp@example.com")["access_token"]
    created = _create_pat(c, tok).json()
    db = TS()
    row = db.get(PersonalAccessToken, created["id"])
    row.expires_at = datetime.now(timezone.utc) - timedelta(days=1)
    db.commit()
    db.close()
    assert _mcp_post(c, created["token"], {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code == 401


def test_pat_of_disabled_user_rejected(client):
    c, TS = client
    tok = _register(c, "pat-dis@example.com")["access_token"]
    created = _create_pat(c, tok).json()
    db = TS()
    from src.models import User

    user = db.scalar(select(User).where(User.email == "pat-dis@example.com"))
    user.is_enabled = False
    db.commit()
    db.close()
    assert _mcp_post(c, created["token"], {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code == 403


def test_pat_of_deleted_user_rejected(client):
    c, TS = client
    tok = _register(c, "pat-gone@example.com")["access_token"]
    created = _create_pat(c, tok).json()
    db = TS()
    from src.models import User

    user = db.scalar(select(User).where(User.email == "pat-gone@example.com"))
    # FK ondelete=CASCADE 在 sqlite 需显式删 PAT 行;这里手工模拟级联
    for row in db.scalars(select(PersonalAccessToken).where(PersonalAccessToken.user_id == user.id)):
        db.delete(row)
    db.delete(user)
    db.commit()
    db.close()
    assert _mcp_post(c, created["token"], {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code == 401


# --------------------------------------------------------------------------
# PAT 越权(跨用户)与 scope 边界
# --------------------------------------------------------------------------


def test_pat_cross_user_management_forbidden(client):
    """B 不能 list / patch / delete A 的 PAT。"""
    c, _ = client
    a = _register(c, "pat-a@example.com")["access_token"]
    b = _register(c, "pat-b@example.com")["access_token"]
    created = _create_pat(c, a, name="a-token").json()

    assert c.get("/api/v1/profile/pats", headers=_auth(b)).json() == []
    assert c.patch(
        f"/api/v1/profile/pats/{created['id']}", headers=_auth(b), json={"name": "pwn"}
    ).status_code == 404
    assert c.delete(f"/api/v1/profile/pats/{created['id']}", headers=_auth(b)).status_code == 404
    # A 的 token 仍然可用
    assert _mcp_tools_list_ok(created["token"]), "A 的 PAT 被 B 的操作影响"


def test_pat_scope_values_are_strict(client):
    """scope 只接受字面 `mcp:read` / `mcp:write`;大小写、空格、越权值全 422。"""
    c, _ = client
    tok = _register(c, "pat-scope@example.com")["access_token"]
    for scopes in (
        ["mcp:ADMIN"],
        ["mcp:read "],
        [" mcp:read"],
        ["MCP:READ"],
        ["mcp:read:all"],
        ["web_write"],
        ["*"],
    ):
        res = _create_pat(c, tok, scopes=scopes)
        assert res.status_code == 422, f"非法 scope {scopes!r} 应 422,实际 {res.status_code}"
    assert _create_pat(c, tok, scopes=[]).status_code == 422
    assert _create_pat(c, tok, name="n" * 129).status_code == 422
    assert _create_pat(c, tok, name="n" * 128).status_code == 201


def test_pat_update_scopes_strict_and_cannot_extend_expiry(client):
    """PATCH 不能改 expires_at;scope 非法值 422。"""
    c, _ = client
    tok = _register(c, "pat-patch@example.com")["access_token"]
    created = _create_pat(c, tok, scopes=["mcp:read"]).json()
    # 未声明的 expires_in_days 被忽略(pydantic 默认 ignore extra)
    res = c.patch(
        f"/api/v1/profile/pats/{created['id']}",
        headers=_auth(tok),
        json={"scopes": ["mcp:read", "mcp:write"], "expires_in_days": 9999},
    )
    assert res.status_code == 200
    assert res.json()["scopes"] == ["mcp:read", "mcp:write"]
    assert res.json()["expires_at"] == created["expires_at"], "expires_at 不应被改动"
    assert c.patch(
        f"/api/v1/profile/pats/{created['id']}", headers=_auth(tok), json={"scopes": ["mcp:root"]}
    ).status_code == 422


# --------------------------------------------------------------------------
# app scope 与 rw 端点隔离(ALLOW_APP_RW_SCOPES=false,conftest 已设)
# --------------------------------------------------------------------------


def test_app_scope_token_blocked_from_web_write_and_read(client):
    """app 客户端 token(只有 app_write)不得读写 web 端点。

    注意 `/api/v1/profile/pats` 的 scope dep 是 require_any_scopes(app_write,
    web_read, web_write)(src/routers/pats.py:_AUTH_SCOPE_DEP),所以 app token
    **可以**列 PAT —— 这是有意为之的 laxity,记录在 HARDENING 测试里。
    """
    c, _ = client
    app_tok = _register(c, "appscope@example.com", client_type="app")["access_token"]
    assert c.get("/api/v1/read/ledgers", headers=_auth(app_tok)).status_code == 403
    assert c.get("/api/v1/devices", headers=_auth(app_tok)).status_code == 403
    assert c.post(
        "/api/v1/write/ledgers", headers=_auth(app_tok), json={"ledger_name": "x"}
    ).status_code == 403


def test_app_scope_token_can_list_own_pats(client):
    """app token 能列/建自己 PAT。

    HARDENING: src/routers/pats.py:43-45 `_AUTH_SCOPE_DEP = require_any_scopes(
    app_write, web_read, web_write)` —— 移动端(app_write)也能管理 MCP token。
    与 "PAT 管理必须用 access token" 的注释一致,但 scope 集合比注释更宽。
    不构成越权(仅限本人),记录现状。
    """
    c, _ = client
    app_tok = _register(c, "apppat@example.com", client_type="app")["access_token"]
    assert c.get("/api/v1/profile/pats", headers=_auth(app_tok)).status_code == 200
    assert _create_pat(c, app_tok, name="from-app").status_code == 201


def test_web_token_scopes_are_exactly_read_write_ops(client):
    """web token 的 scopes 只含 web_read/web_write/ops_write(不得含 mcp:*)。"""
    body = _register(client[0], "websco@example.com", client_type="web")
    assert set(body["scopes"]) == {"web_read", "web_write", "ops_write"}
    assert not any(s.startswith("mcp:") for s in body["scopes"])


def test_app_token_cannot_reach_admin_endpoints(client):
    """app token / 普通 web token 都不能打 admin 端点。"""
    c, _ = client
    app_tok = _register(c, "admapp@example.com", client_type="app")["access_token"]
    web_tok = _register(c, "admweb@example.com", client_type="web")["access_token"]
    for tok in (app_tok, web_tok):
        for path in (
            "/api/v1/admin/users",
            "/api/v1/admin/overview",
            "/api/v1/admin/logs",
            "/api/v1/admin/ai-analysis-logs",
            "/api/v1/admin/backup/remotes",
            "/api/v1/admin/backup/rclone-config",
            "/api/v1/admin/debug/snapshot/anything",
        ):
            code = c.get(path, headers=_auth(tok)).status_code
            assert code == 403, f"{path} 应 403,实际 {code}"


# --------------------------------------------------------------------------
# scope 提升攻击:refresh 是否能把 scope 放大
# --------------------------------------------------------------------------


def test_refresh_cannot_escalate_scopes(client):
    """伪造 refresh token 的 scopes(带 mcp:write / app_write)不能放大权限。

    HARDENING: src/routers/auth.py:refresh 从**请求体 token 的 payload** 读 scopes
    并在无 scopes 时回落到 `_resolve_scopes(client_type)`。攻击者无法重签
    (需 jwt_secret),所以此路径不可利用;但 scopes 来自客户端可控的 token
    payload 而非服务端存储,属脆弱设计。此处断言权限没有被放大。
    """
    c, _ = client
    body = _register(c, "refresh-esc@example.com", client_type="app")
    refresh = body["refresh_token"]
    import jwt as pyjwt

    from src.config import get_settings

    settings = get_settings()
    forged = pyjwt.encode(
        {
            "sub": body["user"]["id"],
            "type": "refresh",
            "client_type": "app",
            "scopes": ["web_write", "ops_write", "mcp:write"],
            "jti": "forged",
            "iat": int(datetime.now(timezone.utc).timestamp()),
            "exp": int((datetime.now(timezone.utc) + timedelta(days=1)).timestamp()),
        },
        "wrong-secret",
        algorithm="HS256",
    )
    assert c.post("/api/v1/auth/refresh", json={"refresh_token": forged}).status_code == 401
    # 合法 refresh 只拿到 app_write
    refreshed = c.post("/api/v1/auth/refresh", json={"refresh_token": refresh})
    assert refreshed.status_code == 200
    assert set(refreshed.json()["scopes"]) == {"app_write"}
    assert c.get("/api/v1/read/ledgers", headers=_auth(refreshed.json()["access_token"])).status_code == 403


def test_refresh_token_rotation_revokes_old_one(client):
    """refresh 轮换:旧 refresh token 立刻失效。"""
    c, _ = client
    body = _register(c, "rotate@example.com")
    first = body["refresh_token"]
    second = c.post("/api/v1/auth/refresh", json={"refresh_token": first})
    assert second.status_code == 200
    assert c.post("/api/v1/auth/refresh", json={"refresh_token": first}).status_code == 401
    assert c.post(
        "/api/v1/auth/refresh", json={"refresh_token": second.json()["refresh_token"]}
    ).status_code == 200


def test_logout_revokes_only_own_refresh_token(client):
    """A 不能通过 logout 撤销 B 的 refresh token(按 user_id 过滤)。"""
    c, _ = client
    a = _register(c, "lo-a@example.com")
    b = _register(c, "lo-b@example.com")
    res = c.post(
        "/api/v1/auth/logout",
        headers=_auth(a["access_token"]),
        json={"refresh_token": b["refresh_token"]},
    )
    assert res.status_code == 200
    # B 的 refresh 仍然有效
    assert c.post(
        "/api/v1/auth/refresh", json={"refresh_token": b["refresh_token"]}
    ).status_code == 200


# --------------------------------------------------------------------------
# Idempotency-Key
# --------------------------------------------------------------------------


def _create_ledger(client, token: str, ext: str = "idem-ledger") -> str:
    res = client.post(
        "/api/v1/write/ledgers",
        headers=_auth(token),
        json={"ledger_id": ext, "ledger_name": ext, "currency": "CNY"},
    )
    assert res.status_code == 200, res.text
    return res.json()["entity_id"]


def _create_tx(client, token, ledger: str, *, key: str | None, payload=None, device: str = "d-web"):
    headers = _auth(token, device)
    if key:
        headers = {**headers, "Idempotency-Key": key}
    body = payload or {
        "base_change_id": 0,
        "tx_type": "expense",
        "amount": 12.5,
        "happened_at": "2026-05-06T12:30:00Z",
        "note": "idem-note",
    }
    return client.post(f"/api/v1/write/ledgers/{ledger}/transactions", headers=headers, json=body)


def test_idempotency_key_replay_creates_single_transaction(client):
    """同 key 同 body 重放 → 只有一笔,第二次 idempotency_replayed=True。"""
    c, _ = client
    tok = _register(c, "idem1@example.com")["access_token"]
    ledger = _create_ledger(c, tok)
    r1 = _create_tx(c, tok, ledger, key="k-1")
    r2 = _create_tx(c, tok, ledger, key="k-1")
    assert (r1.status_code, r2.status_code) == (200, 200)
    assert r1.json()["idempotency_replayed"] is False
    assert r2.json()["idempotency_replayed"] is True
    assert r1.json()["new_change_id"] == r2.json()["new_change_id"]
    listed = c.get(f"/api/v1/read/ledgers/{ledger}/transactions", headers=_auth(tok)).json()
    assert len([t for t in listed if (t.get("note") or "") == "idem-note"]) == 1


def test_idempotency_key_reuse_with_different_body_returns_409(client):
    """同 key 不同 body → 409(不得静默产生第二笔)。"""
    c, _ = client
    tok = _register(c, "idem2@example.com")["access_token"]
    ledger = _create_ledger(c, tok)
    assert _create_tx(c, tok, ledger, key="k-2").status_code == 200
    changed = _create_tx(c, tok, ledger, key="k-2", payload={
        "base_change_id": 0, "tx_type": "expense", "amount": 99.0,
        "happened_at": "2026-05-06T12:30:00Z", "note": "idem-note",
    })
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "IDEMPOTENCY_KEY_REUSED"
    listed = c.get(f"/api/v1/read/ledgers/{ledger}/transactions", headers=_auth(tok)).json()
    assert len([t for t in listed if (t.get("note") or "") == "idem-note"]) == 1


def test_idempotency_key_scope_is_per_device_and_user(client):
    """同 key 换 device / 换用户 → 视为不同请求(键含 user_id + device_id)。

    HARDENING: 重放判定按 (user_id, device_id, idempotency_key) 三元组
    (src/models.py:610 SyncPushIdempotency),符合语义;但同一客户端忘记换
    key 而 device header 变化时会静默产生第二笔。记录现状。
    """
    c, _ = client
    tok = _register(c, "idem3@example.com")["access_token"]
    other = _register(c, "idem4@example.com")["access_token"]
    ledger = _create_ledger(c, tok)
    r1 = _create_tx(c, tok, ledger, key="k-3", device="dev-A")
    r2 = _create_tx(c, tok, ledger, key="k-3", device="dev-B")
    assert r1.status_code == r2.status_code == 200
    assert r2.json()["idempotency_replayed"] is False, "不同 device 视为新请求"
    # 另一用户用同 key 不受影响
    other_ledger = _create_ledger(c, other, "idem-ledger-b")
    r3 = _create_tx(c, other, other_ledger, key="k-3")
    assert r3.status_code == 200 and r3.json()["idempotency_replayed"] is False


def test_idempotency_key_on_delete_and_batch_endpoints(client):
    """批量删除端点也支持幂等重放(同 key 同 body)。"""
    c, _ = client
    tok = _register(c, "idem5@example.com")["access_token"]
    ledger = _create_ledger(c, tok, "idem-batch")
    created = c.post(
        f"/api/v1/write/ledgers/{ledger}/transactions/batch",
        headers=_auth(tok),
        json={
            "base_change_id": 0,
            "transactions": [
                {"tx_type": "expense", "amount": 1.0, "happened_at": "2026-05-06T12:30:00Z"}
            ],
            "auto_ai_tag": False,
            "locale": "zh",
        },
    )
    assert created.status_code == 200
    tx_ids = created.json()["created_sync_ids"]
    body = {"tx_ids": tx_ids, "base_change_id": 0}
    h = {**_auth(tok), "Idempotency-Key": "k-batch"}
    r1 = c.post(f"/api/v1/write/ledgers/{ledger}/transactions/batch/delete", headers=h, json=body)
    r2 = c.post(f"/api/v1/write/ledgers/{ledger}/transactions/batch/delete", headers=h, json=body)
    assert r1.status_code == r2.status_code == 200, (r1.text[:200], r2.text[:200])


def test_idempotency_key_huge_value_rejected_not_500(client):
    """超长 Idempotency-Key 不应 500(SyncPushIdempotency.idempotency_key 是
    String(128);SQLite 不截断,Postgres 会 DataError)。"""
    c, _ = client
    tok = _register(c, "idem6@example.com")["access_token"]
    ledger = _create_ledger(c, tok, "idem-huge")
    res = _create_tx(c, tok, ledger, key="K" * 5000)
    assert res.status_code != 500, f"超长 Idempotency-Key 导致 500:{res.text[:200]}"
    assert res.status_code in (200, 400, 413, 422)


# --------------------------------------------------------------------------
# app scope 跨账本注入(sync/push 与 rw 端点)
# --------------------------------------------------------------------------


def test_app_push_with_foreign_ledger_id_does_not_corrupt_victim_ledger(client):
    """B 用 app token 推 A 的 ledger_id → 不得写入 A 的账本。

    HARDENING: 服务端按 (user_id, external_id) 复合唯一自动建 B 自己的同名
    账本(src/routers/sync/push.py:auto-create 分支),A 的数据不受影响。
    记账客户端 syncId 冲突时的静默分裂风险由 ghost-ledger guard 部分覆盖。
    """
    c, TS = client
    a_web = _register(c, "push-a@example.com", "web")["access_token"]
    b_body = _register(c, "push-b@example.com", "app")
    b_app, b_dev = b_body["access_token"], b_body["device_id"]

    assert c.post(
        "/api/v1/write/ledgers", headers=_auth(a_web),
        json={"ledger_id": "shared-ext", "ledger_name": "A-own", "currency": "CNY"},
    ).status_code == 200
    assert c.post(
        "/api/v1/write/ledgers/shared-ext/transactions", headers=_auth(a_web),
        json={"base_change_id": 0, "tx_type": "expense", "amount": 111,
              "happened_at": "2026-05-06T12:00:00Z", "note": "A-secret"},
    ).status_code == 200

    pushed = c.post(
        "/api/v1/sync/push",
        headers=_auth(b_app, b_dev),
        json={"device_id": b_dev, "changes": [{
            "ledger_id": "shared-ext", "entity_type": "transaction", "entity_sync_id": "b-inject",
            "action": "upsert",
            "payload": {"syncId": "b-inject", "type": "expense", "amount": 999,
                        "happenedAt": "2026-05-06T12:00:00Z", "categoryName": "c",
                        "categoryKind": "expense", "accountName": "a"},
            "updated_at": datetime.now(timezone.utc).isoformat()}]},
    )
    assert pushed.status_code == 200

    # A 的账本没被污染
    a_tx = c.get("/api/v1/read/ledgers/shared-ext/transactions", headers=_auth(a_web)).json()
    notes = [t.get("note") for t in a_tx]
    assert "A-secret" in notes
    assert all(t.get("id") != "b-inject" for t in a_tx), "B 的注入进入了 A 的账本"
    # B 侧数据落在自己的同名账本(数据分裂,但非越权)
    db = TS()
    from src.models import Ledger

    rows = db.scalars(select(Ledger).where(Ledger.external_id == "shared-ext")).all()
    assert len(rows) == 2, "两个用户各有一份同名 external_id 账本"
    db.close()


def test_app_push_snapshot_delete_on_foreign_ledger_is_noop_for_victim(client):
    """B 推 A 的 ledger_snapshot delete → A 的账本不得被标记删除。"""
    c, _ = client
    a_web = _register(c, "snap-a@example.com", "web")["access_token"]
    b_body = _register(c, "snap-b@example.com", "app")
    b_app, b_dev = b_body["access_token"], b_body["device_id"]
    c.post("/api/v1/write/ledgers", headers=_auth(a_web),
           json={"ledger_id": "snap-ext", "ledger_name": "A-snap", "currency": "CNY"})

    res = c.post(
        "/api/v1/sync/push",
        headers=_auth(b_app, b_dev),
        json={"device_id": b_dev, "changes": [{
            "ledger_id": "snap-ext", "entity_type": "ledger_snapshot", "entity_sync_id": "snap-ext",
            "action": "delete", "payload": {},
            "updated_at": datetime.now(timezone.utc).isoformat()}]},
    )
    assert res.status_code == 200
    assert c.get("/api/v1/read/ledgers/snap-ext", headers=_auth(a_web)).status_code == 200, (
        "A 的账本被 B 的 snapshot delete 打成了 tombstone"
    )


def test_idempotency_records_do_not_leak_across_users(client):
    """Idempotency 记录按 user 隔离(A 的重放响应不能被 B 读到)。"""
    c, TS = client
    a = _register(c, "idem-iso-a@example.com")["access_token"]
    b = _register(c, "idem-iso-b@example.com")["access_token"]
    la = _create_ledger(c, a, "iso-a")
    lb = _create_ledger(c, b, "iso-b")
    assert _create_tx(c, a, la, key="iso-key").status_code == 200
    rb = _create_tx(c, b, lb, key="iso-key")
    assert rb.status_code == 200
    assert rb.json()["idempotency_replayed"] is False
    db = TS()
    rows = db.scalars(
        select(SyncPushIdempotency).where(SyncPushIdempotency.idempotency_key == "iso-key")
    ).all()
    assert len({r.user_id for r in rows}) == 2, "两用户各有一条独立幂等记录"
    db.close()
