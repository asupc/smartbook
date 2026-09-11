"""Provider client — 解析 user.ai_config_json 拿 chat provider + 调用 OpenAI-compatible API。

跟 mobile lib/services/ai/ai_provider_config.dart 的 schema 对齐:

    ai_config = {
        "providers": [
            {
                "id": "zhipu_glm",
                "apiKey": "sk-xxx",
                "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
                "textModel": "glm-4-flash",
                "visionModel": "glm-4v-flash",
                ...
            }
        ],
        "binding": {
            "textProviderId": "zhipu_glm",
            "visionProviderId": "zhipu_glm",
            ...
        }
    }
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any

import httpx

from ...config import get_settings
from ...models import User, UserProfile

logger = logging.getLogger(__name__)


# 进程内共享的 AI 上游 HTTP client。httpx 会按 origin 分池，因此同一个 client
# 可以安全承载用户动态配置的不同 provider URL，同时复用 DNS/TCP/TLS/keep-alive。
# 每个请求仍显式传自己的 timeout，避免文本、图片、语音和 embedding 相互污染。
_AI_HTTP_MAX_CONNECTIONS = 32
_AI_HTTP_MAX_KEEPALIVE_CONNECTIONS = 16
_AI_HTTP_KEEPALIVE_EXPIRY_S = 30.0
_ai_http_client: httpx.AsyncClient | None = None
_ai_http_client_loop: asyncio.AbstractEventLoop | None = None
_ai_http_verify_ssl: bool | None = None


async def get_ai_http_client() -> httpx.AsyncClient:
    """返回当前 event loop 的共享 AI 上游 client（懒初始化）。

    FastAPI 启动时会预热一次；懒初始化仍保留给不触发生命周期的单元测试。
    测试可能为每个 case 新建 event loop，因此 loop 或 SSL 配置变化时重建，
    生产环境则始终复用同一个 keep-alive 连接池。
    """
    global _ai_http_client, _ai_http_client_loop, _ai_http_verify_ssl

    loop = asyncio.get_running_loop()
    verify_ssl = get_settings().ai_http_verify_ssl
    client = _ai_http_client
    if client is not None and (
        _ai_http_client_loop is not loop
        or _ai_http_verify_ssl != verify_ssl
        or getattr(client, "is_closed", False)
    ):
        await close_ai_http_client()
        # close 期间若另一个 task 已初始化新 client，直接复用，避免并发重建泄漏。
        client = _ai_http_client

    if client is None:
        client = httpx.AsyncClient(
            timeout=None,
            verify=verify_ssl,
            limits=httpx.Limits(
                max_connections=_AI_HTTP_MAX_CONNECTIONS,
                max_keepalive_connections=_AI_HTTP_MAX_KEEPALIVE_CONNECTIONS,
                keepalive_expiry=_AI_HTTP_KEEPALIVE_EXPIRY_S,
            ),
        )
        _ai_http_client = client
        _ai_http_client_loop = loop
        _ai_http_verify_ssl = verify_ssl
        logger.info(
            "ai.http_pool initialized max_connections=%d max_keepalive=%d verify_ssl=%s",
            _AI_HTTP_MAX_CONNECTIONS,
            _AI_HTTP_MAX_KEEPALIVE_CONNECTIONS,
            verify_ssl,
        )
    return client


async def close_ai_http_client() -> None:
    """关闭共享连接池；供 FastAPI shutdown 与测试清理调用。"""
    global _ai_http_client, _ai_http_client_loop, _ai_http_verify_ssl

    client = _ai_http_client
    _ai_http_client = None
    _ai_http_client_loop = None
    _ai_http_verify_ssl = None
    if client is None or getattr(client, "is_closed", False):
        return

    close = getattr(client, "aclose", None)
    if close is None:  # 兼容只实现 post 的轻量测试 double
        return
    try:
        await close()
    except RuntimeError:
        # 测试可能已关闭创建该 client 的旧 event loop；生产 shutdown 同 loop
        # 正常关闭，不会走到这里。
        logger.debug("ai.http_pool close skipped because owner loop is closed", exc_info=True)


# Anthropic 协议适配(/v1/messages) ────────────────────────────────────────
#
# provider 的 `protocol` 字段 = "anthropic" 时,所有 chat / vision 调用改走
# Anthropic Messages API:消息 shape(system 独立字段 / content blocks)、
# vision(base64 source)、响应(content[].text)都不同;鉴权头也不同
# (x-api-key + anthropic-version,不是 Bearer)。STT Anthropic 没有 ——
# protocol=anthropic 的 provider 一律不支持语音转写。


def _normalize_anthropic_base_url(base_url: str) -> str:
    """baseUrl 允许带或不带 /v1:统一剥掉尾部 /v1 后自己拼 /v1/messages,
    用户填 https://api.anthropic.com 和 https://api.anthropic.com/v1 等价。"""
    return base_url.rstrip("/").removesuffix("/v1")


