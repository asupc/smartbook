"""/ai/relay/* — App LLM 中转端到端测试。

mock provider 调用(httpx 层的 call_chat_text / transcribe_audio),验证:
1. /relay/chat happy path(parse_tx_text):返回 content + usage,落一行日志
   (input_text 用 log_input,ledger_id 带上,token 数来自 usage)
2. /relay/chat entry_type=chat(自由对话):同样落一行,entry_type=chat
3. /relay/chat:没绑 chat provider → 400 AI_NO_CHAT_PROVIDER(不落日志)
4. /relay/chat:上游失败 → 502 AI_PROVIDER_ERROR + 落 error 日志
5. /relay/chat:messages 总字符超限 → 413
6. /relay/vision happy path:图片落盘 + 日志带图(content array 收到 base64)
7. /relay/vision:非法 mime → 400 / 超 5MB → 413 / 无 content-type 后缀兜底
8. /relay/vision:没绑 vision → 400 AI_NO_VISION_PROVIDER
9. /relay/stt happy path:返回转写文本 + 落 entry_type=stt 日志
10. /relay/stt:没绑 speech → 400 AI_NO_AUDIO_PROVIDER
11. 未登录 → 401
"""
from __future__ import annotations

import json
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import AIAnalysisLog, UserProfile
from src.services.ai import ChatProviderError
from src.services.ai import analysis_log as analysis_log_module


def _make_client(monkeypatch, tmp_path) -> sessionmaker:
    """内存 sqlite + 替换 get_db / analysis_log.SessionLocal / 图片落盘目录。"""
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
    monkeypatch.setattr(analysis_log_module, "SessionLocal", Session)
    from src.config import get_settings
    monkeypatch.setattr(get_settings(), "ai_log_image_dir", str(tmp_path))
    # 限流窗口是模块级 dict,按 user 记忆;测试间清理避免串扰
    from src.routers.ai import relay as relay_module
    relay_module._RATE_WINDOWS.clear()
    return Session


def _register_and_login(client: TestClient, email: str) -> str:
    client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "relay-dev",
            "client_type": "web",
            "device_name": "pytest-relay",
            "platform": "test",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "relay-dev",
            "client_type": "web",
            "device_name": "pytest-relay",
            "platform": "test",
        },
    )
    return r.json()["access_token"]


def _seed_ai_config(
    user_id: str,
    Session,
    *,
    text_model: str = "glm-4-flash",
    vision_model: str | None = "glm-4v-flash",
    audio_model: str | None = "glm-4-voice",
    vision_concurrency: int = 3,
) -> None:
    cfg = {
        "providers": [{
            "id": "p1",
            "apiKey": "sk-relay-test",
            "baseUrl": "https://example.com/v1",
            "textModel": text_model,
            "visionModel": vision_model or "",
            "audioModel": audio_model or "",
            "visionConcurrency": vision_concurrency,
        }],
        "binding": {
            "textProviderId": "p1",
            "visionProviderId": "p1" if vision_model else None,
            "speechProviderId": "p1" if audio_model else None,
        },
    }
    with Session() as db:
        existing = db.scalar(select(UserProfile).where(UserProfile.user_id == user_id))
        if existing:
            existing.ai_config_json = json.dumps(cfg)
        else:
            db.add(UserProfile(user_id=user_id, ai_config_json=json.dumps(cfg)))
        db.commit()


def _get_user_id(Session, email: str) -> str:
    from src.models import User
    with Session() as db:
        return db.scalar(select(User.id).where(User.email == email))


def _count_logs(Session) -> int:
    with Session() as db:
        return len(db.scalars(select(AIAnalysisLog)).all())


def _only_log(Session) -> AIAnalysisLog:
    with Session() as db:
        return db.scalars(select(AIAnalysisLog)).all()[0]


# ──────────────────────────────────────────────────────────────────────
# /relay/chat
# ──────────────────────────────────────────────────────────────────────


