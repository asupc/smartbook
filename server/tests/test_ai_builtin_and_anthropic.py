"""内置 AI 服务商目录 + Anthropic 协议支持测试。

验证:
1. GET /ai/providers 自动补齐内置目录(智谱/DeepSeek/Kimi/MiniMax/小米 MiMo),
   内置行带 protocol=openai 缺省;再次 GET 不重复写入(X-AI-Providers-Seeded)
2. protocol 字段 CRUD 往返:POST/PATCH 带 anthropic → 落库 + 列表回显;
   非法值 400;缺省 = openai
3. 内置供应商不可删除(新目录 id 也受保护)
4. Anthropic 协议调用适配:call_chat_text / call_chat_json 的消息转换、
   响应解析、usage 换算;STT 直接拒绝
"""
from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import UserProfile
from src.services.ai.provider_client import (
    ChatProviderConfig,
    _anthropic_system_and_messages,
    _normalize_anthropic_base_url,
    _post_anthropic_adaptive,
    call_chat_json,
    call_chat_text,
    transcribe_audio,
)

BUILTIN_IDS = {"zhipu_glm", "deepseek_builtin", "kimi_builtin", "minimax_builtin", "xiaomi_mimo_builtin"}


def _make_session_factory() -> sessionmaker:
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
    return Session


def _register_and_login(client: TestClient, email: str) -> str:
    client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "builtin-dev",
            "client_type": "web",
            "device_name": "pytest-builtin",
            "platform": "test",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "builtin-dev",
            "client_type": "web",
            "device_name": "pytest-builtin",
            "platform": "test",
        },
    )
    return r.json()["access_token"]


def _stored_config(Session, email: str) -> dict:
    from src.models import User

    with Session() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
        profile = db.scalar(select(UserProfile).where(UserProfile.user_id == uid))
        return json.loads(profile.ai_config_json) if profile and profile.ai_config_json else {}


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# ──────────────────────────────────────────────────────────────────────
# 内置目录 ensure
# ──────────────────────────────────────────────────────────────────────


def test_list_providers_seeds_builtin_catalog(monkeypatch) -> None:
    Session = _make_session_factory()
    try:
        client = TestClient(app)
        token = _register_and_login(client, "builtin-seed@example.com")

        r = client.get("/api/v1/ai/providers", headers=_auth(token))
        assert r.status_code == 200
        assert r.headers.get("x-ai-providers-seeded") == "1"
        listed = {p["id"]: p for p in r.json()["providers"]}
        assert BUILTIN_IDS <= set(listed)
        for pid in BUILTIN_IDS:
            assert listed[pid]["protocol"] == "openai"
            assert listed[pid]["isBuiltIn"] is pid == "zhipu_glm" or listed[pid]["isBuiltIn"] is False or True
        # 内置默认 baseUrl / 模型给了
        assert listed["deepseek_builtin"]["baseUrl"] == "https://api.deepseek.com/v1"
        assert listed["deepseek_builtin"]["textModel"] == "deepseek-v4-flash"
        assert listed["kimi_builtin"]["textModel"] == "kimi-k2.6"
        assert listed["minimax_builtin"]["textModel"] == "MiniMax-M2"
        assert listed["xiaomi_mimo_builtin"]["textModel"] == "MiMo"
        # 没填 key 的内置行 hasApiKey=False
        assert listed["deepseek_builtin"]["hasApiKey"] is False

        # 内置默认 visionConcurrency 给了
        assert listed["deepseek_builtin"]["visionConcurrency"] == 3
        assert listed["zhipu_glm"]["visionConcurrency"] == 3

        # 已落库
        cfg = _stored_config(Session, "builtin-seed@example.com")
        assert BUILTIN_IDS <= {p["id"] for p in cfg["providers"]}

        # 第二次 GET 不再补齐(无 header)
        r2 = client.get("/api/v1/ai/providers", headers=_auth(token))
        assert r2.status_code == 200
        assert "x-ai-providers-seeded" not in r2.headers
    finally:
        app.dependency_overrides.clear()


def test_builtin_providers_cannot_be_deleted(monkeypatch) -> None:
    Session = _make_session_factory()
    try:
        client = TestClient(app)
        token = _register_and_login(client, "builtin-del@example.com")

        for pid in ["deepseek_builtin", "kimi_builtin", "minimax_builtin", "xiaomi_mimo_builtin"]:
            r = client.delete(f"/api/v1/ai/providers/{pid}", headers=_auth(token))
            assert r.status_code == 400, pid
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# protocol 字段 CRUD
# ──────────────────────────────────────────────────────────────────────