def _anthropic_system_and_messages(
    messages: list[dict[str, object]],
) -> tuple[str, list[dict[str, object]]]:
    """OpenAI messages → Anthropic (system, messages)。system 独立传;
    字符串 content 包成 [{"type":"text",...}]。"""
    system_parts: list[str] = []
    out: list[dict[str, object]] = []
    for m in messages:
        role = m.get("role")
        content = m.get("content")
        if role == "system":
            if isinstance(content, str):
                system_parts.append(content)
            continue
        if isinstance(content, str):
            block_content: list[dict[str, object]] = [
                {"type": "text", "text": content}
            ]
        elif isinstance(content, list):
            block_content = []
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text":
                    block_content.append({"type": "text", "text": part.get("text") or ""})
                elif part.get("type") == "image_url":
                    # OpenAI data URL → Anthropic base64 source
                    url = (part.get("image_url") or {}).get("url") or ""
                    if url.startswith("data:"):
                        header, _, b64 = url.partition(",")
                        mime = header[len("data:") :].split(";")[0] or "image/png"
                        block_content.append(
                            {
                                "type": "image",
                                "source": {"type": "base64", "media_type": mime, "data": b64},
                            }
                        )
        else:
            block_content = [{"type": "text", "text": ""}]
        # Anthropic messages 首条必须是 user;assistant 开头的对话丢掉开头
        if not out and role == "assistant":
            continue
        out.append({"role": "user" if role != "assistant" else "assistant", "content": block_content})
    if not out:
        out = [{"role": "user", "content": [{"type": "text", "text": ""}]}]
    return "\n\n".join(system_parts), out


def _anthropic_usage_to_openai(usage: dict | None) -> dict | None:
    """Anthropic usage{input_tokens,output_tokens} → OpenAI 命名,日志落库用。"""
    if not isinstance(usage, dict):
        return None
    return {
        "prompt_tokens": usage.get("input_tokens"),
        "completion_tokens": usage.get("output_tokens"),
        "total_tokens": (usage.get("input_tokens") or 0) + (usage.get("output_tokens") or 0),
    }


def _anthropic_text_from_response(data: dict) -> str:
    return "".join(
        b.get("text") or ""
        for b in data.get("content") or []
        if isinstance(b, dict) and b.get("type") == "text"
    )


