"""对抗性测试 —— /ai/providers CRUD 与密钥掩码。

覆盖攻击面:
  - apiKey 掩码:GET 列表/详情、/profile/me 不得含明文
  - PATCH 收到掩码/空串 = 保留真 key(经典「掩码回传冲掉真 key」bug)
  - 越权:他人 provider id 不可读写(隔离在 user_id 上)
  - provider 数量 / 同名上限(资源耗尽面)
  - 能力绑定指向悬空 id
  - /providers/test:用存储配置测连,SSRF 面 + 掩码 key 语义
  - protocol 字段非法值
  - 内置 provider 保护不可绕过

红绿纪律同 test_ai_relay_adversarial.py。
"""
from __future__ import annotations

import http.server
import json
import threading

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import UserProfile

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
            "email": email, "password": _PW, "device_id": "prov-adv-dev",
            "client_type": client_type, "device_name": "pytest-adv", "platform": "test",
        },
    )
    assert reg.status_code in (200, 201), reg.text
    res = client.post(
        "/api/v1/auth/login",
        json={
            "email": email, "password": _PW, "device_id": "prov-adv-dev",
            "client_type": client_type, "device_name": "pytest-adv", "platform": "test",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _stored_config(Session, email: str) -> dict:
    from src.models import User

    with Session() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
        profile = db.scalar(select(UserProfile).where(UserProfile.user_id == uid))
        if profile is None or not profile.ai_config_json:
            return {}
        return json.loads(profile.ai_config_json)


def _create(client: TestClient, token: str, **payload) -> dict:
    body = {
        "id": "p1", "name": "A", "apiKey": "sk-adv-real-abcd",
        "baseUrl": "https://a.example.com/v1", "textModel": "m1",
    }
    body.update(payload)
    res = client.post("/api/v1/ai/providers", headers=_auth(token), json=body)
    assert res.status_code == 201, res.text
    return res.json()


# ══════════════════════════════════════════════════════════════════════
# 1. 密钥掩码与「掩码回传」语义
# ══════════════════════════════════════════════════════════════════════


def test_list_and_detail_never_leak_plaintext_key() -> None:
    """GET /providers(含全部响应体)+ /profile/me 不得出现真 key。"""
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-mask@example.com")
        _create(client, token)

        listed = client.get("/api/v1/ai/providers", headers=_auth(token))
        assert listed.status_code == 200, listed.text
        assert "sk-adv-real-abcd" not in listed.text
        assert listed.json()["providers"][0]["apiKey"] == "****abcd"
        assert listed.json()["providers"][0]["hasApiKey"] is True

        me = client.get("/api/v1/profile/me", headers=_auth(token))
        assert "sk-adv-real-abcd" not in me.text, me.text
    finally:
        app.dependency_overrides.clear()


def test_patch_with_masked_key_preserves_real_key() -> None:
    """PATCH 传掩码串 / 空串 → 保留真 key(不得把掩码当新 key 覆盖)。"""
    client, Session = _make_client()
    try:
        email = "prov-adv-patch@example.com"
        token = _login(client, email)
        _create(client, token)

        for masked in ("****abcd", "****", "", "****wxyz"):
            res = client.patch(
                "/api/v1/ai/providers/p1", headers=_auth(token), json={"apiKey": masked}
            )
            assert res.status_code == 200, res.text
        cfg = _stored_config(Session, email)
        assert cfg["providers"][0]["apiKey"] == "sk-adv-real-abcd", cfg

        # 真 key 才替换
        res = client.patch(
            "/api/v1/ai/providers/p1", headers=_auth(token), json={"apiKey": "sk-brand-new"}
        )
        assert res.status_code == 200
        assert _stored_config(Session, email)["providers"][0]["apiKey"] == "sk-brand-new"
    finally:
        app.dependency_overrides.clear()


def test_patch_near_miss_mask_overwrites_real_key() -> None:
    """ADVERSE FINDING: 前缀不完整的「像掩码」串会被当成新 key 覆盖真 key。

    `is_unset_key`(ai_config_store.py:70)只认 `key.startswith("****")`。
    客户端若把掩码做了任何变形(去掉一个星、加空格、大写转写、UI 截断成
    `*abcd`、或后端/网关把 `****` 折叠成 `*`),就会被判为「用户提供了新
    key」而把真 key 冲成垃圾串 —— 之后所有 AI 调用 401,而用户看不出原因
    (掩码显示 `****abcd` 只差一个星,视觉几乎相同)。

    期望:写入口对「形如掩码」的串(如 `^\*+[0-9a-zA-Z]{0,6}$`)一律视为
    未变更;或返回 400 让客户端显式确认。实际:静默覆盖。

    源码:`src/services/ai/ai_config_store.py:70-74`(is_unset_key)。
    """
    client, Session = _make_client()
    try:
        email = "prov-adv-nearmiss@example.com"
        token = _login(client, email)
        _create(client, token)

        # 少一个星号的掩码 —— 视觉上仍是掩码,但 startswith("****") 为假
        res = client.patch(
            "/api/v1/ai/providers/p1", headers=_auth(token), json={"apiKey": "***abcd"}
        )
        assert res.status_code == 200
        stored = _stored_config(Session, email)["providers"][0]["apiKey"]
        # ADVERSE FINDING: 形似掩码的串被当新 key 静默覆盖真 key
        assert stored == "sk-adv-real-abcd", (
            "形似掩码的 '***abcd' 被当成新 key 覆盖了真 key "
            f"(当前存的是 {stored!r});is_unset_key 只认 '****' 前缀,"
            "ai_config_store.py:70"
        )
    finally:
        app.dependency_overrides.clear()


def test_patch_whitespace_padded_mask_overwrites_key() -> None:
    """ADVERSE FINDING: 掩码两侧带空白(表单/剪贴板常见)→ 同样覆盖真 key。

    与上一个同源:输入未 strip,`" ****abcd"` 的 startswith 为假 → 当真 key 写入。
    期望同上(归一化后再判)。源码同 is_unset_key。
    """
    client, Session = _make_client()
    try:
        email = "prov-adv-ws@example.com"
        token = _login(client, email)
        _create(client, token)

        res = client.patch(
            "/api/v1/ai/providers/p1", headers=_auth(token), json={"apiKey": " ****abcd"}
        )
        assert res.status_code == 200
        stored = _stored_config(Session, email)["providers"][0]["apiKey"]
        # ADVERSE FINDING: 掩码未 strip,带空白的掩码同样把真 key 覆盖
        assert stored == "sk-adv-real-abcd", (
            f"带前导空白的掩码 ' ****abcd' 覆盖了真 key(当前 {stored!r});"
            "is_unset_key 未做 strip,ai_config_store.py:70"
        )
    finally:
        app.dependency_overrides.clear()


def test_profile_patch_ai_config_mask_roundtrip_preserves_key() -> None:
    """PATCH /profile/me 回传掩码 → 真 key 保留(既有语义,对抗面确认)。"""
    client, Session = _make_client()
    try:
        email = "prov-adv-merge@example.com"
        token = _login(client, email)
        _create(client, token)

        res = client.patch(
            "/api/v1/profile/me", headers=_auth(token),
            json={"ai_config": {
                "providers": [{"id": "p1", "name": "A2", "apiKey": "****abcd",
                               "baseUrl": "https://a.example.com/v1", "textModel": "m2"}],
                "binding": {"textProviderId": "p1"},
            }},
        )
        assert res.status_code == 200, res.text
        cfg = _stored_config(Session, email)
        assert cfg["providers"][0]["apiKey"] == "sk-adv-real-abcd", cfg
        assert cfg["providers"][0]["textModel"] == "m2", cfg
    finally:
        app.dependency_overrides.clear()


def test_profile_patch_ai_config_near_miss_mask_overwrites_key() -> None:
    """ADVERSE FINDING: /profile/me 的掩码合并同样只认 '****' 前缀。

    `merge_ai_config_on_patch`(ai_config_store.py:91)走同一个 `is_unset_key`,
    因此 App 端做任何掩码变形都会把真 key 冲掉。影响面比 /ai/providers 更大:
    App 每次同步 profile 都可能带着变形掩码。
    """
    client, Session = _make_client()
    try:
        email = "prov-adv-merge2@example.com"
        token = _login(client, email)
        _create(client, token)

        res = client.patch(
            "/api/v1/profile/me", headers=_auth(token),
            json={"ai_config": {"providers": [
                {"id": "p1", "apiKey": "****", "baseUrl": "https://a.example.com/v1"}]}},
        )
        assert res.status_code == 200
        stored = _stored_config(Session, email)["providers"][0]["apiKey"]
        # "****" 本身是合法掩码 → 保留;这里断言用它确实保留(基线确认)
        assert stored == "sk-adv-real-abcd", stored

        # 对照:少一个星的变形
        client.patch(
            "/api/v1/profile/me", headers=_auth(token),
            json={"ai_config": {"providers": [
                {"id": "p1", "apiKey": "*", "baseUrl": "https://a.example.com/v1"}]}},
        )
        stored2 = _stored_config(Session, email)["providers"][0]["apiKey"]
        # ADVERSE FINDING: /profile/me 掩码合并共用 is_unset_key,变形掩码冲掉真 key
        assert stored2 == "sk-adv-real-abcd", (
            f"/profile/me 的掩码变形 '*' 冲掉了真 key(当前 {stored2!r});"
            "merge_ai_config_on_patch 共用 is_unset_key,ai_config_store.py:114"
        )
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 2. 越权 / 用户隔离
# ══════════════════════════════════════════════════════════════════════


def test_providers_are_isolated_per_user() -> None:
    """B 改/删/测 A 的 provider id → 404(provider 只在本人 ai_config 内)。"""
    client, Session = _make_client()
    try:
        token_a = _login(client, "prov-adv-iso-a@example.com")
        _create(client, token_a, id="shared-id")
        token_b = _login(client, "prov-adv-iso-b@example.com")

        listed_b = client.get("/api/v1/ai/providers", headers=_auth(token_b))
        ids_b = [p["id"] for p in listed_b.json()["providers"]]
        assert "shared-id" not in ids_b, ids_b

        assert client.patch(
            "/api/v1/ai/providers/shared-id", headers=_auth(token_b), json={"name": "hacked"}
        ).status_code == 404
        assert client.delete(
            "/api/v1/ai/providers/shared-id", headers=_auth(token_b)
        ).status_code == 404
        test_res = client.post(
            "/api/v1/ai/providers/test", headers=_auth(token_b),
            json={"providerId": "shared-id", "capability": "text"},
        )
        assert test_res.status_code == 404, test_res.text

        # A 的配置未被 B 的删除/改名影响
        cfg_a = _stored_config(Session, "prov-adv-iso-a@example.com")
        assert [p["id"] for p in cfg_a["providers"]] == ["shared-id"]
        assert cfg_a["providers"][0]["name"] == "A"
    finally:
        app.dependency_overrides.clear()


def test_binding_cannot_reference_other_users_provider() -> None:
    """PUT /providers/binding 指向不存在的 id → 404(防悬空绑定)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-bind@example.com")
        res = client.put(
            "/api/v1/ai/providers/binding", headers=_auth(token),
            json={"textProviderId": "ghost-provider"},
        )
        assert res.status_code == 404, res.text
    finally:
        app.dependency_overrides.clear()


def test_binding_rejects_other_users_existing_id() -> None:
    """对抗面确认(现状正确):B 不能借 binding 探测 A 的 provider id 是否存在。

    `update_binding`(providers.py:436)的 existing_ids 来自 caller 自己的
    ai_config + 内置目录。因此 B 指向 A 的自定义 id 会被存在性校验拒(404)。
    顺带记录一个**口径差**(非本用例红灯):校验只看 id 字符串,不校验归属 ——
    用自己的账号把 binding 指向一个不存在的 id 时,校验先拒;若未来校验放宽,
    `_resolve_provider_by_kind` 会在 relay 侧二次报错,两套口径需同步。
    """
    client, Session = _make_client()
    try:
        token_a = _login(client, "prov-adv-bind-a@example.com")
        _create(client, token_a, id="a-private-prov")
        token_b = _login(client, "prov-adv-bind-b@example.com")

        res = client.put(
            "/api/v1/ai/providers/binding", headers=_auth(token_b),
            json={"textProviderId": "a-private-prov"},
        )
        assert res.status_code == 404, (
            f"B 可以把 binding 指向 A 的自定义 provider id: {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 3. 资源上限 / 重复
# ══════════════════════════════════════════════════════════════════════


def test_provider_count_has_no_cap() -> None:
    """ADVERSE FINDING: provider 数量无上限 → 单用户可把 ai_config_json 撑爆。

    实测:创建 80 个自定义 provider 全部 201;GET 列表把它们(加上 5 个
    内置)全部返回。缺失的上限带来两类问题:
      1. `UserProfile.ai_config_json` 是单列 TEXT;每个 provider 允许
         apiKey 4096 字符 + baseUrl 512 + 三个 model 128 字符,满配约
         5KB/个 → 1000 个 provider 即 5MB 单行,provider 每次 relay 都要
         `json.loads` 整个串(`_resolve_provider_by_kind`),O(n) 解析在
         热路径上;
      2. `_MAX_PROVIDER_SEMS` 之外的 `_PROVIDER_SEMS` / `_RATE_WINDOWS`
         以 (user, provider) 为键,provider 越多内存条目越多。

    期望:provider 数量有上限(如 32)并在超出时 400。
    源码:`src/routers/ai/providers.py:286-328`(create_provider 无任何计数校验)。
    """
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-cap@example.com")
        created = 0
        for i in range(60):
            res = client.post(
                "/api/v1/ai/providers", headers=_auth(token),
                json={"id": f"bulk-{i}", "name": f"n{i}", "apiKey": "sk-x",
                      "baseUrl": "https://a.example.com/v1", "textModel": "m"},
            )
            if res.status_code == 201:
                created += 1
        # ADVERSE FINDING: provider 数量无上限(60/60 全部创建成功)
        assert created < 60, (
            f"provider 数量无上限:{created} 个自定义 provider 全部创建成功;"
            "ai_config_json 单行会无界增长(providers.py:286)"
        )
    finally:
        app.dependency_overrides.clear()


def test_duplicate_name_allowed_but_duplicate_id_rejected() -> None:
    """HARDENING: id 唯一必拒,但同名 provider 允许(UI 靠 id 区分)。

    同名会让用户在选择器里难以区分两个 provider(尤其 key 掩码相同),
    属可用性问题而非安全缺陷 —— 记录为当前行为。
    """
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-dup@example.com")
        _create(client, token, id="dup-1", name="同名")
        first_dup = client.post(
            "/api/v1/ai/providers", headers=_auth(token),
            json={"id": "dup-1", "name": "同名", "apiKey": "sk-x",
                  "baseUrl": "https://a.example.com/v1", "textModel": "m"},
        )
        assert first_dup.status_code == 400, first_dup.text
        # HARDENING: 不同 id、同名 → 允许
        second = client.post(
            "/api/v1/ai/providers", headers=_auth(token),
            json={"id": "dup-2", "name": "同名", "apiKey": "sk-y",
                  "baseUrl": "https://a.example.com/v1", "textModel": "m"},
        )
        assert second.status_code == 201, second.text
    finally:
        app.dependency_overrides.clear()


def test_provider_id_path_parameter_not_traversal_capable() -> None:
    """provider id 里塞穿越片段/超长串 → 4xx 或 404(不得 500)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-idpath@example.com")
        for pid in ("../../etc/passwd", "a" * 500, "%2e%2e%2f", "..\\..\\win"):
            res = client.patch(
                f"/api/v1/ai/providers/{pid}", headers=_auth(token), json={"name": "x"}
            )
            assert res.status_code in (400, 404, 405, 422), f"{pid!r} -> {res.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_builtin_provider_delete_protection_holds() -> None:
    """内置 provider 不可删;伪造 isBuiltIn 的自定义 id 不可删。"""
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-builtin@example.com")
        assert client.delete(
            "/api/v1/ai/providers/zhipu_glm", headers=_auth(token)
        ).status_code == 400
        # 自定义 id 想冒充内置 → 创建即被拒
        res = client.post(
            "/api/v1/ai/providers", headers=_auth(token),
            json={"id": "fake_builtin", "name": "x", "isBuiltIn": True,
                  "apiKey": "sk", "baseUrl": "https://a.example.com"},
        )
        assert res.status_code == 400, res.text
    finally:
        app.dependency_overrides.clear()


def test_protocol_field_rejects_unknown_value() -> None:
    """protocol 非法值 → 400(不在白名单不得落库)。"""
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-proto@example.com")
        res = client.post(
            "/api/v1/ai/providers", headers=_auth(token),
            json={"id": "pp", "name": "x", "apiKey": "sk", "baseUrl": "https://a.example.com",
                  "protocol": "gopher"},
        )
        assert res.status_code == 400, res.text
        res2 = client.patch(
            "/api/v1/ai/providers/pp", headers=_auth(token), json={"protocol": "grpc"}
        )
        assert res2.status_code in (400, 404), res2.text
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 4. /providers/test —— 用存储配置探测(SSRF + 掩码 key)
# ══════════════════════════════════════════════════════════════════════


class _Probe(http.server.BaseHTTPRequestHandler):
    hits: list = []

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        type(self).hits.append(
            {"path": self.path, "auth": self.headers.get("Authorization"),
             "x-api-key": self.headers.get("x-api-key")}
        )
        payload = json.dumps({"choices": [{"message": {"content": "pong"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        return


def _loopback() -> tuple[http.server.ThreadingHTTPServer, int]:
    _Probe.hits = []
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Probe)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def test_providers_test_reaches_loopback_with_stored_key(monkeypatch) -> None:
    """ADVERSE FINDING: /providers/test 把存储的真 key 发往用户指定的任意 host。

    与 relay 的 SSRF 面同源(`providers.py:495` → `_test_text` →
    `f"{base_url}/chat/completions"`),但这里更直接:请求体不带 key 时
    server **从存储里取出真 key** 代发。攻击者只需有一个账号 + 一个指向
    内网的 baseUrl,就能让服务端带着自己的 key 打内网探点,并通过
    `error_code`/`error_message`(上游状态码 + body 前 200 字)回读内网响应。

    期望:探测目标有 host 策略(至少拒绝环回/链路本地);实际:无。
    源码:`src/routers/ai/providers.py:482-534`。
    """
    srv, port = _loopback()
    try:
        client, Session = _make_client()
        try:
            email = "prov-adv-test@example.com"
            token = _login(client, email)
            _create(client, token, baseUrl=f"http://127.0.0.1:{port}/v1")

            res = client.post(
                "/api/v1/ai/providers/test", headers=_auth(token),
                json={"providerId": "p1", "capability": "text"},
            )
            assert res.status_code == 200, res.text
            # ADVERSE FINDING: 探测请求带真 key 打到环回地址(无 host 策略)
            assert res.json()["success"] is False, (
                "/providers/test 成功把探测请求发往环回地址(SSRF 面);"
                f" got {res.json()}"
            )
        finally:
            app.dependency_overrides.clear()
    finally:
        srv.shutdown()


def test_providers_test_missing_fields_no_network_call() -> None:
    """缺 apiKey/baseUrl/model → success=False 且不发网络请求。"""
    client, Session = _make_client()
    try:
        token = _login(client, "prov-adv-testmiss@example.com")
        _create(client, token, audioModel="")
        res = client.post(
            "/api/v1/ai/providers/test", headers=_auth(token),
            json={"providerId": "p1", "capability": "speech"},
        )
        assert res.status_code == 200, res.text
        assert res.json()["success"] is False
        assert res.json()["error_code"] == "AI_TEST_MISSING_FIELDS"
    finally:
        app.dependency_overrides.clear()


def test_providers_test_has_no_rate_limit() -> None:
    """ADVERSE FINDING: `/ai/providers/test` 无限流,而 `/ai/test-provider` 有 30/min。

    `test_stored_provider`(providers.py:464)直接开跑探测,没有调
    `test_provider._check_rate_limit`;同一个上游探测能力,经这个端点可以
    无节制地打:
      - 每个请求让服务端发起一次真实出站 HTTP(15-20s timeout 档),
        单账号即可把线程/连接池打满(资源耗尽);
      - 结合「baseUrl 无 host 白名单」(见 test_providers_test_reaches_loopback),
        等于一个**无限速的内网扫描器**:内网探点、端口探测、读响应 body
        前 200 字(error_message 回传)。
    期望:与 /ai/test-provider 同款限流(30/min),或更严。
    源码:`src/routers/ai/providers.py:464-534`(无 `_check_rate_limit` 调用)。
    """
    client, Session = _make_client()
    try:
        from src.routers.ai import test_provider as tp_module

        tp_module._RATE_WINDOWS.clear()
        email = "prov-adv-testrate@example.com"
        token = _login(client, email)
        # audioModel 缺失 → 走 success=False 的快速路径,不产生真实出站请求;
        # 仅用于证明「计数没有被任何限流器拦住」
        _create(client, token, audioModel="")
        codes = []
        for _ in range(50):
            res = client.post(
                "/api/v1/ai/providers/test", headers=_auth(token),
                json={"providerId": "p1", "capability": "speech"},
            )
            codes.append(res.status_code)
        # ADVERSE FINDING: 50 次全 200 —— /providers/test 缺少与 /ai/test-provider 对等的限流
        assert 429 in codes, (
            f"/ai/providers/test 50 次连续调用无一被限流(codes={sorted(set(codes))});"
            "该端点缺少与 /ai/test-provider 对等的限流,providers.py:464"
        )
    finally:
        app.dependency_overrides.clear()


def test_providers_test_does_not_share_relay_rate_window() -> None:
    """HARDENING: `/ai/providers/test` 与 relay 的 60/min 窗口**不**共享。

    这是「无总闸」的现状快照:单个账号可以「relay 60/分钟 用完 → 转
    /providers/test 继续探测」。断言当前行为成立,与上一个用例
    (该端点自身无限流)共同刻画资源耗尽面。
    """
    client, Session = _make_client()
    try:
        from src.routers.ai import relay as relay_module
        from src.routers.ai import test_provider as tp_module

        relay_module._RATE_WINDOWS.clear()
        tp_module._RATE_WINDOWS.clear()
        email = "prov-adv-testshare@example.com"
        token = _login(client, email)
        _create(client, token, audioModel="")

        from src.models import User

        with Session() as db:
            uid = db.scalar(select(User.id).where(User.email == email))

        for _ in range(20):
            client.post(
                "/api/v1/ai/providers/test", headers=_auth(token),
                json={"providerId": "p1", "capability": "speech"},
            )
        assert len(relay_module._RATE_WINDOWS.get(uid, [])) == 0, (
            "providers/test 消耗了 relay 的限流窗口 —— 说明两个入口共用计数;"
            "若为空则证明二者独立(无总闸),providers.py:464"
        )
    finally:
        app.dependency_overrides.clear()


def test_providers_test_without_auth_is_401() -> None:
    """未登录调 /providers/test → 401。"""
    client, Session = _make_client()
    try:
        res = client.post(
            "/api/v1/ai/providers/test",
            json={"providerId": "p1", "capability": "text"},
        )
        assert res.status_code == 401, res.text
    finally:
        app.dependency_overrides.clear()
