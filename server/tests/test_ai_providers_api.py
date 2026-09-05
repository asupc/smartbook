"""/ai/providers CRUD + /profile/me ai_config 掩码合并测试。

背景:App「AI 服务商管理」改为服务端持有密钥(只存不吐)。验证:
1. POST /providers 建服务商 → GET 掩码显示(hasApiKey),DB 里是真 key
2. 重复 id / 非内置 id 报 isBuiltIn → 400
3. PATCH:掩码 / 空 key = 保留原值,真 key = 替换;模型等字段照常更新
4. DELETE:自定义可删且相关能力重绑到内置智谱;内置不可删;不存在 404
5. PUT /providers/binding:三能力绑定落库
6. POST /providers/test:不存在 404 / 缺字段 success=False / happy path 复用探测
7. GET /profile/me:ai_config.providers[].apiKey 永远是掩码
8. PATCH /profile/me:掩码回传不冲真 key;不带 providers 段 = 原段保留
"""
from __future__ import annotations

import json

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import UserProfile


def _make_client(monkeypatch) -> sessionmaker:
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
            "device_id": "prov-dev",
            "client_type": "web",
            "device_name": "pytest-prov",
            "platform": "test",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "prov-dev",
            "client_type": "web",
            "device_name": "pytest-prov",
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
# CRUD
# ──────────────────────────────────────────────────────────────────────


def test_create_and_list_masks_key(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prov-create@example.com")

        r = client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={
                "id": "prov-1",
                "name": "硅基流动",
                "apiKey": "sk-abcd1234xyz",
                "baseUrl": "https://api.siliconflow.cn/v1",
                "textModel": "deepseek-v3",
                "createdAt": "2026-09-05T00:00:00.000",
            },
        )
        assert r.status_code == 201, r.text
        body = r.json()
        assert body["id"] == "prov-1"
        assert body["apiKey"] == "****4xyz"
        assert body["hasApiKey"] is True

        # DB 里存的是真 key
        cfg = _stored_config(Session, "prov-create@example.com")
        assert cfg["providers"][0]["apiKey"] == "sk-abcd1234xyz"

        # 列表掩码
        r2 = client.get("/api/v1/ai/providers", headers=_auth(token))
        assert r2.status_code == 200
        listed = r2.json()["providers"][0]
        assert listed["apiKey"] == "****4xyz"
        assert listed["hasApiKey"] is True
        assert "sk-abcd1234xyz" not in json.dumps(r2.json())
    finally:
        app.dependency_overrides.clear()


def test_create_rejects_duplicate_and_builtin_misuse(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prov-dup@example.com")
        payload = {
            "id": "prov-1", "name": "A", "apiKey": "sk-1", "baseUrl": "https://a",
        }
        assert client.post("/api/v1/ai/providers", headers=_auth(token), json=payload).status_code == 201
        assert client.post("/api/v1/ai/providers", headers=_auth(token), json=payload).status_code == 400

        r = client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "fake_builtin", "name": "X", "isBuiltIn": True, "apiKey": "sk", "baseUrl": "https://x"},
        )
        assert r.status_code == 400
    finally:
        app.dependency_overrides.clear()


def test_patch_preserves_key_when_masked(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prov-patch@example.com")
        client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "p", "name": "A", "apiKey": "sk-real-key-99", "baseUrl": "https://a",
                  "textModel": "m1"},
        )

        # 只改模型 → key 原值保留
        r = client.patch(
            "/api/v1/ai/providers/p",
            headers=_auth(token),
            json={"textModel": "m2"},
        )
        assert r.status_code == 200
        assert r.json()["textModel"] == "m2"
        assert _stored_config(Session, "prov-patch@example.com")["providers"][0]["apiKey"] == "sk-real-key-99"

        # 回传掩码值 → 保留原值
        r2 = client.patch(
            "/api/v1/ai/providers/p",
            headers=_auth(token),
            json={"apiKey": "****e-99"},
        )
        assert r2.status_code == 200
        assert _stored_config(Session, "prov-patch@example.com")["providers"][0]["apiKey"] == "sk-real-key-99"

        # 传新真 key → 替换
        r3 = client.patch(
            "/api/v1/ai/providers/p",
            headers=_auth(token),
            json={"apiKey": "sk-new-key"},
        )
        assert r3.status_code == 200
        assert _stored_config(Session, "prov-patch@example.com")["providers"][0]["apiKey"] == "sk-new-key"

        # 不存在 → 404
        r4 = client.patch("/api/v1/ai/providers/nope", headers=_auth(token), json={"name": "x"})
        assert r4.status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_delete_rebinds_to_builtin_and_protects_builtin(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prov-del@example.com")
        client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "zhipu_glm", "name": "智谱GLM", "isBuiltIn": True,
                  "apiKey": "sk-z", "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
                  "textModel": "glm-4-flash"},
        )
        client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "p2", "name": "B", "apiKey": "sk-b", "baseUrl": "https://b"},
        )
        client.put(
            "/api/v1/ai/providers/binding",
            headers=_auth(token),
            json={"textProviderId": "p2", "visionProviderId": "p2", "speechProviderId": "p2"},
        )

        # 内置不可删
        r = client.delete("/api/v1/ai/providers/zhipu_glm", headers=_auth(token))
        assert r.status_code == 400

        # 删自定义 → 相关能力重绑 zhipu_glm
        r2 = client.delete("/api/v1/ai/providers/p2", headers=_auth(token))
        assert r2.status_code == 200
        cfg = _stored_config(Session, "prov-del@example.com")
        assert [p["id"] for p in cfg["providers"]] == ["zhipu_glm"]
        binding = cfg["binding"]
        assert binding["textProviderId"] == "zhipu_glm"
        assert binding["visionProviderId"] == "zhipu_glm"
        assert binding["speechProviderId"] == "zhipu_glm"

        # 再删 → 404
        r3 = client.delete("/api/v1/ai/providers/p2", headers=_auth(token))
        assert r3.status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_binding_put(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prov-bind@example.com")
        r = client.put(
            "/api/v1/ai/providers/binding",
            headers=_auth(token),
            json={"textProviderId": "zhipu_glm", "visionProviderId": None, "speechProviderId": None},
        )
        assert r.status_code == 200, r.text
        cfg = _stored_config(Session, "prov-bind@example.com")
        assert cfg["binding"]["textProviderId"] == "zhipu_glm"
        assert cfg["binding"]["visionProviderId"] is None

        # 列表里 binding 一并返回
        r2 = client.get("/api/v1/ai/providers", headers=_auth(token))
        assert r2.json()["binding"]["textProviderId"] == "zhipu_glm"
    finally:
        app.dependency_overrides.clear()


def test_stored_provider_test(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prov-test@example.com")
        client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "p", "name": "A", "apiKey": "sk-ok", "baseUrl": "https://a",
                  "textModel": "m", "audioModel": ""},
        )

        # 不存在 → 404
        r = client.post(
            "/api/v1/ai/providers/test", headers=_auth(token),
            json={"providerId": "nope", "capability": "text"},
        )
        assert r.status_code == 404

        # 缺模型(audioModel 空)→ success=False + MISSING_FIELDS(200)
        r2 = client.post(
            "/api/v1/ai/providers/test", headers=_auth(token),
            json={"providerId": "p", "capability": "speech"},
        )
        assert r2.status_code == 200
        assert r2.json()["success"] is False
        assert r2.json()["error_code"] == "AI_TEST_MISSING_FIELDS"

        # happy path:patch 探测函数
        async def fake_text(base_url, api_key, model):
            assert base_url == "https://a" and api_key == "sk-ok" and model == "m"
            return "pong"

        monkeypatch.setattr("src.routers.ai.providers._test_text", fake_text)
        r3 = client.post(
            "/api/v1/ai/providers/test", headers=_auth(token),
            json={"providerId": "p", "capability": "text"},
        )
        assert r3.status_code == 200
        body = r3.json()
        assert body["success"] is True
        assert body["preview"] == "pong"
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# /profile/me 掩码与合并
# ──────────────────────────────────────────────────────────────────────