async def _post_anthropic_adaptive(
    client: httpx.AsyncClient,
    url: str,
    headers: dict,
    payload: dict,
    *,
    timeout: float | httpx.Timeout | None = None,
) -> httpx.Response:
    """POST /v1/messages;max_tokens 被拒(部分模型有上限)时逐步砍半重发。"""
    payload = dict(payload)
    if timeout is None:
        resp = await client.post(url, headers=headers, json=payload)
    else:
        resp = await client.post(url, headers=headers, json=payload, timeout=timeout)
    for _ in range(3):
        if resp.status_code < 400:
            return resp
        low = resp.text.lower()
        if "max_tokens" in payload and "max_tokens" in low:
            payload = {**payload, "max_tokens": max(256, int(payload["max_tokens"]) // 2)}
            if timeout is None:
                resp = await client.post(url, headers=headers, json=payload)
            else:
                resp = await client.post(url, headers=headers, json=payload, timeout=timeout)
            continue
        break
    return resp


# Embedding(server-side,跟 build 时同步配置) ──────────────────────────────


class EmbeddingNotConfiguredError(RuntimeError):
    """Server 没配 EMBEDDING_API_KEY — A1 endpoint 直接 503,管理员必须配。"""


async def embed_query(query: str) -> list[float]:
    """server-side 把用户问题 embed 成向量。用 server 持有的 key,不消耗用户配额。

    配置走 src/config.py Settings(读 .env 文件)。部署者在 .env 里设
    `EMBEDDING_API_KEY=...`,无需启动时传 env var。
    """
    settings = get_settings()
    if not settings.embedding_api_key:
        raise EmbeddingNotConfiguredError(
            "EMBEDDING_API_KEY 未配置;请在 .env 文件或环境变量设置 SiliconFlow / OpenAI key"
        )
    client = await get_ai_http_client()
    resp = await client.post(
        f"{settings.embedding_base_url.rstrip('/')}/embeddings",
        headers={"Authorization": f"Bearer {settings.embedding_api_key}"},
        json={"model": settings.embedding_model, "input": query},
        timeout=settings.embedding_timeout,
    )
    resp.raise_for_status()
    data = resp.json()
    embedding = data["data"][0]["embedding"]
    if not isinstance(embedding, list):
        raise RuntimeError("embedding API 返回 shape 异常")
    return [float(x) for x in embedding]


# Chat provider 解析 ──────────────────────────────────────────────────────────


@dataclass(frozen=True)
class ChatProviderConfig:
    """从 user.ai_config_json 解析出的 chat / vision / audio 配置。"""

    provider_id: str
    base_url: str
    api_key: str
    model: str           # textModel / visionModel / audioModel(按 kind)
    name: str | None = None
    is_built_in: bool = False  # 内置智谱(音频走 input_audio 消息,非 /audio/transcriptions)
    protocol: str = "openai"   # "openai"(OpenAI-compatible) | "anthropic"(/v1/messages)
    # 该服务商对同一用户的 LLM 并发调用上限:文字(chat)与视觉(vision/
    # vision-batch)统一生效(relay 的 (user, provider) 并发闸)。字段名保留
    # visionConcurrency 是存量 ai_config_json 兼容,语义已不限于视觉。
    vision_concurrency: int = 3


class ChatProviderError(RuntimeError):
    """通用 provider 调用失败。"""


def supports_disabled_thinking(model: str) -> bool:
    """Return whether the model supports disabling thinking via
    ``thinking={"type": "disabled"}``.

    GLM-4.5 (non-V), GLM-4.6, supported GLM-5.x models and MiniMax M3 can
    receive the field. Do not add the provider-specific field to older GLM
    models or unrelated OpenAI-compatible models: several gateways reject
    unknown request fields.
    """
    normalized = (model or "").strip().lower().replace("_", "-")
    # GLM-4.7 / GLM-4.5V / GLM-5.3 are forced-thinking or do not support
    # disabled; do not send the field for them.
    if any(marker in normalized for marker in ("glm-4.7", "glm-4.5v", "glm-5.3")):
        return False
    supports_glm5 = any(
        marker in normalized
        for marker in ("glm-5.2", "glm-5.1", "glm-5-turbo", "glm-5v-turbo")
    ) or normalized in {"glm-5"} or normalized.endswith("/glm-5")
    # MiniMax M3 uses the same `thinking={"type": "disabled"}` field
    # (official docs: omitted → thinking on; disabled → answer directly).
    # M2.x "thinking cannot be disabled" per docs — excluded.
    supports_minimax_m3 = "minimax" in normalized and (
        "/m3" in normalized
        or normalized.endswith("m3")
        or "minimax-m3" in normalized
    )
    # DeepSeek: thinking is ON by default (effort=high) and
    # `thinking={"type": "disabled"}` is the documented way to turn it off
    # (V4-era models deepseek-flash / deepseek-v4-pro, incl. legacy aliases
    # like deepseek-chat). Legacy deepseek-reasoner (R1) is forced-thinking
    # and cannot be disabled — excluded.
    supports_deepseek = "deepseek" in normalized and "reasoner" not in normalized
    return (
        "glm-4.5" in normalized
        or "glm-4.6" in normalized
        or supports_glm5
        or supports_minimax_m3
        or supports_deepseek
    )


def with_disabled_thinking(
    payload: dict[str, object],
    *,
    model: str,
    disable_thinking: bool,
) -> dict[str, object]:
    """Copy *payload* and disable GLM reasoning when requested."""
    result = dict(payload)
    if disable_thinking and supports_disabled_thinking(model):
        result["thinking"] = {"type": "disabled"}
    return result


@dataclass(frozen=True)
class ChatJSONResult:
    """`call_chat_json` 的返回 — parsed JSON + 上游 usage(可能没有,None)。

    usage 记录到 ai_analysis_logs(prompt/completion/total tokens),部分
    gateway 不返 usage → None。
    """

    parsed: dict | list
    usage: dict | None = None


class NoChatProviderError(ChatProviderError):
    """用户没配 / binding 找不到 — 前端显示 fallback 提示。"""


def resolve_chat_provider(user: User, profile: UserProfile | None) -> ChatProviderConfig:
    """从 user profile 拿 text provider 配置;没配 / 不完整时 raise NoChatProviderError。"""
    return _resolve_provider_by_kind(profile, kind="text")


class NoVisionProviderError(ChatProviderError):
    """用户没绑 vision 模型 — B2 截图记账专用 fallback。"""


def resolve_vision_provider(user: User, profile: UserProfile | None) -> ChatProviderConfig:
    """从 user profile 拿 vision provider 配置(用 visionProviderId + visionModel)。

    没配 → NoVisionProviderError(让前端跳官网 / 引导去 mobile 配)。
    """
    return _resolve_provider_by_kind(
        profile,
        kind="vision",
        not_found_exc=NoVisionProviderError,
    )


class NoAudioProviderError(ChatProviderError):
    """用户没绑语音转写模型 — App 语音记账中转专用。"""


def resolve_audio_provider(user: User, profile: UserProfile | None) -> ChatProviderConfig:
    """从 user profile 拿 audio(语音转写)provider 配置。

    binding 字段沿用 mobile 的命名:`speechProviderId`(不是 audioProviderId),
    模型字段是 provider 的 `audioModel`。
    """
    return _resolve_provider_by_kind(
        profile,
        kind="audio",
        not_found_exc=NoAudioProviderError,
    )


# kind → (binding 字段名, provider 模型字段名)。binding 命名与 mobile
# AICapabilityBinding.toJson() 对齐(语音叫 speechProviderId)。
_KIND_FIELDS: dict[str, tuple[str, str]] = {
    "text": ("textProviderId", "textModel"),
    "vision": ("visionProviderId", "visionModel"),
    "audio": ("speechProviderId", "audioModel"),
}


def _resolve_provider_by_kind(
    profile: UserProfile | None,
    *,
    kind: str,  # "text" | "vision" | "audio"
    not_found_exc: type[ChatProviderError] = NoChatProviderError,
) -> ChatProviderConfig:
    """B2/B3 复用的 provider 解析 — 跟 resolve_chat_provider 同模式,只是
    binding 字段名 + provider 字段名按 kind 切。
    """
    if profile is None or not profile.ai_config_json:
        raise not_found_exc(f"user has no ai_config (kind={kind})")

    try:
        cfg = json.loads(profile.ai_config_json)
    except (ValueError, TypeError) as exc:
        raise not_found_exc(f"ai_config_json invalid JSON: {exc}") from exc

    if not isinstance(cfg, dict):
        raise not_found_exc("ai_config not a dict")

    binding_key, model_key = _KIND_FIELDS[kind]

    binding = cfg.get("binding") if isinstance(cfg.get("binding"), dict) else {}
    provider_id = binding.get(binding_key)
    if not provider_id:
        raise not_found_exc(f"{binding_key} not bound")

    providers = cfg.get("providers") if isinstance(cfg.get("providers"), list) else []
    matched: dict[str, Any] | None = None
    for p in providers:
        if isinstance(p, dict) and p.get("id") == provider_id:
            matched = p
            break
    if matched is None:
        raise not_found_exc(f"provider {provider_id!r} not found")

    api_key = matched.get("apiKey") or ""
    base_url = matched.get("baseUrl") or ""
    model = matched.get(model_key) or ""

    if not api_key:
        raise not_found_exc(f"provider {provider_id!r} apiKey empty")
    if not base_url:
        raise not_found_exc(f"provider {provider_id!r} baseUrl empty")
    if not model:
        raise not_found_exc(f"provider {provider_id!r} {model_key} empty")

    return ChatProviderConfig(
        provider_id=provider_id,
        base_url=base_url.rstrip("/"),
        api_key=api_key,
        model=model,
        name=matched.get("name"),
        is_built_in=bool(matched.get("isBuiltIn")),
        # 存量配置没有 protocol 字段 → openai(行为与升级前一致)
        protocol=matched.get("protocol") or "openai",
        # 存量 / 未配置的 provider 无 visionConcurrency → 默认 3
        vision_concurrency=int(matched.get("visionConcurrency") or 3),
    )


def get_user_custom_prompt(profile: UserProfile | None, key: str) -> str | None:
    """从 user.ai_config_json 读自定义 prompt template。

    key 是 ai_config_json 里的字段名:
    - `parseTxImagePrompt` — B2 截图
    - `parseTxTextPrompt` — B3 文本
    没有就返 None,server 用 default。**第一期 web UI 不暴露编辑入口**,留给 mobile
    端同步过来的 hook(避免两端配冲突)。
    """
    if profile is None or not profile.ai_config_json:
        return None
    try:
        cfg = json.loads(profile.ai_config_json)
    except (ValueError, TypeError):
        return None
    if not isinstance(cfg, dict):
        return None
    val = cfg.get(key)
    if isinstance(val, str) and val.strip():
        return val
    return None


# JSON-mode chat call(非 streaming,B2/B3 用) ─────────────────────────────


_JSON_BLOCK_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)
_FIRST_OBJECT_RE = re.compile(r"\{.*\}", re.DOTALL)


def _try_parse_json(raw: str) -> dict | list | None:
    """从 LLM 原始输出抽 JSON 值。

    抽取本身允许 dict / list / 用 ```json``` 代码块包裹 — 这是「LLM 输出文本
    格式」的鲁棒,跟 schema 验证是两件事。schema 严格性由 caller 的
    `_normalize_drafts` 强制(必须 `{"tx_drafts": [...]}`),不在 parser 兼容。
    """
    if not raw:
        return None
    # 1. 直接 try
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, (dict, list)):
            return parsed
    except (ValueError, TypeError):
        pass
    # 2. ```json ... ``` 代码块
    m = _JSON_BLOCK_RE.search(raw)
    if m:
        try:
            parsed = json.loads(m.group(1).strip())
            if isinstance(parsed, (dict, list)):
                return parsed
        except (ValueError, TypeError):
            pass
    # 3. 第一个 { ... } 块兜底(主要给「LLM 输出含前后缀解释文字」)
    m = _FIRST_OBJECT_RE.search(raw)
    if m:
        try:
            return json.loads(m.group(0))
        except (ValueError, TypeError):
            pass
    return None


