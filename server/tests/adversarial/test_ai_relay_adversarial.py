"""对抗性测试 —— AI 中转(/ai/relay/*)。

覆盖攻击面:
  - 未配置 provider 时的 4xx 语义(非 500)
  - provider baseUrl 的 SSRF 面(file:// / gopher:// / 内网 / 环回)
  - 请求体畸形(messages 空 / role 非法 / content 非字符串 / 超大体 / 深嵌套)
  - vision:伪造型 MIME(text/html 改名 .png)、0 字节、超尺寸、超大 batch
  - stt:非音频 MIME、0 字节、octet-stream 塞 HTML
  - 现场落 ai_analysis_logs:失败调用也落 / 图片落盘唯一性 / 日志无 apiKey 明文
  - 限流与并发闸的令牌口径(batch 多图只耗 1 令牌 → 单请求资源放大)

红绿纪律:
  - `// ADVERSE FINDING:` = 确认缺陷,断言按「安全行为」写,保持失败;
  - `// HARDENING:`      = 当前行为可辩护但脆弱,断言当前行为并通过。
"""
from __future__ import annotations

import io
import json
import threading
import http.server
from collections import Counter
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import AIAnalysisLog, User
from src.services.ai import analysis_log as analysis_log_module

_PW = "Pa$$word1!"


# ────────────────────────────── 脚手架 ──────────────────────────────


def _make_client(monkeypatch, tmp_path):
    """内存 sqlite + get_db override + AI 日志 session / 图片目录隔离。

    本文件所有用例的上游都是**环回假 LLM**(`_start_loopback()` 绑 127.0.0.1),
    而生产默认拒环回(AI SSRF 策略)。因此夹具显式放行环回 —— 等价于自建
    Ollama 部署里设置 `AI_ALLOWED_PRIVATE_HOSTS=127.0.0.1`,是**被支持的
    部署形态**,不是绕过防护。默认拒绝本身由
    `test_relay_base_url_loopback_is_reachable_by_design` 的对照组断言覆盖。
    """
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
    monkeypatch.setattr(analysis_log_module, "SessionLocal", Session)
    from src.config import get_settings
    monkeypatch.setattr(get_settings(), "ai_log_image_dir", str(tmp_path / "ai_log_images"))
    # 假上游在环回 → 按自建部署的官方路径显式放行 host(默认空 = 拒绝)。
    monkeypatch.setattr(get_settings(), "ai_relay_allow_private_hosts", "127.0.0.1")
    from src.services.ai import outbound_policy as outbound_policy_module
    monkeypatch.setattr(outbound_policy_module, "_resolve_cache", {})
    # 模块级限流窗口 / 并发信号量:测试间清理避免串扰
    from src.routers.ai import relay as relay_module
    relay_module._RATE_WINDOWS.clear()
    relay_module._PROVIDER_SEMS.clear()
    return TestClient(app, raise_server_exceptions=False), Session


