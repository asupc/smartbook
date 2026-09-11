"""自适应参数剥离单元测试(issue #312)。

覆盖真实记账解析路径 `call_chat_json` 与 `_rejected_param` 的分类逻辑:
推理模型(kimi-k2.5 / o1 / o3 / R1)锁 temperature → 被拒时摘掉重发,无需真实 key。
"""
from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import patch

import httpx

from src.services.ai.provider_client import (
    ChatProviderConfig,
    _rejected_param,
    call_chat_json,
    call_chat_text,
    close_ai_http_client,
    supports_disabled_thinking,
    with_disabled_thinking,
)

_MOONSHOT_TEMP_ERR = (
    '{"error":{"message":"invalid temperature: only 1 is allowed for this model",'
    '"type":"invalid_request_error"}}'
)


# ──────────────── _rejected_param 分类 ────────────────


def test_rejected_param_structured_error_param():
    """OpenAI/o1/o3 错误体直接给 error.param。"""
    body = '{"error":{"param":"temperature","message":"unsupported value","code":"unsupported_value"}}'
    assert _rejected_param({"temperature": 0.2, "model": "o1"}, 400, body) == "temperature"


def test_rejected_param_text_fallback_moonshot():
    """Moonshot 不给 param,扫文案点名了哪个我们发出去的键。"""
    assert _rejected_param({"temperature": 0.2, "model": "kimi-k2.5"}, 400, _MOONSHOT_TEMP_ERR) == "temperature"


def test_rejected_param_never_strips_required_key():
    """'model not found' 含 'model',但 model 是必须键 → 不摘,返回 None。"""
    assert _rejected_param({"model": "missing", "messages": []}, 404, '{"error":"model not found"}') is None


def test_rejected_param_non_param_error_returns_none():
    """错误没点名我们发的任何可丢键 → None,交给上层照常报错。"""
    assert _rejected_param({"temperature": 0.2, "model": "x"}, 429, '{"error":"rate limited"}') is None


def test_rejected_param_success_status_returns_none():
    assert _rejected_param({"temperature": 0.2}, 200, "") is None


def test_rejected_param_response_format():
    """同一机制覆盖 response_format 不被支持的 provider。"""
    body = '{"error":{"message":"response_format is not supported by this model"}}'
    payload = {"model": "x", "messages": [], "response_format": {"type": "json_object"}}
    assert _rejected_param(payload, 400, body) == "response_format"


def test_disabled_thinking_is_only_added_for_glm_45_or_46():
    assert supports_disabled_thinking("glm-4.6v") is True
    assert supports_disabled_thinking("Pro/GLM-4.5-Air") is True
    assert supports_disabled_thinking("GLM-5.2") is True
    assert supports_disabled_thinking("Pro/GLM-4.5V") is False
    assert supports_disabled_thinking("GLM-4.7") is False
    assert supports_disabled_thinking("glm-4v-flash") is False
    assert supports_disabled_thinking("Qwen/Qwen3-VL-8B") is False

    # MiniMax M3 同字段关闭思考(官方文档);M2.x 官方明确无法关闭,不发送。
    assert supports_disabled_thinking("MiniMax-M3") is True
    assert supports_disabled_thinking("minimax/MiniMax-M3") is True
    assert supports_disabled_thinking("MiniMax-M2.1") is False
    assert supports_disabled_thinking("MiniMax-Text-01") is False

    # DeepSeek 默认开启思考(effort=high),disabled 是官方关闭写法;
    # 旧 deepseek-reasoner(R1)强制思考,不发送。
    assert supports_disabled_thinking("deepseek-flash") is True
    assert supports_disabled_thinking("deepseek-v4-pro") is True
    assert supports_disabled_thinking("deepseek-chat") is True
    assert supports_disabled_thinking("deepseek-reasoner") is False

    payload = {"model": "glm-4.6v", "messages": []}
    assert with_disabled_thinking(
        payload, model="glm-4.6v", disable_thinking=True
    )["thinking"] == {"type": "disabled"}
    assert payload == {"model": "glm-4.6v", "messages": []}
    assert "thinking" not in with_disabled_thinking(
        payload, model="glm-4v-flash", disable_thinking=True
    )
    assert with_disabled_thinking(
        {"model": "MiniMax-M3", "messages": []},
        model="MiniMax-M3",
        disable_thinking=True,
    )["thinking"] == {"type": "disabled"}


# ──────────────── call_chat_json 真实解析路径 ────────────────