class JsonParseFailedError(ChatProviderError):
    """LLM 输出无法解析为 JSON,重试后仍失败。带上 raw_content 给排查。"""

    def __init__(self, message: str, *, raw_content: str = ""):
        super().__init__(message)
        self.raw_content = raw_content


# 自适应参数剥离 ────────────────────────────────────────────────────────────
#
# 不同模型对 OpenAI-compatible 参数有不同约束:推理模型(kimi-k2.5 / o1 / o3 /
# DeepSeek-R1)把 temperature 锁死成 1,拒绝其他值;部分模型不支持 response_format。
# 与其按模型/参数名写死兼容分支,不如「听上游报错动态适配」:上游因某个参数报错时
# 它会点名是哪个参数,我们照它说的把那个参数摘掉重发。

# 结构上必须保留的键;其余键(temperature / top_p / response_format / max_tokens …)
# 都是「可丢的可选参数」:被上游拒绝时摘掉重发。
_REQUIRED_KEYS = frozenset({"model", "messages", "stream"})
# 防止烂网关让我们无限摘参数空转
_MAX_PARAM_STRIPS = 3


def _rejected_param(payload: dict, status_code: int, body: str) -> str | None:
    """上游因「参数不合法」报错时,返回它点名的那个参数(且必须是我们发出去的可丢键)。

    优先结构化 error.param(OpenAI / o1 / o3 错误体里直接给 ``"param": "temperature"``);
    没有该字段(Moonshot 那种 ``invalid temperature: only 1 is allowed for this model``)
    就扫错误文案里点了我们发出去的哪个键。

    返回 None = 不是参数问题 / 点名的是必须键 / 没的可摘了 → 交给上层照常报错。
    """
    if status_code < 400:
        return None
    # 1) 结构化:{"error": {"param": "temperature", ...}}
    try:
        err = json.loads(body).get("error")
        if isinstance(err, dict):
            param = err.get("param")
            if isinstance(param, str) and param in payload and param not in _REQUIRED_KEYS:
                return param
    except (ValueError, TypeError, AttributeError):
        pass
    # 2) 文案兜底:错误信息点了我们发出去的哪个可丢键
    low = body.lower()
    for key in payload:
        if key not in _REQUIRED_KEYS and key.lower() in low:
            return key
    return None