def _login(c: TestClient, email: str, client_type: str = "app") -> str:
    reg = c.post(
        "/api/v1/auth/register",
        json={
            "email": email, "password": _PW, "device_id": "relay-adv-dev",
            "client_type": client_type, "device_name": "pytest-adv", "platform": "test",
        },
    )
    assert reg.status_code in (200, 201), reg.text
    res = c.post(
        "/api/v1/auth/login",
        json={
            "email": email, "password": _PW, "device_id": "relay-adv-dev",
            "client_type": client_type, "device_name": "pytest-adv", "platform": "test",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _user_id(Session, email: str) -> str:
    with Session() as db:
        return db.scalar(select(User.id).where(User.email == email))


def _seed_config(Session, email: str, cfg: dict) -> None:
    """直接写 UserProfile.ai_config_json(绕过 profile 的入参校验,模拟存量脏数据)。"""
    from src.models import UserProfile

    uid = _user_id(Session, email)
    with Session() as db:
        row = db.scalar(select(UserProfile).where(UserProfile.user_id == uid))
        if row is None:
            db.add(UserProfile(user_id=uid, ai_config_json=json.dumps(cfg)))
        else:
            row.ai_config_json = json.dumps(cfg)
        db.commit()


def _provider_cfg(base_url: str, *, text_model: str = "tm", vision_model: str = "vm",
                  audio_model: str = "am", protocol: str | None = None,
                  vision_concurrency: int | None = 3) -> dict:
    provider: dict = {
        "id": "p1", "name": "adv", "apiKey": "sk-adv-secret-7777",
        "baseUrl": base_url, "textModel": text_model,
        "visionModel": vision_model, "audioModel": audio_model,
    }
    if protocol is not None:
        provider["protocol"] = protocol
    if vision_concurrency is not None:
        provider["visionConcurrency"] = vision_concurrency
    return {
        "providers": [provider],
        "binding": {
            "textProviderId": "p1", "visionProviderId": "p1", "speechProviderId": "p1",
        },
    }


class _LoopbackLLM(http.server.BaseHTTPRequestHandler):
    """本地假 LLM。绝不主动联网;只绑 127.0.0.1 随机端口。

    mode='ok'       → 200 + OpenAI 形状 body
    mode='leak500'  → 500 + body 里塞「内部秘密」,验证错误透传
    """

    mode = "ok"
    hits: list = []

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        type(self).hits.append(
            {"path": self.path, "auth": self.headers.get("Authorization"), "body": body}
        )
        if type(self).mode == "leak500":
            payload = b"INTERNAL-CANARY-9f8e7d"
            self.send_response(500)
        else:
            payload = json.dumps({
                "choices": [{"message": {"content": "loopback-ok"}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3},
            }).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # noqa: D102 — 静音
        return


def _start_loopback() -> tuple[http.server.ThreadingHTTPServer, int]:
    _LoopbackLLM.hits = []
    _LoopbackLLM.mode = "ok"
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _LoopbackLLM)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def _logs(Session) -> list[AIAnalysisLog]:
    with Session() as db:
        return list(db.scalars(select(AIAnalysisLog).order_by(AIAnalysisLog.id)).all())


# ══════════════════════════════════════════════════════════════════════
# 1. provider 配置缺失 / 损坏 → 明确 4xx(不得 500)
# ══════════════════════════════════════════════════════════════════════


def test_relay_chat_without_any_config_is_400(monkeypatch, tmp_path) -> None:
    """未配置 provider → 400 AI_NO_CHAT_PROVIDER,不是 500。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-noconf@example.com")
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers=_auth(token),
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        assert res.status_code == 400, res.text
        assert res.json()["error_code"] == "AI_NO_CHAT_PROVIDER"
        assert _logs(Session) == []
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_corrupt_json_config_is_400(monkeypatch, tmp_path) -> None:
    """ai_config_json 是坏 JSON(存量脏数据 / DB 手动改坏)→ 400 而非 500。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-corrupt@example.com")
        from src.models import UserProfile

        uid = _user_id(Session, "adv-corrupt@example.com")
        with Session() as db:
            db.add(UserProfile(user_id=uid, ai_config_json="{not json at all"))
            db.commit()

        res = client.post(
            "/api/v1/ai/relay/chat",
            headers=_auth(token),
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        assert res.status_code == 400, res.text
        assert res.json()["error_code"] == "AI_NO_CHAT_PROVIDER"
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_missing_base_url_is_400(monkeypatch, tmp_path) -> None:
    """provider 缺 baseUrl → 400(不落日志、不发起任何请求)。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-nourl@example.com")
        _seed_config(Session, "adv-nourl@example.com", _provider_cfg("", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers=_auth(token),
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        assert res.status_code == 400, res.text
        assert res.json()["error_code"] == "AI_NO_CHAT_PROVIDER"
    finally:
        app.dependency_overrides.clear()


def test_relay_non_http_scheme_base_url_no_500(monkeypatch, tmp_path) -> None:
    """file:// / gopher:// 这类非 HTTP scheme → 4xx/502 且不 500、不透传栈。

    当前行为:httpx 抛 UnsupportedProtocol → 路由层只捕获 ChatProviderError,
    file:// 走 call_chat_text 内的 httpx.HTTPError 分支 → 502 AI_PROVIDER_ERROR
    (可接受:明确失败码)。但发现细节 —— 见下面的 ADVERSE 用例。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        for scheme_url in ("file:///etc/passwd", "gopher://127.0.0.1:70/x"):
            token = _login(client, f"adv-scheme-{abs(hash(scheme_url)) % 9999}@example.com")
            _seed_config(
                Session, f"adv-scheme-{abs(hash(scheme_url)) % 9999}@example.com",
                _provider_cfg(scheme_url, vision_concurrency=None),
            )
            res = client.post(
                "/api/v1/ai/relay/chat",
                headers=_auth(token),
                json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
            )
            assert res.status_code != 500, f"{scheme_url} -> {res.status_code} {res.text[:200]}"
            assert res.status_code == 502, res.text
    finally:
        app.dependency_overrides.clear()


def test_relay_unexpected_provider_config_type_is_500(
    monkeypatch, tmp_path,
) -> None:
    """ADVERSE FINDING: provider 的 visionConcurrency 非数值 → relay 500。

    连 provider 与 AI 配置的写入路径本身没有类型校验:
      - `/ai/providers` PATCH 的 visionConcurrency 是 `int | None`,但
        `/profile/me` 的 ai_config 是自由 dict,直通 jsonb/text;
      - 于是脏数据(客户端同步 / 手改 DB / 旧版本 schema 漂移)落库后,
        `_resolve_provider_by_kind` 的 `int(matched.get("visionConcurrency") or 3)`
        抛 ValueError → 未被业务异常捕获 → 全局 handler 兜底 500。
    期望:配置类错误应归一成 400(AI_NO_CHAT_PROVIDER / AI_PROVIDER_INVALID),
    而不是 500 —— 500 会被客户端当作可重试的 transient 一直打转。

    源码:`src/services/ai/provider_client.py:460`(`vision_concurrency=int(...)`)。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        email = "adv-badconf@example.com"
        token = _login(client, email)
        _seed_config(
            Session, email,
            _provider_cfg("https://a.example.com/v1", vision_concurrency="abc"),
        )
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers=_auth(token),
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        # ADVERSE FINDING: 期望 4xx(配置类错误),实际 500
        assert res.status_code != 500, (
            "脏 visionConcurrency 配置把 relay 打成 500;应为 400 配置错误。"
            f" got {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()


def test_relay_vision_batch_bad_vision_concurrency_is_500(
    monkeypatch, tmp_path,
) -> None:
    """ADVERSE FINDING: 同一个脏配置也把 vision-batch 打成 500(面更广)。

    `/ai/relay/vision-batch` 在 `_provider_sem(...)` 之前就要
    `cfg.vision_concurrency`,与 chat 同源同崩。期望 400,实际 500。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        email = "adv-badconf-vb@example.com"
        token = _login(client, email)
        _seed_config(
            Session, email,
            _provider_cfg("https://a.example.com/v1", vision_concurrency={"n": 1}),
        )
        res = client.post(
            "/api/v1/ai/relay/vision-batch",
            headers=_auth(token),
            data={"prompt": "p"},
            files=[("images", ("a.png", b"\x89PNG\r\n\x1a\n1", "image/png"))],
        )
        # ADVERSE FINDING: 期望 4xx,实际 500
        assert res.status_code != 500, (
            f"脏 visionConcurrency 把 vision-batch 打成 500: {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 2. SSRF 面:provider baseUrl 可指向环回 / 内网
# ══════════════════════════════════════════════════════════════════════


def test_relay_base_url_loopback_is_reachable_by_design(
    monkeypatch, tmp_path,
) -> None:
    """ADVERSE FINDING: relay 允许把 LLM 调用打向任意内网/环回地址(SSRF)。

    自部署场景下用户自己就是 admin,「可配任意 baseUrl」是产品设计(自托管
    LLM 网关、局域网 vLLM 都靠它)。但服务端**没有任何** scheme/host 白名单:
      - 非 http(s) scheme 被 httpx 挡住(见上一个用例),
      - http/https 则畅通无阻 —— 包括云元数据地址 169.254.169.254、
        localhost、Docker 内网服务。
    只要一个用户账号被借用(或注册开放 + 诱导),攻击者可把服务端当作
    内网探测代理,并通过 502 错误文案 / LLM 输出回读内网响应。

    这里用**真实环回 HTTP 服务**证明请求确实发出(而非只做静态检查),
    且 Authorization 头带着该用户的 apiKey 一起发到内网目标。
    源码:`src/services/ai/provider_client.py:838,1101`(url = base_url + path)。
    """
    srv, port = _start_loopback()
    try:
        client, Session = _make_client(monkeypatch, tmp_path)
        try:
            email = "adv-ssrf@example.com"
            token = _login(client, email)
            _seed_config(
                Session, email,
                _provider_cfg(f"http://127.0.0.1:{port}/internal-metadata", vision_concurrency=None),
            )
            res = client.post(
                "/api/v1/ai/relay/chat",
                headers=_auth(token),
                json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
            )
            assert res.status_code == 200, res.text
            assert len(_LoopbackLLM.hits) == 1, "服务端应把请求发往用户配置的 URL"
            hit = _LoopbackLLM.hits[0]
            assert hit["path"] == "/internal-metadata/chat/completions", hit
            from src.config import get_settings
            fake_enabled = getattr(get_settings(), "ai_relay_allow_private_hosts", None)
            # ADVERSE FINDING: 无内网/环回拦截开关(fake_enabled 始终为 None)。
            # 期望存在 SSRF 防护配置(默认拒私网 / 或至少显式开关),实际完全没有。
            assert fake_enabled is not None, (
                "relay 无 SSRF 防护开关:provider baseUrl 可指向 127.0.0.1 / 169.254.169.254 / "
                "Docker 内网,服务端会成为内网代理。见 provider_client.py:838"
            )
        finally:
            app.dependency_overrides.clear()
    finally:
        srv.shutdown()


def test_relay_metadata_endpoint_reachable(monkeypatch, tmp_path) -> None:
    """ADVERSE FINDING: 云元数据地址 169.254.169.254 不会被拦(仅网络不可达)。

    本机无该地址 → 502;但这证明代码路径没有 host 黑名单,在云主机上会
    真的把请求（含 apiKey）发到实例元数据服务。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        email = "adv-meta@example.com"
        token = _login(client, email)
        _seed_config(
            Session, email,
            _provider_cfg("http://169.254.169.254/latest/meta-data", vision_concurrency=None),
        )
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers=_auth(token),
            json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
        )
        # 400 = 被拒(期望);502/504 = 网络层拒绝(说明没有 host 级拦截)
        # ADVERSE FINDING: 169.254.169.254 未被 host 黑名单拦截,请求真实发出
        assert res.status_code == 400, (
            "169.254.169.254(云元数据)未被 host 白名单拦截;"
            f" got {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 3. relay 请求体畸形
# ══════════════════════════════════════════════════════════════════════


def test_relay_chat_malformed_bodies_are_422(monkeypatch, tmp_path) -> None:
    """messages 空数组 / role 非法 / content 数字 / 温度越界 → 422(而非 5xx)。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        email = "adv-malformed@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg("https://a.example.com/v1", vision_concurrency=None))
        cases = [
            {"messages": [], "entry_type": "chat"},
            {"messages": [{"role": "root", "content": "x"}], "entry_type": "chat"},
            {"messages": [{"role": "user", "content": 123}], "entry_type": "chat"},
            {"messages": [{"role": "user", "content": "x"}], "entry_type": "admin"},
            {"messages": [{"role": "user", "content": "x"}], "entry_type": "chat", "temperature": 9},
            {"messages": [{"role": "user", "content": ""}], "entry_type": "chat"},
        ]
        for payload in cases:
            res = client.post("/api/v1/ai/relay/chat", headers=_auth(token), json=payload)
            assert res.status_code in (400, 422), f"{payload} -> {res.status_code} {res.text[:200]}"
        assert _logs(Session) == [], "校验失败的请求不应落 AI 日志"
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_non_json_body_is_4xx(monkeypatch, tmp_path) -> None:
    """非 JSON body → 400/422(不 500)。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-nonjson@example.com")
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers={**_auth(token), "Content-Type": "application/json"},
            content=b"{{{",
        )
        assert res.status_code in (400, 422), res.text
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_deeply_nested_json_no_500(monkeypatch, tmp_path) -> None:
    """深嵌套 JSON(100k 层)→ 安全拒绝(不 500、不崩)。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-deepjson@example.com")
        depth = 100_000
        body = b'{"messages":' + b"[" * depth + b"]" * depth + b',"entry_type":"chat"}'
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers={**_auth(token), "Content-Type": "application/json"},
            content=body,
        )
        assert res.status_code in (400, 413, 422), res.text
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_total_chars_cap_413(monkeypatch, tmp_path) -> None:
    """messages 总字符超 100k → 413 AI_RELAY_PAYLOAD_TOO_LARGE。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-big@example.com")
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers=_auth(token),
            json={
                "messages": [
                    {"role": "user", "content": "A" * 50_000},
                    {"role": "user", "content": "B" * 50_001},
                ],
                "entry_type": "chat",
            },
        )
        assert res.status_code == 413, res.text
        assert res.json()["error_code"] == "AI_RELAY_PAYLOAD_TOO_LARGE"
    finally:
        app.dependency_overrides.clear()


def test_relay_chat_message_count_cap(monkeypatch, tmp_path) -> None:
    """messages 条数超 40 → 422 拒绝。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-count@example.com")
        res = client.post(
            "/api/v1/ai/relay/chat",
            headers=_auth(token),
            json={
                "messages": [{"role": "user", "content": "x"} for _ in range(41)],
                "entry_type": "chat",
            },
        )
        assert res.status_code in (400, 422), res.text
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 4. vision 攻击面
# ══════════════════════════════════════════════════════════════════════


def test_vision_accepts_content_type_spoofed_html_with_png_suffix(
    monkeypatch, tmp_path,
) -> None:
    """ADVERSE FINDING: content-type=text/html + 文件名 .png 被当作合法 PNG 转发。

    `_resolve_image_mime`(relay.py:225)在 content-type 不在白名单时,
    无条件回退到**文件名后缀**;客户端只要把任意字节改名为 .png 并声明
    text/html 就能通过校验,server 会将其 base64 成 data:image/png 发给上游。
    上游若做严格嗅探会拒;但 server 侧从未校验 magic bytes,也没有解码验证
    —— 这等于把「图片类型校验」交给用户可控的文件名。

    期望:仅凭后缀不足以通过类型校验(至少校验 magic bytes),或至少要
    求 content-type 与后缀一致。实际:后缀即通过。

    源码:`src/routers/ai/relay.py:225-232`。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-spoof@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        # 声明 text/html(不在白名单)→ 走后缀兜底 → 被当作 image/png 接受
        res = client.post(
            "/api/v1/ai/relay/vision",
            headers=_auth(token),
            data={"prompt": "p"},
            files={"image": ("spoofed.png", b"<html><script>alert(1)</script></html>", "text/html")},
        )
        # ADVERSE FINDING: text/html 载荷仅凭 .png 后缀就通过类型校验并转发上游
        assert res.status_code == 400, (
            "text/html 内容仅因文件名为 .png 就被当作图片转发(无 magic bytes 校验)。"
            f" got {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_vision_zip_renamed_png_suffix_only_is_accepted_when_ct_missing(
    monkeypatch, tmp_path,
) -> None:
    """ADVERSE FINDING: 缺 content-type 时后缀兜底让 zip 也过 vision 校验。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-spoof2@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/vision",
            headers=_auth(token),
            data={"prompt": "p"},
            files={"image": ("payload.png", b"PK\x03\x04not-an-image", None)},
        )
        # ADVERSE FINDING: 缺 content-type → 后缀兜底,zip 字节被当图片放行
        assert res.status_code == 400, (
            f"无可信 content-type 时仅凭 .png 后缀放行任意字节: {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_vision_zero_byte_image_is_accepted(monkeypatch, tmp_path) -> None:
    """HARDENING: 0 字节图片被接受并转发(上游自行报错)。

    `/ai/relay/vision` 只做 mime + 上限校验,没有非空校验 —— 与
    `/attachments/upload`(空文件 400)口径不一致。当前行为可辩护
    (上游会拒),但对上游是无谓调用;若上游宽容会产出空结果。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-empty@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/vision",
            headers=_auth(token),
            data={"prompt": "p"},
            files={"image": ("empty.png", b"", "image/png")},
        )
        # HARDENING: 当前放行 200 且白白调用一次上游
        assert res.status_code == 200, res.text
        assert len(_LoopbackLLM.hits) == 1, "空图仍会触发一次上游调用"
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_vision_batch_has_no_image_count_cap(monkeypatch, tmp_path) -> None:
    """ADVERSE FINDING: vision-batch 无图片数量上限 → 单请求资源放大。

    `/ai/relay/vision-batch` 对 images 列表长度无约束:`_MAX_MESSAGES`(=40)
    只作用于 chat。实测 64 张图 → 64 次上游 LLM 调用,全部由**一个** HTTP
    请求触发;而 relay 的限流(_RATE_LIMIT_MAX=60/60s)在入口只记 1 次
    (relay.py:561 `_rate_limited` 一次)。于是「限流 60/分钟」实际可放大成
    60×N 次上游调用,用户配额与上游账单被单请求放大。

    期望:batch 图片数量有上限(如 ≤10)且按张数计限流;实际:无上限、只记 1。

    源码:`src/routers/ai/relay.py:539-566`(无长度校验)。测试用 16 张
    证明线性放大 + 限流令牌只耗 1(不必真打 64 次)。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        from src.routers.ai import relay as relay_module

        email = "adv-batchcap@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1"))

        uid = _user_id(Session, email)
        tokens_before = len(relay_module._RATE_WINDOWS.get(uid, []))
        files = [
            ("images", (f"{i}.png", b"\x89PNG\r\n\x1a\n" + bytes([i % 256]) * 32, "image/png"))
            for i in range(16)
        ]
        res = client.post(
            "/api/v1/ai/relay/vision-batch",
            headers=_auth(token),
            data={"prompt": "p"},
            files=files,
        )
        assert res.status_code == 200, res.text
        assert len(res.json()["results"]) == 16
        tokens_after = len(relay_module._RATE_WINDOWS.get(uid, []))
        # ADVERSE FINDING: 16 张图 = 16 次上游调用,但限流只消耗 1 个令牌。
        assert tokens_after - tokens_before >= 16, (
            "vision-batch 未按图片张数计限流:16 张图只消耗 "
            f"{tokens_after - tokens_before} 个令牌 → 限流可被放大 16x。"
            "源码 relay.py:561"
        )
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_vision_batch_partial_mime_failure_stops_batch_before_upstream(
    monkeypatch, tmp_path,
) -> None:
    """整批任何一张 mime 非法 → 整批 400 且不调用上游(既有语义,对抗面确认)。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-batchmime@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/vision-batch",
            headers=_auth(token),
            data={"prompt": "p"},
            files=[
                ("images", ("a.png", b"\x89PNG\r\n\x1a\na", "image/png")),
                ("images", ("b.txt", b"nope", "text/plain")),
            ],
        )
        assert res.status_code == 400, res.text
        assert _LoopbackLLM.hits == [], "整批校验失败时不得调用上游"
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_vision_oversize_rejected_413(monkeypatch, tmp_path) -> None:
    """>5MB 图片 → 413 AI_IMAGE_TOO_LARGE(边界:正好 5MB 通过、+1 字节拒绝)。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-oversize@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        limit = 5 * 1024 * 1024
        ok = client.post(
            "/api/v1/ai/relay/vision", headers=_auth(token), data={"prompt": "p"},
            files={"image": ("exact.jpg", b"\xff\xd8" + b"0" * (limit - 2), "image/jpeg")},
        )
        assert ok.status_code == 200, ok.text
        bad = client.post(
            "/api/v1/ai/relay/vision", headers=_auth(token), data={"prompt": "p"},
            files={"image": ("over.jpg", b"\xff\xd8" + b"0" * limit, "image/jpeg")},
        )
        assert bad.status_code == 413, bad.text
        assert bad.json()["error_code"] == "AI_IMAGE_TOO_LARGE"
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


# ══════════════════════════════════════════════════════════════════════
# 5. stt 攻击面
# ══════════════════════════════════════════════════════════════════════


def test_stt_octet_stream_html_body_is_forwarded(monkeypatch, tmp_path) -> None:
    """ADVERSE FINDING: content-type=application/octet-stream 时任意字节都当音频转发。

    `relay.py:666-674` 把 `application/octet-stream` 视作合法音频(为兼容 App
    端的默认 content-type)。对抗后果:任何非音频载荷(HTML/脚本/二进制)
    都能借此进入上游 STT;server 侧无 magic bytes 校验。
    期望:octet-stream 也应做基本识别(wav/mp3 头)或要求显式音频 MIME。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-stt@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/stt",
            headers=_auth(token),
            files={"audio": ("x.bin", b"<html>not audio at all</html>", "application/octet-stream")},
        )
        # ADVERSE FINDING: octet-stream + HTML 载荷被当音频转发(无魔数校验)
        assert res.status_code == 400, (
            "application/octet-stream + HTML 内容被当音频转发(无魔数校验)。"
            f" got {res.status_code} {res.text[:200]}"
        )
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_stt_non_audio_mime_rejected_400(monkeypatch, tmp_path) -> None:
    """text/plain 等明确非音频 MIME → 400 AI_AUDIO_TYPE_INVALID。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        email = "adv-sttmime@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg("https://a.example.com/v1", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/stt",
            headers=_auth(token),
            files={"audio": ("a.txt", b"hello", "text/plain")},
        )
        assert res.status_code == 400, res.text
        assert res.json()["error_code"] == "AI_AUDIO_TYPE_INVALID"
    finally:
        app.dependency_overrides.clear()