def test_call_chat_json_strips_temperature_and_succeeds():
    """带温度 → 400 → 摘温度重发 → 返回解析好的 JSON。"""
    calls: list[dict | None] = []

    async def fake_post(self, url, headers=None, json=None, **_):
        calls.append(dict(json) if json else None)
        if json is not None and "temperature" in json:
            return httpx.Response(400, text=_MOONSHOT_TEMP_ERR)
        return httpx.Response(
            200, json={"choices": [{"message": {"content": '{"ok": true}'}}]}
        )

    cfg = ChatProviderConfig(
        provider_id="p1",
        base_url="https://api.moonshot.cn/v1",
        api_key="sk-x",
        model="kimi-k2.5",
    )
    with patch("httpx.AsyncClient.post", fake_post):
        result = asyncio.run(
            call_chat_json(config=cfg, messages=[{"role": "user", "content": "hi"}])
        )

    assert result.parsed == {"ok": True}
    assert len(calls) == 2                       # 带温度→被拒,不带温度→成功
    assert "temperature" in calls[0]
    assert "temperature" not in calls[1]



def test_call_chat_json_sends_disabled_thinking_for_glm46():
    calls: list[dict | None] = []

    async def fake_post(self, url, headers=None, json=None, **_):
        calls.append(dict(json) if json else None)
        return httpx.Response(
            200, json={"choices": [{"message": {"content": '{\"ok\": true}'}}]}
        )

    cfg = ChatProviderConfig(
        provider_id="p-glm",
        base_url="https://open.bigmodel.cn/api/paas/v4",
        api_key="sk-x",
        model="glm-4.6v",
    )
    with patch("httpx.AsyncClient.post", fake_post):
        result = asyncio.run(
            call_chat_json(
                config=cfg,
                messages=[{"role": "user", "content": "hi"}],
                disable_thinking=True,
            )
        )

    assert result.parsed == {"ok": True}
    assert len(calls) == 1
    assert calls[0]["thinking"] == {"type": "disabled"}

def test_ai_http_pool_reuses_client_across_providers_and_keeps_timeouts():
    """不同 provider 共用一个 keep-alive client，且每次请求保留独立 timeout。"""
    clients = []
    calls: list[dict] = []

    class FakeClient:
        def __init__(self, **kwargs):
            self.init_kwargs = kwargs
            self.is_closed = False
            self.close_count = 0
            clients.append(self)

        async def post(self, url, headers=None, json=None, timeout=None, **_):
            payload = dict(json) if json else {}
            calls.append({"url": url, "payload": payload, "timeout": timeout})
            if url.startswith("https://one.example") and "temperature" in payload:
                return httpx.Response(400, text=_MOONSHOT_TEMP_ERR)
            provider = "one" if url.startswith("https://one.example") else "two"
            return httpx.Response(
                200, json={"choices": [{"message": {"content": provider}}]},
            )

        async def aclose(self):
            self.close_count += 1
            self.is_closed = True

    async def scenario():
        await close_ai_http_client()
        settings = SimpleNamespace(ai_http_verify_ssl=False)
        with (
            patch("src.services.ai.provider_client.get_settings", return_value=settings),
            patch("src.services.ai.provider_client.httpx.AsyncClient", FakeClient),
        ):
            first = await call_chat_text(
                config=ChatProviderConfig(
                    provider_id="one",
                    base_url="https://one.example/v1",
                    api_key="sk-one",
                    model="kimi-k2.5",
                ),
                messages=[{"role": "user", "content": "hi"}],
                timeout=3.25,
            )
            second = await call_chat_text(
                config=ChatProviderConfig(
                    provider_id="two",
                    base_url="https://two.example/v1",
                    api_key="sk-two",
                    model="plain-model",
                ),
                messages=[{"role": "user", "content": "hi"}],
                timeout=7.5,
            )
            assert first.content == "one"
            assert second.content == "two"
            assert len(clients) == 1
            assert clients[0].init_kwargs["timeout"] is None
            assert clients[0].init_kwargs["verify"] is False
            limits = clients[0].init_kwargs["limits"]
            assert limits.max_connections == 32
            assert limits.max_keepalive_connections == 16
            assert [call["timeout"] for call in calls] == [3.25, 3.25, 7.5]
            assert "temperature" in calls[0]["payload"]
            assert "temperature" not in calls[1]["payload"]
            assert calls[0]["url"].startswith("https://one.example")
            assert calls[2]["url"].startswith("https://two.example")
            await close_ai_http_client()
            assert clients[0].close_count == 1

    asyncio.run(scenario())