async def _post_chat_adaptive(
    client: httpx.AsyncClient,
    url: str,
    headers: dict,
    payload: dict,
    *,
    timeout: float | httpx.Timeout | None = None,
) -> httpx.Response:
    """POST /chat/completions;若上游因某个可选参数报 4xx,摘掉它重发,最多 _MAX_PARAM_STRIPS 次。

    普通模型:参数都合法 → 一次成功,行为完全不变。
    推理模型(k2.5 / o1 / o3 / R1):温度等被锁 → 摘掉 → 用模型默认值,通过。

    只在「拿到响应且是参数类错误」时重试;超时 / 网络异常照常向上抛(由调用方处理)。
    """
    payload = dict(payload)  # 不改调用方的 dict
    if timeout is None:
        resp = await client.post(url, headers=headers, json=payload)
    else:
        resp = await client.post(url, headers=headers, json=payload, timeout=timeout)
    for _ in range(_MAX_PARAM_STRIPS):
        if resp.status_code < 400:
            return resp
        param = _rejected_param(payload, resp.status_code, resp.text)
        if param is None:
            return resp  # 不是参数问题 / 没的可摘 → 原样返回,交给上层报错
        logger.info(
            "ai.param_stripped param=%s model=%s status=%d",
            param, payload.get("model"), resp.status_code,
        )
        # 重建(而非 in-place pop):每次 POST 用独立 dict,不改已发出去的引用
        payload = {k: v for k, v in payload.items() if k != param}
        if timeout is None:
            resp = await client.post(url, headers=headers, json=payload)
        else:
            resp = await client.post(url, headers=headers, json=payload, timeout=timeout)
    return resp  # 摘到上限仍失败,返回最后一次让上层报错


async def call_chat_json(
    *,
    config: ChatProviderConfig,
    messages: list[dict[str, object]],
    timeout: float = 30.0,
    max_retries: int = 1,
    disable_thinking: bool = False,
) -> ChatJSONResult:
    """调 provider chat API(非 stream),返 ChatJSONResult。

    protocol=openai 走 /chat/completions;protocol=anthropic 走 /v1/messages。

    重试策略(openai 分支):
    - attempt 0:带 `response_format={"type": "json_object"}`(部分 provider 支持,提高准确率)
    - attempt 1+:去掉 `response_format`(兼容不支持该参数的 provider,有些网关传了会卡死)
    - 都依赖 `_try_parse_json` 鲁棒抽 JSON(允许 markdown code block 包裹 / 前后缀文字)
    """
    import time

    if config.protocol == "anthropic":
        return await _call_chat_json_anthropic(
            config=config, messages=messages, timeout=timeout,
            max_retries=max_retries,
        )

    last_exc: Exception | None = None
    client = await get_ai_http_client()
    url = f"{config.base_url}/chat/completions"
    headers = {
        "Authorization": f"Bearer {config.api_key}",
        "Content-Type": "application/json",
    }

    for attempt in range(max_retries + 1):
        # attempt 0 带 response_format;重试(解析失败 / 超时)降 temperature 并去掉
        # response_format。参数被模型拒绝(如推理模型锁 temperature、不支持 response_format)
        # 由 _post_chat_adaptive 在单次调用内自适应摘除,不依赖 attempt 切换。
        temperature = 0.2 if attempt == 0 else 0.05
        payload = with_disabled_thinking(
            {
                "model": config.model,
                "messages": messages,
                "temperature": temperature,
            },
            model=config.model,
            disable_thinking=disable_thinking,
        )
        if attempt == 0:
            payload["response_format"] = {"type": "json_object"}

        t0 = time.monotonic()
        logger.info(
            "ai.call_chat_json provider=%s model=%s attempt=%d msgs=%d response_format=%s disable_thinking=%s",
            config.provider_id, config.model, attempt + 1, len(messages),
            attempt == 0, disable_thinking,
        )
        try:
            resp = await _post_chat_adaptive(
                client, url, headers, payload, timeout=timeout,
            )
            elapsed = time.monotonic() - t0
            logger.info(
                "ai.call_chat_json done attempt=%d status=%d elapsed=%.2fs body_len=%d",
                attempt + 1, resp.status_code, elapsed, len(resp.text),
            )
            if resp.status_code >= 400:
                # 参数类 4xx 已由 _post_chat_adaptive 摘参数重试过;到这说明不是参数问题
                raise ChatProviderError(
                    f"provider {config.provider_id} returned {resp.status_code}: {resp.text[:200]}"
                )
            data = resp.json()
            content = (
                data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            )
            parsed = _try_parse_json(content or "")
            if parsed is not None:
                usage = data.get("usage")
                return ChatJSONResult(
                    parsed=parsed,
                    usage=usage if isinstance(usage, dict) else None,
                )
            last_exc = JsonParseFailedError(
                f"LLM did not return parseable JSON (attempt {attempt + 1}); "
                f"raw[:120]={content[:120]!r}",
                raw_content=content or "",
            )
            logger.warning(
                "ai.call_chat_json json parse failed attempt=%d raw=%s",
                attempt + 1, (content or "")[:300],
            )
        except httpx.TimeoutException as exc:
            elapsed = time.monotonic() - t0
            logger.warning(
                "ai.call_chat_json timeout attempt=%d elapsed=%.2fs err=%s",
                attempt + 1, elapsed, exc,
            )
            last_exc = ChatProviderError(
                f"provider {config.provider_id} timed out after {elapsed:.1f}s"
            )
            # timeout 也允许 retry(下一轮去掉 response_format,某些网关吞 json_object 卡死)
            if attempt < max_retries:
                continue
            raise last_exc from exc
        except httpx.HTTPError as exc:
            elapsed = time.monotonic() - t0
            logger.warning(
                "ai.call_chat_json http error attempt=%d elapsed=%.2fs err=%s",
                attempt + 1, elapsed, exc,
            )
            raise ChatProviderError(f"network error: {exc}") from exc
    # 所有重试都解析失败
    raise last_exc or JsonParseFailedError("unknown JSON parse failure")