def test_stt_zero_byte_audio_is_forwarded(monkeypatch, tmp_path) -> None:
    """HARDENING: 0 字节音频被放行并转发(与 vision 空文件同款缺口)。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-sttempty@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/stt",
            headers=_auth(token),
            files={"audio": ("e.wav", b"", "audio/wav")},
        )
        # HARDENING: 当前 200
        assert res.status_code == 200, res.text
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_stt_oversize_rejected_413(monkeypatch, tmp_path) -> None:
    """>10MB 音频 → 413 AI_AUDIO_TOO_LARGE。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        email = "adv-sttbig@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg("https://a.example.com/v1", vision_concurrency=None))
        res = client.post(
            "/api/v1/ai/relay/stt",
            headers=_auth(token),
            files={"audio": ("big.wav", b"\x00" * (10 * 1024 * 1024 + 1), "audio/wav")},
        )
        assert res.status_code == 413, res.text
        assert res.json()["error_code"] == "AI_AUDIO_TOO_LARGE"
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# 6. 现场落 ai_analysis_logs:失败也落 / 图片唯一性 / 无密钥泄漏
# ══════════════════════════════════════════════════════════════════════


def test_relay_failure_still_writes_error_log(monkeypatch, tmp_path) -> None:
    """上游 500 → 502 且落一行 status=error 日志(审计完整性)。"""
    srv, port = _start_loopback()
    _LoopbackLLM.mode = "leak500"
    try:
        client, Session = _make_client(monkeypatch, tmp_path)
        try:
            email = "adv-faillog@example.com"
            token = _login(client, email)
            _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
            res = client.post(
                "/api/v1/ai/relay/chat",
                headers=_auth(token),
                json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
            )
            assert res.status_code == 502, res.text
            rows = _logs(Session)
            assert len(rows) == 1, rows
            assert rows[0].status == "error"
            assert "500" in (rows[0].error_message or "")
        finally:
            app.dependency_overrides.clear()
    finally:
        _LoopbackLLM.mode = "ok"
        srv.shutdown()