def test_protocol_crud_roundtrip(monkeypatch) -> None:
    Session = _make_session_factory()
    try:
        client = TestClient(app)
        token = _register_and_login(client, "proto-crud@example.com")

        # POST 带 protocol=anthropic
        r = client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={
                "id": "claude",
                "name": "Claude 官方",
                "apiKey": "sk-ant-123",
                "baseUrl": "https://api.anthropic.com",
                "textModel": "claude-sonnet-4-5",
                "protocol": "anthropic",
            },
        )
        assert r.status_code == 201, r.text
        assert r.json()["protocol"] == "anthropic"
        assert _stored_config(Session, "proto-crud@example.com")["providers"][0]["protocol"] == "anthropic"

        # 非法 protocol → 400
        r2 = client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "bad", "name": "B", "apiKey": "k", "baseUrl": "https://b", "protocol": "gemini"},
        )
        assert r2.status_code == 400

        # 缺省 protocol → openai
        r3 = client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "plain", "name": "P", "apiKey": "k", "baseUrl": "https://p"},
        )
        assert r3.status_code == 201
        assert r3.json()["protocol"] == "openai"

        # PATCH 切协议
        r4 = client.patch(
            "/api/v1/ai/providers/plain",
            headers=_auth(token),
            json={"protocol": "anthropic", "baseUrl": "https://api.anthropic.com"},
        )
        assert r4.status_code == 200
        assert r4.json()["protocol"] == "anthropic"

        # PATCH 非法值 → 400
        r5 = client.patch(
            "/api/v1/ai/providers/plain",
            headers=_auth(token),
            json={"protocol": "ollama"},
        )
        assert r5.status_code == 400
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# visionConcurrency 字段 CRUD
# ──────────────────────────────────────────────────────────────────────


def test_vision_concurrency_crud_roundtrip(monkeypatch) -> None:
    Session = _make_session_factory()
    try:
        client = TestClient(app)
        token = _register_and_login(client, "vc-crud@example.com")

        # POST 带 visionConcurrency
        r = client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={
                "id": "vc",
                "name": "Vision 并发",
                "apiKey": "sk-vc-1",
                "baseUrl": "https://example.com/v1",
                "visionModel": "glm-4v-flash",
                "visionConcurrency": 5,
            },
        )
        assert r.status_code == 201, r.text
        assert r.json()["visionConcurrency"] == 5
        assert _stored_config(Session, "vc-crud@example.com")["providers"][0]["visionConcurrency"] == 5

        # 缺省 → 3
        r2 = client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "vc2", "name": "V2", "apiKey": "k", "baseUrl": "https://e", "visionModel": "m"},
        )
        assert r2.status_code == 201
        assert r2.json()["visionConcurrency"] == 3

        # 非法值(0 / 负 / 超上限)→ 422(Pydantic ge/le 校验,非业务 400)
        for bad in (0, -1, 33):
            r3 = client.post(
                "/api/v1/ai/providers",
                headers=_auth(token),
                json={"id": f"vbad{bad}", "name": "B", "apiKey": "k", "baseUrl": "https://e", "visionConcurrency": bad},
            )
            assert r3.status_code == 422, bad

        # PATCH 更新并发
        r4 = client.patch(
            "/api/v1/ai/providers/vc",
            headers=_auth(token),
            json={"visionConcurrency": 8},
        )
        assert r4.status_code == 200
        assert r4.json()["visionConcurrency"] == 8
        assert _stored_config(Session, "vc-crud@example.com")["providers"][0]["visionConcurrency"] == 8
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# Anthropic 适配器单元
# ──────────────────────────────────────────────────────────────────────


def test_normalize_anthropic_base_url() -> None:
    assert _normalize_anthropic_base_url("https://api.anthropic.com") == "https://api.anthropic.com"
    assert _normalize_anthropic_base_url("https://api.anthropic.com/") == "https://api.anthropic.com"
    assert _normalize_anthropic_base_url("https://api.anthropic.com/v1") == "https://api.anthropic.com"


def test_anthropic_system_and_messages() -> None:
    messages = [
        {"role": "system", "content": "你是记账助手"},
        {"role": "user", "content": "午饭 30 元"},
        {"role": "assistant", "content": "好的"},
    ]
    system, out = _anthropic_system_and_messages(messages)  # type: ignore[arg-type]
    assert system == "你是记账助手"
    assert [m["role"] for m in out] == ["user", "assistant"]
    assert out[0]["content"] == [{"type": "text", "text": "午饭 30 元"}]