async def _call_chat_json_anthropic(
    *,
    config: ChatProviderConfig,
    messages: list[dict[str, object]],
    timeout: float,
    max_retries: int,
) -> ChatJSONResult:
    """/v1/messages JSON 提取 — call_chat_json 的 Anthropic 分支(温度自适应
    降档 + max_tokens 砍半重试,复用 _try_parse_json)。"""
    import time

    last_exc: Exception | None = None
    client = await get_ai_http_client()
    system, a_messages = _anthropic_system_and_messages(messages)
    headers = {
        "x-api-key": config.api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }
    url = f"{_normalize_anthropic_base_url(config.base_url)}/v1/messages"

    for attempt in range(max_retries + 1):
        temperature = 0.2 if attempt == 0 else 0.05
        payload: dict[str, object] = {
            "model": config.model,
            "messages": a_messages,
            "max_tokens": 4096,
            "temperature": temperature,
        }
        if system:
            payload["system"] = system
        t0 = time.monotonic()
        logger.info(
            "ai.call_chat_json_anthropic provider=%s model=%s attempt=%d msgs=%d",
            config.provider_id, config.model, attempt + 1, len(a_messages),
        )
        try:
            resp = await _post_anthropic_adaptive(
                client, url, headers, payload, timeout=timeout,
            )
            if resp.status_code >= 400:
                raise ChatProviderError(
                    f"provider {config.provider_id} returned {resp.status_code}: {resp.text[:200]}"
                )
            data = resp.json()
            content = _anthropic_text_from_response(data)
            parsed = _try_parse_json(content or "")
            if parsed is not None:
                return ChatJSONResult(parsed=parsed, usage=_anthropic_usage_to_openai(data.get("usage")))
            last_exc = JsonParseFailedError(
                f"LLM did not return parseable JSON (attempt {attempt + 1}); "
                f"raw[:120]={content[:120]!r}",
                raw_content=content or "",
            )
        except httpx.TimeoutException as exc:
            last_exc = ChatProviderError(
                f"provider {config.provider_id} timed out after {time.monotonic() - t0:.1f}s"
            )
            if attempt < max_retries:
                continue
            raise last_exc from exc
        except httpx.HTTPError as exc:
            raise ChatProviderError(f"network error: {exc}") from exc
    raise last_exc or JsonParseFailedError("unknown JSON parse failure")


# Plain-text chat call(非 streaming、非 JSON 模式,/ai/relay/* 中转用) ────


@dataclass(frozen=True)
class ChatTextResult:
    """`call_chat_text` 的返回 — 原样 content + 上游 usage(可能没有)。"""

    content: str
    usage: dict | None = None


async def call_chat_text(
    *,
    config: ChatProviderConfig,
    messages: list[dict[str, object]],
    temperature: float = 0.3,
    disable_thinking: bool = False,
    timeout: float = 120.0,
) -> ChatTextResult:
    """调 provider(OpenAI-compatible /chat/completions 或 Anthropic /v1/messages),
    返回原始 content。

    与 `call_chat_json` 的区别:不附加 response_format、不做 JSON 抽取、不重试
    —— 提示词与输出解析都是 App 端业务(/ai/relay/* 只做密钥代管 + 转发),
    content 原样回给客户端,由客户端的 JsonResponseParser 鲁棒解析。
    参数自适应摘除(_post_chat_adaptive)与 GLM thinking 关闭逻辑保持一致。
    Anthropic protocol 时消息 shape / 鉴权头 / 响应解析走 _anthropic_* 系列。
    """
    import time

    if config.protocol == "anthropic":
        return await _call_chat_text_anthropic(
            config=config,
            messages=messages,
            temperature=temperature,
            timeout=timeout,
        )

    url = f"{config.base_url}/chat/completions"
    headers = {
        "Authorization": f"Bearer {config.api_key}",
        "Content-Type": "application/json",
    }
    payload = with_disabled_thinking(
        {
            "model": config.model,
            "messages": messages,
            "temperature": temperature,
        },
        model=config.model,
        disable_thinking=disable_thinking,
    )

    t0 = time.monotonic()
    logger.info(
        "ai.call_chat_text provider=%s model=%s msgs=%d disable_thinking=%s",
        config.provider_id, config.model, len(messages), disable_thinking,
    )
    try:
        client = await get_ai_http_client()
        resp = await _post_chat_adaptive(
            client, url, headers, payload, timeout=timeout,
        )
    except httpx.TimeoutException as exc:
        elapsed = time.monotonic() - t0
        logger.warning("ai.call_chat_text timeout provider=%s elapsed=%.2fs", config.provider_id, elapsed)
        raise ChatProviderError(
            f"provider {config.provider_id} timed out after {elapsed:.1f}s"
        ) from exc
    except httpx.HTTPError as exc:
        logger.warning("ai.call_chat_text http error provider=%s err=%s", config.provider_id, exc)
        raise ChatProviderError(f"network error: {exc}") from exc

    elapsed = time.monotonic() - t0
    logger.info(
        "ai.call_chat_text done status=%d elapsed=%.2fs body_len=%d",
        resp.status_code, elapsed, len(resp.text),
    )
    if resp.status_code >= 400:
        raise ChatProviderError(
            f"provider {config.provider_id} returned {resp.status_code}: {resp.text[:200]}"
        )
    data = resp.json()
    content = (
        data.get("choices", [{}])[0]
        .get("message", {})
        .get("content", "")
    )
    usage = data.get("usage")
    return ChatTextResult(
        content=content or "",
        usage=usage if isinstance(usage, dict) else None,
    )