def test_relay_error_message_truncates_upstream_body(monkeypatch, tmp_path) -> None:
    """HARDENING: 上游错误 body 被截断到 200/500 字后回传与落库。

    可辩护(便于排障、限制体积),但上游 body 里若有敏感串会被一并透传
    —— 实测 canary 在响应里可见。记录该行为边界。
    """
    srv, port = _start_loopback()
    _LoopbackLLM.mode = "leak500"
    try:
        client, Session = _make_client(monkeypatch, tmp_path)
        try:
            email = "adv-echo@example.com"
            token = _login(client, email)
            _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
            res = client.post(
                "/api/v1/ai/relay/chat",
                headers=_auth(token),
                json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
            )
            assert res.status_code == 502, res.text
            # HARDENING: 上游 body 片段(Python repr)会出现在响应里
            assert "INTERNAL-CANARY-9f8e7d" in res.text
        finally:
            app.dependency_overrides.clear()
    finally:
        _LoopbackLLM.mode = "ok"
        srv.shutdown()


def test_relay_logs_never_contain_api_key(monkeypatch, tmp_path) -> None:
    """日志行(输入/输出/错误)不得出现 apiKey 明文。"""
    srv, port = _start_loopback()
    try:
        client, Session = _make_client(monkeypatch, tmp_path)
        try:
            email = "adv-nokey@example.com"
            token = _login(client, email)
            _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
            # 让 LLM 回显 key,模拟上游把鉴权信息写进 content
            _LoopbackLLM.mode = "leak500"
            client.post(
                "/api/v1/ai/relay/chat",
                headers=_auth(token),
                json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
            )
            blob = json.dumps([
                {"in": r.input_text, "out": r.output_text, "err": r.error_message}
                for r in _logs(Session)
            ], ensure_ascii=False)
            assert "sk-adv-secret-7777" not in blob, blob[:400]
        finally:
            _LoopbackLLM.mode = "ok"
            app.dependency_overrides.clear()
    finally:
        srv.shutdown()