def test_profile_me_masks_api_key(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prof-mask@example.com")
        client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "zhipu_glm", "name": "智谱GLM", "isBuiltIn": True,
                  "apiKey": "sk-secret-8888", "baseUrl": "https://x", "textModel": "m"},
        )

        r = client.get("/api/v1/profile/me", headers=_auth(token))
        assert r.status_code == 200
        ai_cfg = r.json()["ai_config"]
        assert ai_cfg["providers"][0]["apiKey"] == "****8888"
        assert "sk-secret-8888" not in json.dumps(r.json())

        # PATCH 响应同样掩码
        r2 = client.patch(
            "/api/v1/profile/me", headers=_auth(token), json={"display_name": "nn"}
        )
        assert r2.json()["ai_config"]["providers"][0]["apiKey"] == "****8888"
    finally:
        app.dependency_overrides.clear()


def test_profile_patch_merge_semantics(monkeypatch) -> None:
    Session = _make_client(monkeypatch)
    try:
        client = TestClient(app)
        token = _register_and_login(client, "prof-merge@example.com")
        client.post(
            "/api/v1/ai/providers",
            headers=_auth(token),
            json={"id": "p1", "name": "A", "apiKey": "sk-keep-me",
                  "baseUrl": "https://a", "textModel": "m1"},
        )

        # 1) 掩码回传 → 真 key 保留,其它字段更新生效
        r = client.patch(
            "/api/v1/profile/me",
            headers=_auth(token),
            json={"ai_config": {
                "providers": [{"id": "p1", "name": "A2", "apiKey": "****me",
                               "baseUrl": "https://a", "textModel": "m2"}],
                "binding": {"textProviderId": "p1"},
            }},
        )
        assert r.status_code == 200
        cfg = _stored_config(Session, "prof-merge@example.com")
        assert cfg["providers"][0]["apiKey"] == "sk-keep-me"
        assert cfg["providers"][0]["name"] == "A2"
        assert cfg["providers"][0]["textModel"] == "m2"

        # 2) 不带 providers 段 → 原段保留(新客户端只同步 prompt 等非敏感段)
        r2 = client.patch(
            "/api/v1/profile/me",
            headers=_auth(token),
            json={"ai_config": {"strategy": "auto"}},
        )
        assert r2.status_code == 200
        cfg2 = _stored_config(Session, "prof-merge@example.com")
        assert cfg2["strategy"] == "auto"
        assert cfg2["providers"][0]["apiKey"] == "sk-keep-me"
        assert "binding" in cfg2

        # 3) 新 provider 带真 key → 正常写入
        r3 = client.patch(
            "/api/v1/profile/me",
            headers=_auth(token),
            json={"ai_config": {"providers": [
                {"id": "p1", "apiKey": "****me"},
                {"id": "p2", "apiKey": "sk-fresh", "baseUrl": "https://b"},
            ]}},
        )
        assert r3.status_code == 200
        cfg3 = _stored_config(Session, "prof-merge@example.com")
        keys = {p["id"]: p["apiKey"] for p in cfg3["providers"]}
        assert keys == {"p1": "sk-keep-me", "p2": "sk-fresh"}
    finally:
        app.dependency_overrides.clear()