async def _call_chat_text_anthropic(
    *,
    config: ChatProviderConfig,
    messages: list[dict[str, object]],
    temperature: float,
    timeout: float,
) -> ChatTextResult:
    """/v1/messages 非流式调用 — call_chat_text 的 Anthropic 分支。"""
    import time

    system, a_messages = _anthropic_system_and_messages(messages)
    payload: dict[str, object] = {
        "model": config.model,
        "messages": a_messages,
        "max_tokens": 4096,
        "temperature": temperature,
    }
    if system:
        payload["system"] = system
    headers = {
        "x-api-key": config.api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }
    url = f"{_normalize_anthropic_base_url(config.base_url)}/v1/messages"

    t0 = time.monotonic()
    logger.info(
        "ai.call_chat_text_anthropic provider=%s model=%s msgs=%d",
        config.provider_id, config.model, len(a_messages),
    )
    try:
        client = await get_ai_http_client()
        resp = await _post_anthropic_adaptive(
            client, url, headers, payload, timeout=timeout,
        )
    except httpx.TimeoutException as exc:
        elapsed = time.monotonic() - t0
        logger.warning("ai.call_chat_text_anthropic timeout provider=%s elapsed=%.2fs", config.provider_id, elapsed)
        raise ChatProviderError(
            f"provider {config.provider_id} timed out after {elapsed:.1f}s"
        ) from exc
    except httpx.HTTPError as exc:
        logger.warning("ai.call_chat_text_anthropic http error provider=%s err=%s", config.provider_id, exc)
        raise ChatProviderError(f"network error: {exc}") from exc

    if resp.status_code >= 400:
        raise ChatProviderError(
            f"provider {config.provider_id} returned {resp.status_code}: {resp.text[:200]}"
        )
    data = resp.json()
    return ChatTextResult(
        content=_anthropic_text_from_response(data),
        usage=_anthropic_usage_to_openai(data.get("usage")),
    )


# Audio transcription(/ai/relay/stt 用) ────────────────────────────────────

_STT_PROMPT = "请将语音内容转换为文字，只返回识别的文字内容，不要添加任何解释或标点修饰。"


def _audio_format_for(audio_mime: str | None, filename: str | None) -> str:
    """智谱 input_audio 的 format 字段:wav 或 mp3(与 mobile 端检测逻辑一致,
    m4a/aac 等按 mp3 传)。"""
    name = (filename or "").lower()
    if name.endswith(".wav") or audio_mime == "audio/wav":
        return "wav"
    return "mp3"


def _is_zhipu_audio(config: ChatProviderConfig) -> bool:
    """内置智谱(或直填 bigmodel 域名的自定义 provider)没有 /audio/transcriptions,
    语音转写走 chat/completions + input_audio 消息(与 mobile ZhipuGLMProvider 相同)。"""
    if config.is_built_in:
        return True
    return "bigmodel.cn" in config.base_url.lower()


async def transcribe_audio(
    *,
    config: ChatProviderConfig,
    audio_bytes: bytes,
    audio_mime: str | None = None,
    filename: str | None = None,
    timeout: float = 120.0,
) -> str:
    """语音转文字:按 provider 类型分派 OpenAI /audio/transcriptions 或
    智谱 input_audio。返回识别文本(可能为空串)。失败抛 ChatProviderError。
    Anthropic 协议没有 STT 接口,直接报错(能力绑定 UI 不该让用户绑到这一步)。"""
    if config.protocol == "anthropic":
        raise ChatProviderError(
            f"provider {config.provider_id} uses Anthropic protocol which has no speech-to-text API"
        )
    headers = {"Authorization": f"Bearer {config.api_key}"}
    try:
        client = await get_ai_http_client()
        if _is_zhipu_audio(config):
            logger.info(
                "ai.transcribe_audio path=input_audio provider=%s model=%s bytes=%d",
                config.provider_id, config.model, len(audio_bytes),
            )
            content = [
                {
                    "type": "input_audio",
                    "input_audio": {
                        "data": base64.b64encode(audio_bytes).decode(),
                        "format": _audio_format_for(audio_mime, filename),
                    },
                },
                {"type": "text", "text": _STT_PROMPT},
            ]
            payload = {
                "model": config.model,
                "messages": [{"role": "user", "content": content}],
                "temperature": 0.1,
            }
            resp = await _post_chat_adaptive(
                client,
                f"{config.base_url}/chat/completions",
                {**headers, "Content-Type": "application/json"},
                payload,
                timeout=timeout,
            )
            if resp.status_code >= 400:
                raise ChatProviderError(
                    f"provider {config.provider_id} returned {resp.status_code}: {resp.text[:200]}"
                )
            data = resp.json()
            text = (
                data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            )
            return (text or "").strip()

        logger.info(
            "ai.transcribe_audio path=transcriptions provider=%s model=%s bytes=%d",
            config.provider_id, config.model, len(audio_bytes),
        )
        resp = await client.post(
            f"{config.base_url}/audio/transcriptions",
            headers=headers,
            files={
                "file": (
                    filename or "audio",
                    audio_bytes,
                    audio_mime or "application/octet-stream",
                ),
            },
            data={"model": config.model},
            timeout=timeout,
        )
        if resp.status_code >= 400:
            raise ChatProviderError(
                f"provider {config.provider_id} returned {resp.status_code}: {resp.text[:200]}"
            )
        body = resp.json()
        return (body.get("text") or "").strip()
    except httpx.TimeoutException as exc:
        logger.warning("ai.transcribe_audio timeout provider=%s err=%s", config.provider_id, exc)
        raise ChatProviderError(
            f"provider {config.provider_id} timed out"
        ) from exc
    except httpx.HTTPError as exc:
        logger.warning("ai.transcribe_audio http error provider=%s err=%s", config.provider_id, exc)
        raise ChatProviderError(f"network error: {exc}") from exc