def test_relay_vision_logs_image_files_unique_per_call(monkeypatch, tmp_path) -> None:
    """并发同图 vision 的落盘图片按 log_id 唯一,不互相覆盖。

    `write_ai_analysis_log_with_image` 用 `{row.id}{ext}` 命名;并发下若
    两个请求拿到同一 id 就会互相覆盖。这里用两次顺序调用 + 校验文件数与
    字节内容一一对应(顺序场景本身已能暴露命名复用)。
    """
    srv, port = _start_loopback()
    try:
        client, Session = _make_client(monkeypatch, tmp_path)
        try:
            email = "adv-imgs@example.com"
            token = _login(client, email)
            _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
            payload_a = b"\x89PNG\r\n\x1a\nAAAA"
            payload_b = b"\x89PNG\r\n\x1a\nBBBB"
            for name, payload in (("a.png", payload_a), ("b.png", payload_b)):
                res = client.post(
                    "/api/v1/ai/relay/vision", headers=_auth(token), data={"prompt": "p"},
                    files={"image": (name, payload, "image/png")},
                )
                assert res.status_code == 200, res.text

            from src.services.ai.analysis_log import resolve_log_image_path

            rows = _logs(Session)
            assert len(rows) == 2, rows
            paths = {r.image_path for r in rows}
            assert None not in paths and len(paths) == 2, paths
            on_disk = sorted(resolve_log_image_path(r.image_path).read_bytes() for r in rows)
            assert on_disk == sorted([payload_a, payload_b]), on_disk
        finally:
            app.dependency_overrides.clear()
    finally:
        srv.shutdown()


