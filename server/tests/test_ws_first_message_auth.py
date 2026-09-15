"""W7: /ws 首条消息鉴权。

背景(docs/design-flaw-fix-plan-2026-09-15.md W7):token 走 URL query 会进
反代 / 服务端 access log,与「token 不进日志」的安全口径矛盾。改造后:

  - 新路径:裸连 /ws → 第一条消息 {"type":"auth","token":...} → 回
    {"type":"auth_ok"} → 之后行为与旧版一致(ping/pong 心跳)。
  - 认证前收到其它消息 / 超时未认证 → close(1008)。
  - 兼容路径:query token(mobile Flutter 客户端无法同步发版)保留原语义。
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool
from starlette.websockets import WebSocketDisconnect

from src.database import Base, get_db
from src.main import app
from src.routers import ws as ws_router


def _make_client() -> TestClient:
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
    # /ws 端点直接用模块级 SessionLocal 查 User 存在性(不走 get_db 依赖),
    # 指到同一个内存库。
    ws_router.SessionLocal = TS
    return TestClient(app)


@pytest.fixture()
def client(monkeypatch):
    c = _make_client()
    monkeypatch.setattr(ws_router, "AUTH_TIMEOUT_SECONDS", 10.0)
    yield c
    app.dependency_overrides.pop(get_db, None)


def _register(client: TestClient, email: str, client_type: str = "web") -> str:
    res = client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "123456",
            "client_type": client_type,
            "device_name": "pytest-ws",
            "platform": client_type,
        },
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def test_first_message_auth_ok_then_ping_pong(client: TestClient):
    token = _register(client, "ws-auth@example.com")
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "auth", "token": token}))
        assert json.loads(ws.receive_text()) == {"type": "auth_ok"}
        ws.send_text(json.dumps({"type": "ping"}))
        assert json.loads(ws.receive_text()) == {"type": "pong"}


def test_first_message_auth_rejects_bad_token(client: TestClient):
    _register(client, "ws-auth2@example.com")
    with client.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "auth", "token": "not-a-jwt"}))
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 1008


def test_first_message_must_be_auth(client: TestClient):
    token = _register(client, "ws-auth3@example.com")
    with client.websocket_connect("/ws") as ws:
        # 认证前发心跳(合法 token 没带在 auth 帧里)→ 拒绝。
        ws.send_text(json.dumps({"type": "ping", "token": token}))
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 1008


def test_query_token_legacy_path_still_works(client: TestClient):
    """mobile(Flutter)客户端用 query token 连接,不能被本次改造破坏。"""
    token = _register(client, "ws-auth4@example.com", client_type="app")
    with client.websocket_connect(f"/ws?token={token}") as ws:
        # 兼容路径不发 auth_ok —— 第一帧就应该是心跳应答。
        ws.send_text(json.dumps({"type": "ping"}))
        assert json.loads(ws.receive_text()) == {"type": "pong"}


def test_query_token_invalid_rejected_before_accept(client: TestClient):
    _register(client, "ws-auth5@example.com")
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/ws?token=bogus"):
            pass


def test_auth_timeout_closes_connection(client: TestClient, monkeypatch):
    monkeypatch.setattr(ws_router, "AUTH_TIMEOUT_SECONDS", 0.2)
    _register(client, "ws-auth6@example.com")
    with client.websocket_connect("/ws") as ws:
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 1008