# Streaming chat ────────────────────────────────────────────────────────────


async def stream_chat_completion(
    *,
    config: ChatProviderConfig,
    messages: list[dict[str, str]],
    timeout: float = 30.0,
) -> AsyncIterator[str]:
    """调 provider stream=true,yield 增量 content。

    protocol=openai:OpenAI-compatible /chat/completions SSE(GLM / OpenAI /
    DeepSeek / 智谱 / SiliconFlow 都走同一套),每行 `data: {...}` 看
    choices[0].delta.content,`data: [DONE]` 结束。
    protocol=anthropic:/v1/messages SSE,看 content_block_delta 的
    delta.text,message_stop 结束。

    出错抛 ChatProviderError(不细分:对前端来说就是「AI 服务出错,请重试 / 检查 key」)。
    """
    if config.protocol == "anthropic":
        async for chunk in _stream_chat_anthropic(
            config=config, messages=messages, timeout=timeout,
        ):
            yield chunk
        return

    payload = {
        "model": config.model,
        "messages": messages,
        "stream": True,
        "temperature": 0.3,  # 低 temperature → 答案更稳,文档 QA 不需要创造性
    }
    headers = {
        "Authorization": f"Bearer {config.api_key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    url = f"{config.base_url}/chat/completions"

    try:
        client = await get_ai_http_client()
        # 参数被模型拒绝(如推理模型锁 temperature)→ 摘掉重开一次流。
        attempt_payload = dict(payload)
        for _ in range(_MAX_PARAM_STRIPS + 1):
            async with client.stream(
                "POST",
                url,
                headers=headers,
                json=attempt_payload,
                timeout=timeout,
            ) as resp:
                if resp.status_code >= 400:
                    body = (await resp.aread()).decode("utf-8", errors="replace")
                    param = _rejected_param(attempt_payload, resp.status_code, body)
                    if param is None:
                        raise ChatProviderError(
                            f"provider {config.provider_id} returned {resp.status_code}: {body[:200]}"
                        )
                    logger.info(
                        "ai.stream_param_stripped param=%s model=%s status=%d",
                        param, attempt_payload.get("model"), resp.status_code,
                    )
                    attempt_payload = {
                        k: v for k, v in attempt_payload.items() if k != param
                    }
                    continue
                async for line in resp.aiter_lines():
                    if not line:
                        continue
                    line = line.strip()
                    if not line.startswith("data:"):
                        continue
                    payload_str = line[len("data:"):].strip()
                    if payload_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload_str)
                    except (ValueError, TypeError):
                        logger.warning("ai.chat malformed SSE chunk: %s", payload_str[:80])
                        continue
                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    content = delta.get("content")
                    if content:
                        yield content
                return
        raise ChatProviderError(
            f"provider {config.provider_id} stream failed after stripping params"
        )
    except httpx.HTTPError as exc:
        raise ChatProviderError(f"network error: {exc}") from exc


async def _stream_chat_anthropic(
    *,
    config: ChatProviderConfig,
    messages: list[dict[str, str]],
    timeout: float,
) -> AsyncIterator[str]:
    """/v1/messages SSE 流式 — stream_chat_completion 的 Anthropic 分支。
    system 已在 messages 里由 caller 传,这里复用统一的 system 抽取。"""
    system, a_messages = _anthropic_system_and_messages(messages)  # type: ignore[arg-type]
    payload: dict[str, object] = {
        "model": config.model,
        "messages": a_messages,
        "max_tokens": 4096,
        "stream": True,
    }
    if system:
        payload["system"] = system
    headers = {
        "x-api-key": config.api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    url = f"{_normalize_anthropic_base_url(config.base_url)}/v1/messages"

    try:
        client = await get_ai_http_client()
        async with client.stream(
            "POST", url, headers=headers, json=payload, timeout=timeout,
        ) as resp:
            if resp.status_code >= 400:
                body = (await resp.aread()).decode("utf-8", errors="replace")
                raise ChatProviderError(
                    f"provider {config.provider_id} returned {resp.status_code}: {body[:200]}"
                )
            async for line in resp.aiter_lines():
                if not line or not line.strip().startswith("data:"):
                    continue
                payload_str = line.strip()[len("data:"):].strip()
                try:
                    chunk = json.loads(payload_str)
                except (ValueError, TypeError):
                    logger.warning(
                        "ai.chat anthropic malformed SSE chunk: %s", payload_str[:80],
                    )
                    continue
                etype = chunk.get("type")
                if etype == "content_block_delta":
                    delta = chunk.get("delta") or {}
                    text = delta.get("text")
                    if text:
                        yield text
                elif etype == "message_stop":
                    return
    except httpx.HTTPError as exc:
        raise ChatProviderError(f"network error: {exc}") from exc