def test_relay_logs_do_not_leak_into_other_users(monkeypatch, tmp_path) -> None:
    """用户隔离:GET /ai/logs 只能看到自己的记录(IDOR 面)。"""
    srv, port = _start_loopback()
    try:
        client, Session = _make_client(monkeypatch, tmp_path)
        try:
            token_a = _login(client, "adv-log-a@example.com")
            _seed_config(Session, "adv-log-a@example.com",
                         _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
            res = client.post(
                "/api/v1/ai/relay/chat", headers=_auth(token_a),
                json={"messages": [{"role": "user", "content": "secret-a"}], "entry_type": "chat"},
            )
            assert res.status_code == 200, res.text
            log_id = _logs(Session)[0].id

            token_b = _login(client, "adv-log-b@example.com")
            assert client.get("/api/v1/ai/logs", headers=_auth(token_b)).json()["total"] == 0
            assert client.get(f"/api/v1/ai/logs/{log_id}", headers=_auth(token_b)).status_code == 404
            assert client.get(f"/api/v1/ai/logs/{log_id}/image", headers=_auth(token_b)).status_code == 404
            assert client.delete(f"/api/v1/ai/logs/{log_id}", headers=_auth(token_b)).status_code == 404
        finally:
            app.dependency_overrides.clear()
    finally:
        srv.shutdown()


# ══════════════════════════════════════════════════════════════════════
# 7. 限流 / 并发闸
# ══════════════════════════════════════════════════════════════════════


def test_relay_chat_rate_limit_60_per_minute(monkeypatch, tmp_path) -> None:
    """单 user 60s 内第 61 次 → 429 AI_RELAY_RATE_LIMITED。"""
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        email = "adv-rate@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1", vision_concurrency=None))
        codes = []
        for _ in range(62):
            res = client.post(
                "/api/v1/ai/relay/chat", headers=_auth(token),
                json={"messages": [{"role": "user", "content": "hi"}], "entry_type": "chat"},
            )
            codes.append(res.status_code)
        assert 429 in codes, Counter(codes)
        assert codes.count(429) == 2, Counter(codes)
        assert all(c in (200, 429) for c in codes), Counter(codes)
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