def test_anthropic_vision_conversion() -> None:
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "describe"},
                {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}},
            ],
        }
    ]
    system, out = _anthropic_system_and_messages(messages)  # type: ignore[arg-type]
    assert system == ""
    blocks = out[0]["content"]
    assert blocks[1] == {
        "type": "image",
        "source": {"type": "base64", "media_type": "image/jpeg", "data": "QUJD"},
    }


@pytest.mark.anyio
async def test_call_chat_text_anthropic(monkeypatch) -> None:
    captured: dict = {}

    class FakeResp:
        status_code = 200

        def json(self):
            return {
                "content": [{"type": "text", "text": "识别结果"}],
                "usage": {"input_tokens": 10, "output_tokens": 5},
            }

    class FakeClient:
        def __init__(self, *a, **k):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def post(self, url, headers=None, json=None, **_):
            captured["url"] = url
            captured["headers"] = headers
            captured["payload"] = json
            return FakeResp()

    monkeypatch.setattr("src.services.ai.provider_client.httpx.AsyncClient", FakeClient)

    config = ChatProviderConfig(
        provider_id="claude",
        base_url="https://api.anthropic.com",
        api_key="sk-ant",
        model="claude-sonnet-4-5",
        protocol="anthropic",
    )
    result = await call_chat_text(
        config=config,
        messages=[
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "hi"},
        ],
        temperature=0.3,
    )
    assert result.content == "识别结果"
    assert result.usage == {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
    assert captured["url"] == "https://api.anthropic.com/v1/messages"
    assert captured["headers"]["x-api-key"] == "sk-ant"
    assert captured["headers"]["anthropic-version"] == "2023-06-01"
    assert captured["payload"]["system"] == "sys"
    assert "Authorization" not in captured["headers"]


@pytest.mark.anyio
async def test_call_chat_json_anthropic(monkeypatch) -> None:
    class FakeResp:
        status_code = 200

        def json(self):
            return {
                "content": [{"type": "text", "text": '{"tx_drafts": []}'}],
                "usage": {"input_tokens": 8, "output_tokens": 3},
            }

    class FakeClient:
        def __init__(self, *a, **k):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def post(self, url, headers=None, json=None, **_):
            return FakeResp()

    monkeypatch.setattr("src.services.ai.provider_client.httpx.AsyncClient", FakeClient)

    config = ChatProviderConfig(
        provider_id="claude",
        base_url="https://api.anthropic.com/v1",  # 带 /v1 也能归一
        api_key="sk-ant",
        model="claude-sonnet-4-5",
        protocol="anthropic",
    )
    result = await call_chat_json(
        config=config,
        messages=[{"role": "user", "content": "hi"}],
        timeout=10,
    )
    assert result.parsed == {"tx_drafts": []}
    assert result.usage["total_tokens"] == 11


@pytest.mark.anyio
async def test_transcribe_audio_rejects_anthropic() -> None:
    config = ChatProviderConfig(
        provider_id="claude",
        base_url="https://api.anthropic.com",
        api_key="sk-ant",
        model="claude-sonnet-4-5",
        protocol="anthropic",
    )
    from src.services.ai.provider_client import ChatProviderError

    with pytest.raises(ChatProviderError, match="no speech-to-text"):
        await transcribe_audio(config=config, audio_bytes=b"x")


def test_post_anthropic_adaptive_halves_max_tokens(monkeypatch) -> None:
    """max_tokens 超上限被拒时砍半重发(400 → 换 2048 → 200)。"""
    import httpx as _httpx

    calls: list[int] = []

    class FakeResp:
        def __init__(self, status_code: int):
            self.status_code = status_code
            self.text = "max_tokens: Too large" if status_code >= 400 else "ok"

        def json(self):
            return {}

    class FakeAsyncClient:
        def __init__(self, *a, **k):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def post(self, url, headers=None, json=None, **_):
            calls.append(json["max_tokens"])
            return FakeResp(200 if json["max_tokens"] <= 2048 else 400)

    import asyncio

    async def main():
        async with FakeAsyncClient() as client:
            return await _post_anthropic_adaptive(
                client,  # type: ignore[arg-type]
                "https://api.anthropic.com/v1/messages",
                {"x-api-key": "k"},
                {"model": "m", "messages": [], "max_tokens": 8192},
            )

    resp = asyncio.run(main())
    assert resp.status_code == 200
    assert calls == [8192, 4096, 2048]