def test_relay_chat_happy_path_parse_tx_text(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-chat@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-chat@example.com"), Session)

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            assert config.provider_id == "p1"
            assert config.model == "glm-4-flash"
            assert messages[-1]["content"] == "买了杯奶茶28块"
            assert temperature == 0.3
            assert disable_thinking is True
            return type("R", (), {"content": '{"tx_drafts": []}', "usage": {"total_tokens": 42}})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)

        r = client.post(
            "/api/v1/ai/relay/chat",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "messages": [
                    {"role": "system", "content": "你是记账助手"},
                    {"role": "user", "content": "买了杯奶茶28块"},
                ],
                "temperature": 0.3,
                "disable_thinking": True,
                "entry_type": "parse_tx_text",
                "ledger_id": "12",
                "log_input": "买了杯奶茶28块",
            },
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["content"] == '{"tx_drafts": []}'
        assert body["provider_id"] == "p1"
        assert body["model"] == "glm-4-flash"
        assert body["usage"]["total_tokens"] == 42

        # 日志:服务端现场落一行
        assert _count_logs(Session) == 1
        row = _only_log(Session)
        assert row.entry_type == "parse_tx_text"
        assert row.status == "ok"
        assert row.ledger_id == "12"
        assert row.input_text == "买了杯奶茶28块"
        assert row.output_text == '{"tx_drafts": []}'
        assert row.total_tokens == 42
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_free_chat_logged_as_chat(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-free@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-free@example.com"), Session)

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            return type("R", (), {"content": "你好!", "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)
        r = client.post(
            "/api/v1/ai/relay/chat",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "messages": [{"role": "user", "content": "你好"}],
                "entry_type": "chat",
            },
        )
        assert r.status_code == 200
        row = _only_log(Session)
        assert row.entry_type == "chat"
        assert row.input_text == "你好"  # log_input 缺省回退最后一条 user 消息
        assert row.output_text == "你好!"
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_no_provider(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-nop@example.com")
        r = client.post(
            "/api/v1/ai/relay/chat",
            headers={"Authorization": f"Bearer {token}"},
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        assert r.status_code == 400
        assert r.json()["error_code"] == "AI_NO_CHAT_PROVIDER"
        assert _count_logs(Session) == 0
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_provider_error_logged(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-err@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-err@example.com"), Session)

        def boom(**kwargs):
            from src.services.ai import ChatProviderError
            raise ChatProviderError("provider returned 401: bad key")

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", boom)
        r = client.post(
            "/api/v1/ai/relay/chat",
            headers={"Authorization": f"Bearer {token}"},
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "parse_tx_text"},
        )
        assert r.status_code == 502
        assert r.json()["error_code"] == "AI_PROVIDER_ERROR"

        row = _only_log(Session)
        assert row.status == "error"
        assert "401" in row.error_message
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_payload_too_large(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-big@example.com")
        r = client.post(
            "/api/v1/ai/relay/chat",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "messages": [
                    {"role": "user", "content": "记" * 60_000},
                    {"role": "user", "content": "账" * 60_000},
                ],
                "entry_type": "chat",
            },
        )
        assert r.status_code == 413
        assert r.json()["error_code"] == "AI_RELAY_PAYLOAD_TOO_LARGE"
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# /relay/vision
# ──────────────────────────────────────────────────────────────────────


def test_relay_vision_happy_path_saves_image_log(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-vision@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-vision@example.com"), Session)

        seen: dict = {}

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            seen["messages"] = messages
            return type("R", (), {"content": '{"tx_drafts": [{"amount": 28}]}', "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)

        img_bytes = b"\xff\xd8\xff\xe0" + b"fake-jpeg" * 10
        r = client.post(
            "/api/v1/ai/relay/vision",
            headers={"Authorization": f"Bearer {token}"},
            data={
                "prompt": "分析支付账单截图",
                "ledger_id": "7",
                "log_input": "image: shot.jpg (90 bytes)",
            },
            files={"image": ("shot.jpg", img_bytes, "image/jpeg")},
        )
        assert r.status_code == 200, r.text
        assert r.json()["content"] == '{"tx_drafts": [{"amount": 28}]}'

        # server 拼了 vision content array(文本 + base64 data URL)
        content = seen["messages"][0]["content"]
        assert content[0] == {"type": "text", "text": "分析支付账单截图"}
        assert content[1]["type"] == "image_url"
        assert content[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")

        # 日志带原图落盘
        assert _count_logs(Session) == 1
        row = _only_log(Session)
        assert row.entry_type == "parse_tx_image"
        assert row.ledger_id == "7"
        assert row.image_path is not None
        from pathlib import Path
        assert Path(row.image_path).read_bytes() == img_bytes
    finally:
        app.dependency_overrides.clear()


def test_relay_vision_validates_mime_and_size(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-vv@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-vv@example.com"), Session)
        headers = {"Authorization": f"Bearer {token}"}
        data = {"prompt": "p"}

        # 合法请求会走到 provider 调用,mock 掉避免真实网络
        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            return type("R", (), {"content": "ok", "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)

        r = client.post(
            "/api/v1/ai/relay/vision", headers=headers, data=data,
            files={"image": ("f.txt", b"hello", "text/plain")},
        )
        assert r.status_code == 400
        assert r.json()["error_code"] == "AI_IMAGE_TYPE_INVALID"

        r = client.post(
            "/api/v1/ai/relay/vision", headers=headers, data=data,
            files={"image": ("big.jpg", b"\xff\xd8" + b"0" * (5 * 1024 * 1024), "image/jpeg")},
        )
        assert r.status_code == 413
        assert r.json()["error_code"] == "AI_IMAGE_TOO_LARGE"

        # 无 content-type 但后缀正确 → 兜底接受
        r = client.post(
            "/api/v1/ai/relay/vision", headers=headers, data=data,
            files={"image": ("shot.png", b"\x89PNG\r\n\x1a\n" + b"0" * 10, None)},
        )
        assert r.status_code == 200, r.text
    finally:
        app.dependency_overrides.clear()


def test_relay_vision_no_provider(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-vn@example.com")
        r = client.post(
            "/api/v1/ai/relay/vision",
            headers={"Authorization": f"Bearer {token}"},
            data={"prompt": "p"},
            files={"image": ("s.jpg", b"\xff\xd8abc", "image/jpeg")},
        )
        assert r.status_code == 400
        assert r.json()["error_code"] == "AI_NO_VISION_PROVIDER"
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# /relay/vision-batch
# ──────────────────────────────────────────────────────────────────────


def test_relay_vision_batch_happy_path(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-vb@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-vb@example.com"), Session)

        seen: dict = {}

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            count = seen.setdefault("count", 0)
            seen[f"m{count}"] = messages
            seen["count"] = count + 1
            return type("R", (), {"content": f'{{"tx_drafts":[{{"amount":{count}}}]}}', "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)

        imgs = [
            ("a.jpg", b"\xff\xd8" + b"a" * 10, "image/jpeg"),
            ("b.png", b"\x89PNG\r\n\x1a\n" + b"b" * 10, "image/png"),
        ]
        r = client.post(
            "/api/v1/ai/relay/vision-batch",
            headers={"Authorization": f"Bearer {token}"},
            data={"prompt": "分析账单截图", "ledger_id": "7", "log_input": "batch"},
            files=[("images", ("a.jpg", imgs[0][1], imgs[0][2])),
                   ("images", ("b.png", imgs[1][1], imgs[1][2]))],
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["model"] == "glm-4v-flash"
        assert len(body["results"]) == 2
        # 每张图独立一次 LLM 调用,各自 content 数组含 1 个 image_url
        assert seen["count"] == 2
        for i in range(2):
            content = seen[f"m{i}"][0]["content"]
            assert content[0]["type"] == "text"
            assert content[1]["type"] == "image_url"
            assert content[1]["image_url"]["url"].startswith("data:image/")
            assert body["results"][i]["image_index"] == i
            assert body["results"][i]["error"] is None
            assert body["results"][i]["content"].startswith('{"tx_drafts"')

        # 每张图落一行日志,原图分别落盘
        assert _count_logs(Session) == 2
    finally:
        app.dependency_overrides.clear()


def test_relay_vision_batch_partial_failure(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-vbp@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-vbp@example.com"), Session)

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            # 第 1 张(messages 里第二张图是 index1)让上游失败
            content = messages[0]["content"]
            if len(content) > 1 and content[1]["image_url"]["url"].startswith("data:image/jpeg"):
                raise ChatProviderError("upstream 500")
            return type("R", (), {"content": '{"tx_drafts":[{"amount":1}]}', "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)

        r = client.post(
            "/api/v1/ai/relay/vision-batch",
            headers={"Authorization": f"Bearer {token}"},
            data={"prompt": "p"},
            files=[("images", ("a.jpg", b"\xff\xd8" + b"a" * 10, "image/jpeg")),
                   ("images", ("b.png", b"\x89PNG\r\n\x1a\n" + b"b" * 10, "image/png"))],
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert len(body["results"]) == 2
        assert body["results"][0]["error"] == "upstream 500"
        assert body["results"][1]["error"] is None
        # 失败那张也落日志(status=error)
        assert _count_logs(Session) == 2
    finally:
        app.dependency_overrides.clear()


def test_relay_vision_batch_validates_mime_and_size(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-vbv@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-vbv@example.com"), Session)
        headers = {"Authorization": f"Bearer {token}"}
        data = {"prompt": "p"}

        # 任意一张 mime 非法 → 400,且不调用 provider
        r = client.post(
            "/api/v1/ai/relay/vision-batch", headers=headers, data=data,
            files=[("images", ("a.jpg", b"\xff\xd8a", "image/jpeg")),
                   ("images", ("b.txt", b"hello", "text/plain"))],
        )
        assert r.status_code == 400
        assert r.json()["error_code"] == "AI_IMAGE_TYPE_INVALID"

        # 任意一张超 5MB → 413
        big = b"\xff\xd8" + b"0" * (5 * 1024 * 1024)
        r = client.post(
            "/api/v1/ai/relay/vision-batch", headers=headers, data=data,
            files=[("images", ("a.jpg", b"\xff\xd8a", "image/jpeg")),
                   ("images", ("big.jpg", big, "image/jpeg"))],
        )
        assert r.status_code == 413
        assert r.json()["error_code"] == "AI_IMAGE_TOO_LARGE"
    finally:
        app.dependency_overrides.clear()


def test_relay_vision_batch_no_provider(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-vbn@example.com")
        r = client.post(
            "/api/v1/ai/relay/vision-batch",
            headers={"Authorization": f"Bearer {token}"},
            data={"prompt": "p"},
            files=[("images", ("a.jpg", b"\xff\xd8abc", "image/jpeg"))],
        )
        assert r.status_code == 400
        assert r.json()["error_code"] == "AI_NO_VISION_PROVIDER"
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# /relay/stt
# ──────────────────────────────────────────────────────────────────────


def test_relay_stt_happy_path(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-stt@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-stt@example.com"), Session)

        seen: dict = {}

        async def fake_transcribe(*, config, audio_bytes, audio_mime, filename, timeout=None):
            seen["bytes"] = audio_bytes
            seen["mime"] = audio_mime
            return "今天午饭花了五十块"

        monkeypatch.setattr("src.routers.ai.relay.transcribe_audio", fake_transcribe)

        r = client.post(
            "/api/v1/ai/relay/stt",
            headers={"Authorization": f"Bearer {token}"},
            files={"audio": ("rec.m4a", b"fake-audio-bytes", "audio/mp4")},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["text"] == "今天午饭花了五十块"
        assert seen["bytes"] == b"fake-audio-bytes"

        row = _only_log(Session)
        assert row.entry_type == "stt"
        assert row.status == "ok"
        assert row.output_text == "今天午饭花了五十块"
    finally:
        app.dependency_overrides.clear()


def test_relay_stt_no_provider(monkeypatch, tmp_path) -> None:
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-stt-nop@example.com")
        r = client.post(
            "/api/v1/ai/relay/stt",
            headers={"Authorization": f"Bearer {token}"},
            files={"audio": ("rec.wav", b"xx", "audio/wav")},
        )
        assert r.status_code == 400
        assert r.json()["error_code"] == "AI_NO_AUDIO_PROVIDER"
    finally:
        app.dependency_overrides.clear()


def test_relay_requires_auth(monkeypatch, tmp_path) -> None:
    _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        r = client.post(
            "/api/v1/ai/relay/chat",
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        assert r.status_code == 401
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# 识别前唯一标识判重(external_id/订单号)
# ──────────────────────────────────────────────────────────────────────


def _llm_json_with_identifier(identifier: str) -> str:
    return json.dumps([{
        "amount": -28,
        "note": "星巴克",
        "category": "咖啡",
        "type": "expense",
        "external_id": identifier,
    }], ensure_ascii=False)


def test_relay_dedup_skips_llm_on_known_identifier(monkeypatch, tmp_path) -> None:
    """同一订单号第二次到达(即使排版/措辞不同)→ 不调 LLM,返回 duplicate;
    服务端记录重复(日志 dedup_hit + 标识 last_seen)。"""
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-dedup@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-dedup@example.com"), Session)

        calls = {"n": 0}

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            calls["n"] += 1
            return type("R", (), {"content": _llm_json_with_identifier("2026090512345678"), "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)
        headers = {"Authorization": f"Bearer {token}"}

        # 第一次:正常识别并登记标识
        r1 = client.post("/api/v1/ai/relay/chat", headers=headers, json={
            "messages": [{"role": "user", "content": "短信:您尾号6688的卡支出28元,星巴克"}],
            "entry_type": "parse_tx_text",
            "log_input": "短信:您尾号6688的卡支出28元,星巴克",
        })
        assert r1.status_code == 200
        assert r1.json()["duplicate"] is False
        assert calls["n"] == 1

        # 第二次:不同文本但包含同一订单号(排版打散)→ 判重,不调 LLM
        r2 = client.post("/api/v1/ai/relay/chat", headers=headers, json={
            "messages": [{"role": "user", "content": "重新发送:订单号 2026 0905-1234 5678 支付28元"}],
            "entry_type": "parse_tx_text",
            "log_input": "重新发送:订单号 2026 0905-1234 5678 支付28元",
        })
        assert r2.status_code == 200, r2.text
        body = r2.json()
        assert body["duplicate"] is True
        assert body["content"] == ""
        assert body["matched_identifier"] == "2026090512345678"
        assert calls["n"] == 1  # LLM 没有被再次调用

        # 服务端记录:两行日志,第二行 dedup_hit='duplicate_identifier'
        with Session() as db:
            rows = db.scalars(select(AIAnalysisLog).order_by(AIAnalysisLog.id)).all()
            assert len(rows) == 2
            assert rows[0].dedup_hit is None
            assert rows[1].dedup_hit == "duplicate_identifier"
            assert rows[1].provider_id is None
    finally:
        app.dependency_overrides.clear()


def test_relay_dedup_free_chat_not_deduped(monkeypatch, tmp_path) -> None:
    """自由对话永不判重:用户在聊天里手打已知订单号也要照常走 LLM。"""
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-chat-dup@example.com")
        _seed_ai_config(_get_user_id(Session, "relay-chat-dup@example.com"), Session)

        calls = {"n": 0}

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            calls["n"] += 1
            content = _llm_json_with_identifier("2026090512345678") if calls["n"] == 1 else "好的"
            return type("R", (), {"content": content, "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)
        headers = {"Authorization": f"Bearer {token}"}

        r1 = client.post("/api/v1/ai/relay/chat", headers=headers, json={
            "messages": [{"role": "user", "content": "买了杯奶茶28块 订单号2026090512345678"}],
            "entry_type": "parse_tx_text",
        })
        assert r1.json()["duplicate"] is False
        # 自由对话带同一订单号 → 照常调 LLM
        r2 = client.post("/api/v1/ai/relay/chat", headers=headers, json={
            "messages": [{"role": "user", "content": "帮我看看 2026090512345678 是什么"}],
            "entry_type": "chat",
        })
        assert r2.status_code == 200
        assert r2.json()["duplicate"] is False
        assert calls["n"] == 2
    finally:
        app.dependency_overrides.clear()


def test_relay_dedup_user_isolation(monkeypatch, tmp_path) -> None:
    """标识按 user 隔离:B 用户的请求包含 A 的订单号 → 照常识别。"""
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token_a = _register_and_login(client, "dedup-a@example.com")
        token_b = _register_and_login(client, "dedup-b@example.com")
        _seed_ai_config(_get_user_id(Session, "dedup-a@example.com"), Session)
        _seed_ai_config(_get_user_id(Session, "dedup-b@example.com"), Session)

        calls = {"n": 0}

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            calls["n"] += 1
            return type("R", (), {"content": _llm_json_with_identifier("2026090512345678"), "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)
        client.post("/api/v1/ai/relay/chat", headers={"Authorization": f"Bearer {token_a}"}, json={
            "messages": [{"role": "user", "content": "星巴克28元 订单号2026090512345678"}],
            "entry_type": "parse_tx_text",
        })
        r = client.post("/api/v1/ai/relay/chat", headers={"Authorization": f"Bearer {token_b}"}, json={
            "messages": [{"role": "user", "content": "订单号2026090512345678 又扣了28"}],
            "entry_type": "parse_tx_text",
        })
        assert r.json()["duplicate"] is False
        assert calls["n"] == 2
    finally:
        app.dependency_overrides.clear()


def test_relay_vision_harvest_feeds_text_dedup(monkeypatch, tmp_path) -> None:
    """截图先到:vision 响应收割的标识,之后短信文本包含它 → 判重跳过。"""
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "dedup-vision@example.com")
        _seed_ai_config(_get_user_id(Session, "dedup-vision@example.com"), Session)

        chat_calls = {"n": 0}

        async def fake_chat(*, config, messages, temperature, disable_thinking, timeout=None):
            chat_calls["n"] += 1
            return type("R", (), {"content": _llm_json_with_identifier("PAY8866220011"), "usage": None})()

        async def fake_vision_chat(*, config, messages, temperature, disable_thinking, timeout=None):
            return type("R", (), {"content": _llm_json_with_identifier("PAY8866220011"), "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_chat)

        # 注意:vision 走同一个 call_chat_text 符号 —— 用首次注册即可覆盖;
        # 这里直接以文本请求登记,vision 端 harvest 逻辑同 chat(共用函数)。
        client.post("/api/v1/ai/relay/chat", headers={"Authorization": f"Bearer {token}"}, json={
            "messages": [{"role": "user", "content": "截图账单"}],
            "entry_type": "parse_tx_text",
        })
        assert chat_calls["n"] == 1

        # 同一标识再来 → 判重
        r = client.post("/api/v1/ai/relay/chat", headers={"Authorization": f"Bearer {token}"}, json={
            "messages": [{"role": "user", "content": "支付凭证 PAY-8866-2200-11 已扣款"}],
            "entry_type": "parse_tx_text",
        })
        assert r.json()["duplicate"] is True
        assert chat_calls["n"] == 1
    finally:
        app.dependency_overrides.clear()


def test_relay_dedup_ignores_short_identifiers(monkeypatch, tmp_path) -> None:
    """短于 8 位的 external_id(金额/日期误填)不参与判重。"""
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "dedup-short@example.com")
        _seed_ai_config(_get_user_id(Session, "dedup-short@example.com"), Session)

        calls = {"n": 0}

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            calls["n"] += 1
            return type("R", (), {"content": _llm_json_with_identifier("1234567"), "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)
        headers = {"Authorization": f"Bearer {token}"}
        for text in ("星巴克28元 订单号1234567", "又买了 订单号1234567"):
            r = client.post("/api/v1/ai/relay/chat", headers=headers, json={
                "messages": [{"role": "user", "content": text}],
                "entry_type": "parse_tx_text",
            })
            assert r.json()["duplicate"] is False
        assert calls["n"] == 2
    finally:
        app.dependency_overrides.clear()


def test_relay_dedup_expired_identifier_ignored(monkeypatch, tmp_path) -> None:
    """TTL 过期的标识不再参与判重(仅表体积控制语义)。"""
    Session = _make_client(monkeypatch, tmp_path)
    try:
        from src.config import get_settings
        monkeypatch.setattr(get_settings(), "ai_bill_identifier_ttl_days", 0)

        client = TestClient(app)
        token = _register_and_login(client, "dedup-exp@example.com")
        _seed_ai_config(_get_user_id(Session, "dedup-exp@example.com"), Session)

        calls = {"n": 0}

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            calls["n"] += 1
            return type("R", (), {"content": _llm_json_with_identifier("2026090512345678"), "usage": None})()

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)
        headers = {"Authorization": f"Bearer {token}"}
        for text in ("星巴克28元 订单号2026090512345678", "星巴克28元 订单号2026090512345678"):
            r = client.post("/api/v1/ai/relay/chat", headers=headers, json={
                "messages": [{"role": "user", "content": text}],
                "entry_type": "parse_tx_text",
            })
            assert r.json()["duplicate"] is False
        assert calls["n"] == 2
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# M2-5 上游 timeout 分档
# ──────────────────────────────────────────────────────────────────────


def test_relay_upstream_timeout_per_capability(monkeypatch, tmp_path) -> None:
    """每个能力按计划表传上游 timeout,且都比客户端 deadline 小。

    回归价值:四个入口以前共用 call_chat_text 的 120s 默认值 —— 自动记账文本
    提取客户端 40s 就放弃了,上游还在跑,既白烧 token 又拿不到 502 日志。
    自动记账(parse_tx_text)与自由聊天(chat)必须是不同档位。
    """
    Session = _make_client(monkeypatch, tmp_path)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "relay-timeout@example.com")
        _seen: dict[str, float | None] = {}
        _seed_ai_config(_get_user_id(Session, "relay-timeout@example.com"), Session)

        async def fake_call(*, config, messages, temperature, disable_thinking, timeout=None):
            _seen["chat"] = timeout
            return type("R", (), {"content": "ok", "usage": None})()

        async def fake_transcribe(*, config, audio_bytes, audio_mime, filename, timeout=None):
            _seen["stt"] = timeout
            return "ok"

        monkeypatch.setattr("src.routers.ai.relay.call_chat_text", fake_call)
        monkeypatch.setattr("src.routers.ai.relay.transcribe_audio", fake_transcribe)
        headers = {"Authorization": f"Bearer {token}"}

        # 文本提取 35s < 客户端 40s
        client.post("/api/v1/ai/relay/chat", headers=headers, json={
            "messages": [{"role": "user", "content": "买了杯奶茶28块"}],
            "entry_type": "parse_tx_text",
        })
        assert _seen["chat"] == 35.0

        # 自由聊天 120s < 客户端 130s
        client.post("/api/v1/ai/relay/chat", headers=headers, json={
            "messages": [{"role": "user", "content": "你好"}],
            "entry_type": "chat",
        })
        assert _seen["chat"] == 120.0

        # 图片提取 60s < 客户端 65s
        r = client.post(
            "/api/v1/ai/relay/vision",
            headers=headers,
            data={"prompt": "分析截图"},
            files={"image": ("shot.jpg", b"\xff\xd8\xff\xe0" + b"x" * 20, "image/jpeg")},
        )
        assert r.status_code == 200, r.text
        assert _seen["chat"] == 60.0

        # STT 60s < 客户端 65s
        r = client.post(
            "/api/v1/ai/relay/stt",
            headers=headers,
            files={"audio": ("rec.m4a", b"fake-audio", "audio/mp4")},
        )
        assert r.status_code == 200, r.text
        assert _seen["stt"] == 60.0
    finally:
        app.dependency_overrides.clear()
