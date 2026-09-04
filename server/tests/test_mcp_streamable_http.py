"""MCP transport 换成 Streamable HTTP 的挂载 + 分流测试.

背景:SmartBook Cloud 的 MCP 起初只暴露官方已弃用(deprecated)的老式 SSE
transport(`GET /api/v1/mcp/sse` + `POST /api/v1/mcp/messages/`)。只支持新版
Streamable HTTP(单端点)的客户端(如 Hermes 内置 HTTP MCP 客户端)连过来时,
POST 命中 SSE 的 `/sse` GET-only 路由 → 405,连不上。

决策:**直接替换**成 Streamable HTTP —— 对外单端点 `POST /api/v1/mcp`
(与 `.well-known/oauth-protected-resource` 的 `resource` 对齐),复用同一批
tool + 同一套 PAT 鉴权,不再保留 SSE(小众高级功能、存量客户端极少,breaking
change 可接受)。

测试策略沿用 test_mcp_sse_handshake.py 的边界:**不做 live handshake**
(httpx + ASGITransport 的 stream 在 anyio task group 收尾时易挂死 pytest),
只在结构 / 开关 / 分流层验证:
  1. 挂载的 MCP app 内层是 Streamable HTTP(StreamableHTTPASGIApp),不再是
     SSE —— 证明是"替换"而非并存,且外层仍套 PAT 鉴权
  2. transport 用 stateless + json_response(决定反代后行为的开关)
  3. 带合法 PAT 的 POST 真的被分流到 streamable session manager —— 把
     handle_request monkeypatch 成 stub,不触碰真实 anyio task group,不挂死。
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from uuid import uuid4

from fastapi.testclient import TestClient
from mcp.server.fastmcp.server import StreamableHTTPASGIApp
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.config import get_settings
from src.database import Base, get_db
from src.main import app
from src.mcp import auth as mcp_auth
from src.mcp import server as mcp_server
from src.mcp.auth import PATAuthMiddleware
from src.models import PersonalAccessToken, User
from src.security import generate_pat, hash_password


def _bootstrap(monkeypatch):
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
    monkeypatch.setattr(mcp_auth, "SessionLocal", Session)
    return Session


def _seed_pat(Session) -> str:
    plaintext, h, pfx = generate_pat()
    with Session() as db:
        u = User(
            id=str(uuid4()),
            email="stream@x",
            password_hash=hash_password("x"),
            is_admin=False,
            is_enabled=True,
            created_at=datetime.now(timezone.utc),
        )
        db.add(u)
        db.flush()
        db.add(
            PersonalAccessToken(
                id=str(uuid4()),
                user_id=u.id,
                name="stream-probe",
                token_hash=h,
                prefix=pfx,
                scopes_json=json.dumps(["mcp:read", "mcp:write"]),
                created_at=datetime.now(timezone.utc),
            )
        )
        db.commit()
    return plaintext


def test_mcp_endpoint_is_streamable_http_not_sse() -> None:
    """挂载的 MCP app 必须是 Streamable HTTP(替换掉老 SSE),且外层仍套 PAT
    鉴权中间件 —— 不能裸奔。"""
    assert isinstance(mcp_server.app, PATAuthMiddleware)
    assert isinstance(mcp_server.app.app, StreamableHTTPASGIApp), (
        "MCP 挂载应为 Streamable HTTP,老 SSE 已被替换"
    )


def test_mcp_transport_is_stateless_json() -> None:
    """streamable 走 stateless + json_response:无状态适合反代/无粘性负载,
    单次 JSON 响应对内置 HTTP 客户端最省心。"""
    assert mcp_server.mcp.settings.stateless_http is True
    assert mcp_server.mcp.settings.json_response is True


def test_post_mcp_routes_to_session_manager(monkeypatch) -> None:
    """带合法 PAT 的 POST /api/v1/mcp 必须被分流进 streamable session manager
    (证明单端点真的接上了 Streamable HTTP transport)。

    monkeypatch handle_request 成 stub,避开真实 anyio task group(没 run()),
    不挂死。"""
    Session = _bootstrap(monkeypatch)
    pat = _seed_pat(Session)

    hits: dict[str, bool] = {}

    async def fake_handle_request(scope, receive, send):
        hits["called"] = True
        await send({"type": "http.response.start", "status": 202, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    monkeypatch.setattr(
        mcp_server.mcp.session_manager, "handle_request", fake_handle_request
    )

    try:
        client = TestClient(app)
        res = client.post(
            f"{get_settings().api_prefix}/mcp",
            headers={
                "Authorization": f"Bearer {pat}",
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
            },
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        )
        assert hits.get("called") is True, "POST 没有分流到 streamable session manager"
        assert res.status_code == 202
    finally:
        app.dependency_overrides.clear()


def test_post_mcp_without_trailing_slash_not_redirected(monkeypatch) -> None:
    """POST /api/v1/mcp(无尾斜杠)必须直接命中端点,不能 307 重定向到
    /api/v1/mcp/。内置 HTTP 客户端(如 Hermes)未必跟随 307 的 POST —— 那正是
    这次要根治的连接问题,不能因为端点形态又引入一个新的连不上。"""
    Session = _bootstrap(monkeypatch)
    pat = _seed_pat(Session)

    hits: dict[str, bool] = {}

    async def fake_handle_request(scope, receive, send):
        hits["called"] = True
        await send({"type": "http.response.start", "status": 202, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    monkeypatch.setattr(
        mcp_server.mcp.session_manager, "handle_request", fake_handle_request
    )

    try:
        client = TestClient(app)
        res = client.post(
            f"{get_settings().api_prefix}/mcp",
            headers={
                "Authorization": f"Bearer {pat}",
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
            },
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            follow_redirects=False,
        )
        assert res.status_code != 307, (
            f"无尾斜杠端点被 307 重定向了(status={res.status_code}),"
            "内置 HTTP 客户端可能不跟随"
        )
        assert hits.get("called") is True, "POST 没有直接到达 streamable 端点"
    finally:
        app.dependency_overrides.clear()