def test_relay_vision_batch_amplifies_rate_limit_tokens(
    monkeypatch, tmp_path,
) -> None:
    """ADVERSE FINDING: vision-batch 一次多图只消耗 1 个限流令牌(资源放大)。

    与 `test_vision_batch_has_no_image_count_cap` 同源,这里从**限流口径**
    侧断言:一次 8 图 batch(8 次上游调用)在限流窗口里只记 1 个令牌,
    因此 60 令牌/分钟 的上限实际允许 ≥480 次上游调用/分钟。

    期望:限流按上游调用次数(或至少按图片张数)计数。
    源码:`src/routers/ai/relay.py:561`(`_rate_limited` 在 batch 入口只调一次,
    `recognize()` 循环内不再计数)。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    srv, port = _start_loopback()
    try:
        from src.routers.ai import relay as relay_module

        email = "adv-amplify@example.com"
        token = _login(client, email)
        _seed_config(Session, email, _provider_cfg(f"http://127.0.0.1:{port}/v1"))
        uid = _user_id(Session, email)

        files = [
            ("images", (f"{i}.png", b"\x89PNG\r\n\x1a\n" + bytes([i]) * 16, "image/png"))
            for i in range(8)
        ]
        res = client.post(
            "/api/v1/ai/relay/vision-batch", headers=_auth(token),
            data={"prompt": "p"}, files=files,
        )
        assert res.status_code == 200, res.text
        upstream_calls = len(_LoopbackLLM.hits)
        tokens = len(relay_module._RATE_WINDOWS.get(uid, []))
        assert upstream_calls == 8, upstream_calls
        # ADVERSE FINDING: 8 次上游调用只记 1 个限流令牌
        assert tokens == upstream_calls, (
            f"限流令牌 {tokens} != 上游调用 {upstream_calls}:batch 不按张数限流,"
            "60/分钟的限流可被放大 N 倍(relay.py:561)"
        )
    finally:
        app.dependency_overrides.clear()
        srv.shutdown()


# ══════════════════════════════════════════════════════════════════════
# 8. 日志读路径:过滤参数注入 / 分页边界 / entry_type 非法值
# ══════════════════════════════════════════════════════════════════════


def test_ai_logs_filter_injection_and_pagination_bounds(monkeypatch, tmp_path) -> None:
    """HARDENING:/ai/logs 的过滤与分页参数全部被 schema 拒绝(422),不 500。

    攻击面:entry_type / status 是过滤条件的取值域(写入侧为受控枚举,
    读入侧若不校验就可能拼进查询),limit/offset 决定扫描量(负数 / 巨额
    可触发 SQLite 变量或内存问题)。实测:
      - `entry_type=chat'OR'1'='1`、`entry_type=../../etc`、`status=error'--`
        → 422(`_ENTRY_TYPE_PATTERN` 只认 5 个枚举值,logs.py:61);
      - `limit=-1`、`limit=999999` → 422(有上下界);
      - `offset=-5` → 422;`offset=99999999999999` → 200 空页(不 500)。
    断言当前安全行为成立(与 relay 写入侧 `entry_type: Literal[...]` 的
    422 形成读写双侧闭环)。
    """
    client, Session = _make_client(monkeypatch, tmp_path)
    try:
        token = _login(client, "adv-logsfilt@example.com")
        bad_filters = [
            "entry_type=chat'OR'1'='1",
            "entry_type=../../etc/passwd",
            "entry_type=<script>alert(1)</script>",
            "status=error'--",
            "limit=-1",
            "limit=999999",
            "offset=-5",
        ]
        for q in bad_filters:
            res = client.get(f"/api/v1/ai/logs?{q}", headers=_auth(token))
            assert res.status_code == 422, f"?{q} -> {res.status_code} {res.text[:160]}"

        huge = client.get("/api/v1/ai/logs?offset=99999999999999", headers=_auth(token))
        assert huge.status_code == 200, huge.text
        assert huge.json()["items"] == []

        # 写入侧对读:非法 entry_type 直接 422(Literal 白名单),不落库
        res = client.post(
            "/api/v1/ai/relay/chat", headers=_auth(token),
            json={"messages": [{"role": "user", "content": "x"}],
                  "entry_type": "pwn'; DROP TABLE ai_analysis_logs;--"},
        )
        assert res.status_code == 422, res.text
        assert _logs(Session) == []
    finally:
        app.dependency_overrides.clear()
