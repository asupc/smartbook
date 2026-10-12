"""POST /api/v1/ai/relay/* — App AI 记账的 LLM 中转。

背景:App 的 AI 记账(文本提取 / 截图 / 语音 / 自由聊天)原本在端上直连
LLM 服务商,API Key 存在手机上。改为统一经自建 server 中转后:

- Key 只存服务端(`UserProfile.ai_config_json`),任何接口不下发;
- App 只携带自己的 prompt(messages)调这里,server 解析该用户的
  provider 配置并代发请求;
- 每次中转调用由 server 直接落一行 `ai_analysis_logs`(图片原文落盘),
  客户端不再事后上报(`POST /ai/logs*` 已删除)。

与 /ai/parse-tx-* 的分工:那两个端点是 Web 端「贴文本/截图 → tx_drafts」
一站式(prompt 模板、schema 归一都在 server);relay 是**透明管道** ——
prompt 拼装与输出 JSON 解析都在 App 端,server 只负责鉴权、选 provider、
转发与日志。entry_type 语义:
- /relay/chat + entry_type=parse_tx_text → 记账文本提取(App 各自动/手动渠道)
- /relay/chat + entry_type=chat        → App 自由对话
- /relay/vision                        → parse_tx_image(带原图落盘)
- /relay/stt                           → stt(语音转写)

错误码:
- AI_NO_CHAT_PROVIDER / AI_NO_VISION_PROVIDER / AI_NO_AUDIO_PROVIDER (400)
- AI_IMAGE_TYPE_INVALID (400) / AI_IMAGE_TOO_LARGE (413)
- AI_AUDIO_TYPE_INVALID (400) / AI_AUDIO_TOO_LARGE (413)
- AI_RELAY_PAYLOAD_TOO_LARGE (413):messages 总字符超限
- AI_RELAY_RATE_LIMITED (429):单 user 60s 内超过上限
- AI_PROVIDER_ERROR (502):上游 LLM 调用失败(透传截断的错误信息)

并发:chat / 单图 vision / vision-batch 逐张共享同一 (user, provider)
并发闸,上限 = 服务商的 `visionConcurrency`(UI 已改名「并发数」,对文字与
视觉统一生效)。
"""
from __future__ import annotations

import asyncio
import base64
import logging
import time
from collections import defaultdict, deque
from pathlib import Path
from typing import Literal

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
    status,
)
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from ...config import get_settings
from ...database import get_db
from ...deps import get_current_user, require_any_scopes
from ...models import User, UserProfile
from ...security import SCOPE_APP_WRITE, SCOPE_WEB_WRITE
from ...services.ai import (
    ChatProviderConfig,
    ChatProviderError,
    NoAudioProviderError,
    NoChatProviderError,
    NoVisionProviderError,
    call_chat_text,
    resolve_audio_provider,
    resolve_chat_provider,
    resolve_vision_provider,
    transcribe_audio,
)
from ...services.ai.analysis_log import (
    token_count,
    write_ai_analysis_log_async,
    write_ai_analysis_log_with_image_async,
)
from ...services.ai.bill_identifier import (
    find_duplicate_identifier,
    harvest_identifiers,
    mark_duplicate_hit,
    register_identifiers,
)
from ...services.ai.media_sniff import is_plausible_audio, is_plausible_image
from ...services.ai.outbound_policy import AiHostNotAllowedError
from ...services.ai.provider_client import preflight_outbound_host_policy
from ._shared import host_not_allowed_http

logger = logging.getLogger(__name__)
router = APIRouter()

_RELAY_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_WRITE)

# 限流:单 user 60 秒内最多 60 次(自动化渠道批量触发时的防风暴上限,
# 正常手动 + 自动记账远达不到)。test-provider 的 30/min 是独立计数。
_RATE_WINDOWS: dict[str, deque[float]] = defaultdict(deque)
_RATE_LIMIT_WINDOW_S = 60.0
_RATE_LIMIT_MAX = 60

# 上游并发闸:同一 (user, provider) 的 LLM 调用(chat / 单图 vision /
# vision-batch 逐张)共享,上限 = 该服务商的 `visionConcurrency`(UI 已改名
# 「并发数」,对文字与视觉统一生效)。跨请求持有,天然覆盖「App 端多个事件
# 同时打 /relay/chat」的场景;不同 provider / 不同 user 互不阻塞。
# asyncio.Semaphore 非 reentrant,上限 1 时同请求内不得再嵌套 acquire。
_PROVIDER_SEMS: dict[tuple[str, str], asyncio.Semaphore] = {}


def _provider_sem(user_id: str, provider_id: str, limit: int) -> asyncio.Semaphore:
    """按 (user_id, provider_id) 取/建并发信号量;limit 只在建仓时生效。

    S11:长期运行下字典只增不减(每个 (user, provider) 一个 entry);取/建
    前顺手清掉闲置信号量(value>0 即无等待者 —— asyncio.Semaphore.release
    会立即唤醒等待者,value>0 说明没人排队),防无界膨胀。清理阈值远高于
    正常规模,单用户自部署几乎不会触发。"""
    if len(_PROVIDER_SEMS) >= _PROVIDER_SEMS_PRUNE_THRESHOLD:
        idle = [k for k, s in _PROVIDER_SEMS.items() if s.value > 0]
        for k in idle:
            if k != (user_id, provider_id):
                del _PROVIDER_SEMS[k]
    key = (user_id, provider_id)
    sem = _PROVIDER_SEMS.get(key)
    if sem is None:
        sem = asyncio.Semaphore(max(1, limit))
        _PROVIDER_SEMS[key] = sem
    return sem


_PROVIDER_SEMS_PRUNE_THRESHOLD = 256

_MAX_IMAGE_BYTES = 5 * 1024 * 1024  # 5MB,与 /ai/parse-tx-image 同口径
_ALLOWED_IMAGE_MIMES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
# multipart part 没带 content-type 时按文件后缀兜底(App 端 MultipartFile
# 可能默认 application/octet-stream,不能因此把真图拒了)
_SUFFIX_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
}

_MAX_AUDIO_BYTES = 10 * 1024 * 1024  # 10MB,语音录音足够
_MAX_MESSAGES = 40
_MAX_MESSAGES_TOTAL_CHARS = 100_000
# vision-batch 单请求图片张数上限。每张图 = 一次独立的上游 LLM 调用(各自
# 计费 / 计入上游配额),无上限时一个请求可放大成任意多次调用。
#
# 取值与 `_MAX_MESSAGES`(40)同量级:上限的作用是给「单次请求能触发的上游
# 调用数」封顶,真正的成本闸是**按张数计限流**(见 `_rate_limited(tokens=...)`)
# ——60 令牌/分钟 配合本上限,最坏 60 次上游调用/分钟。32 也覆盖了「AI 助手
# 一次选多张账单截图」的真实用法(App 端过滤/去重后一次通常 1~5 张)。
_MAX_BATCH_IMAGES = 32

# M2-5 上游 timeout。每档都比客户端 deadline 小 5s:服务端先放弃,客户端才能
# 拿到 502 AI_PROVIDER_ERROR(transient)并落 retry 状态;反过来客户端先超时,
# 上游请求还在跑,既白烧 token 又没有失败日志。
# 客户端 deadline 见 client/lib/ai/relay/ai_relay_client.dart(40/65/65/130s)。
_UPSTREAM_TIMEOUT_PARSE_TEXT = 35.0  # 自动记账文本提取
_UPSTREAM_TIMEOUT_CHAT = 120.0  # 自由聊天 / 问 AI,允许长推理
_UPSTREAM_TIMEOUT_VISION = 60.0  # 图片提取
_UPSTREAM_TIMEOUT_STT = 60.0  # 语音转写


def _check_rate_limit(user_id: str, tokens: int = 1) -> bool:
    """单 user 60 秒内最多 `_RATE_LIMIT_MAX` 个令牌。

    `tokens` 支持一次消耗多个 —— vision-batch 一次 N 张图就是 N 次上游调用
    (N 份账单 / 配额),必须按张数计令牌,否则「60/分钟」可被放大成 60×N。
    """
    now = time.monotonic()
    window = _RATE_WINDOWS[user_id]
    while window and now - window[0] > _RATE_LIMIT_WINDOW_S:
        window.popleft()
    if not window:
        # S11:窗口清空即删 key,防长期运行下 defaultdict 只增不减。
        _RATE_WINDOWS.pop(user_id, None)
        window = _RATE_WINDOWS[user_id]
    if len(window) + tokens > _RATE_LIMIT_MAX:
        return False
    window.extend([now] * tokens)
    return True


def _rate_limited(user_id: str, tokens: int = 1) -> None:
    if not _check_rate_limit(user_id, tokens):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={"error_code": "AI_RELAY_RATE_LIMITED"},
        )


def _host_not_allowed(exc: AiHostNotAllowedError) -> HTTPException:
    """SSRF 策略拒绝 → 400 配置类错误(不是 502 transient)。

    与 `/ai/parse-tx-*`、`/ai/ask` 共用 `_shared.host_not_allowed_http`
    —— 同一个策略错误在所有 AI 入口必须归一成同一个客户端可见形态
    (对抗缺陷 2)。
    """
    return host_not_allowed_http(exc)


def _preflight_host_policy(cfg: ChatProviderConfig) -> None:
    """出站前先判 host 策略 —— 违规立即 400,不做无谓的图片读盘 / 日志准备。

    `provider_client` 内部每个 egress 点也会各自校验(那是权威闸);这里提前
    判一次是为了让**配置类错误**在请求早期就以 400 返回,而不是等走到上游
    调用才被归一 —— 也保证 vision/stt 在读完整个 body 之前就拒掉。

    实现是 `provider_client.preflight_outbound_host_policy`(与
    `/ai/parse-tx-*`、`/ai/ask` 同一份 —— host 策略的覆盖面靠单一实现保证,
    对抗缺陷 2 的教训)。
    """
    preflight_outbound_host_policy(cfg, context="relay_preflight")


def _resolve_profile(db: Session, user_id: str) -> UserProfile | None:
    return db.scalar(select(UserProfile).where(UserProfile.user_id == user_id))


# ──────────────── 账单标识判重/收割的线程池 DB 包装(S6) ────────────────
# 这些函数内部含 SELECT / COMMIT(bill_identifier.register_identifiers
# commit 在函数内),直接在事件循环线程同步打 DB —— SQLite busy_timeout
# =5000 下一次写冲突就把整个进程挂起数秒。与 ai_analysis_logs 的写入路径
# 同款:asyncio.to_thread + 独立 session(与请求 session 解耦)。
#
# 线程 session 的 bind 取自**请求 session 的 engine**(而不是 SessionLocal):
# 生产两者同库;测试普遍用 dependency_overrides 换掉 get_db 的 engine,
# 直接用 SessionLocal 会打到默认库(no such table)。

def _find_duplicate_identifier_sync(bind, user_id: str, text: str | None) -> str | None:
    with Session(bind=bind) as db:
        user = db.get(User, user_id)
        if user is None:
            return None
        return find_duplicate_identifier(db, user, text)


def _mark_duplicate_hit_sync(bind, user_id: str, identifier: str) -> None:
    with Session(bind=bind) as db:
        user = db.get(User, user_id)
        if user is None:
            return
        mark_duplicate_hit(db, user, identifier)


def _register_identifiers_sync(bind, user_id: str, identifiers: list[str], source: str) -> None:
    with Session(bind=bind) as db:
        user = db.get(User, user_id)
        if user is None:
            return
        register_identifiers(db, user, identifiers, source=source)


async def _find_duplicate_identifier(bind, user_id: str, text: str | None) -> str | None:
    return await asyncio.to_thread(_find_duplicate_identifier_sync, bind, user_id, text)


async def _mark_duplicate_hit(bind, user_id: str, identifier: str) -> None:
    await asyncio.to_thread(_mark_duplicate_hit_sync, bind, user_id, identifier)


async def _register_identifiers(bind, user_id: str, identifiers: list[str], source: str) -> None:
    await asyncio.to_thread(_register_identifiers_sync, bind, user_id, identifiers, source)


def _resolve_image_mime(
    content_type: str | None, filename: str | None,
) -> str:
    """校验图片 mime;非法返回 ""。content-type 缺失时按文件后缀兜底。"""
    mime = (content_type or "").lower()
    if mime not in _ALLOWED_IMAGE_MIMES:
        mime = _SUFFIX_MIME.get(Path(filename or "").suffix.lower(), "")
    return mime


async def _check_image_upload(image: UploadFile) -> tuple[str, bytes]:
    """对单个 UploadFile 做 mime + 大小 + **魔数** 校验,返回 (mime, bytes)。

    非法 mime / 内容不像图片 → 400 AI_IMAGE_TYPE_INVALID;
    超过 5MB → 413 AI_IMAGE_TOO_LARGE。

    魔数是必需的:原先 content-type 不在白名单时**无条件回退到文件名后缀**,
    而文件名完全由客户端控制 —— `<html><script>` 改名 `.png`、zip(`PK\\x03\\x04`)
    改名 `.png` 都能通过校验并被 base64 转发上游。现在后缀只用来决定
    「按哪种类型去校验」,字节本身必须是可识别的图片容器(见 media_sniff)。
    声明了明确 image/* 也仍然校验魔数 —— 声明同样是客户端可控的。
    """
    mime = _resolve_image_mime(image.content_type, image.filename)
    if mime not in _ALLOWED_IMAGE_MIMES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_IMAGE_TYPE_INVALID",
                "message": f"unsupported image type: {image.content_type!r}; "
                f"allowed: {sorted(_ALLOWED_IMAGE_MIMES)}",
            },
        )
    image_bytes = await image.read()
    if len(image_bytes) > _MAX_IMAGE_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail={
                "error_code": "AI_IMAGE_TOO_LARGE",
                "message": f"image size {len(image_bytes)} exceeds 5MB",
            },
        )
    # 魔数校验:仅凭 CT / 后缀不足以证明是图片(0 字节仍放行 — 既有行为)。
    if not is_plausible_image(image_bytes, declared_mime=mime):
        logger.warning(
            "ai.relay.image_magic_rejected declared=%s filename=%r bytes=%d",
            image.content_type, image.filename, len(image_bytes),
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_IMAGE_TYPE_INVALID",
                "message": "payload is not a recognizable image (magic bytes mismatch)",
            },
        )
    return mime, image_bytes


def _build_vision_messages(prompt: str, mime: str, image_bytes: bytes) -> list[dict[str, object]]:
    """单图 → OpenAI 多模态 content 数组(文本 + 1 个 image_url base64 data URL)。"""
    return [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:{mime};base64,{base64.b64encode(image_bytes).decode()}",
                    },
                },
            ],
        }
    ]


# ──────────────── /relay/chat ────────────────


class RelayChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str = Field(min_length=1, max_length=100_000)


class RelayChatRequest(BaseModel):
    """App 拼好的完整 prompt。`log_input` 是给 ai_analysis_logs 看的原始用户
    输入(不含模板 / 分类上下文,与中转前 App 端日志语义一致);缺省回退为
    最后一条 user 消息。"""

    messages: list[RelayChatMessage] = Field(min_length=1, max_length=_MAX_MESSAGES)
    temperature: float = Field(default=0.3, ge=0, le=2)
    disable_thinking: bool = False
    entry_type: Literal["parse_tx_text", "chat"]
    ledger_id: str | None = Field(default=None, max_length=128)
    log_input: str | None = Field(default=None, max_length=50_000)


@router.post("/relay/chat")
async def relay_chat(
    req: RelayChatRequest,
    request: Request,
    _scopes: set[str] = Depends(_RELAY_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, object]:
    _rate_limited(current_user.id)

    total_chars = sum(len(m.content) for m in req.messages)
    if total_chars > _MAX_MESSAGES_TOTAL_CHARS:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail={
                "error_code": "AI_RELAY_PAYLOAD_TOO_LARGE",
                "message": f"messages total {total_chars} chars exceeds {_MAX_MESSAGES_TOTAL_CHARS}",
            },
        )

    profile = _resolve_profile(db, current_user.id)
    try:
        cfg = resolve_chat_provider(current_user, profile)
    except NoChatProviderError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_NO_CHAT_PROVIDER", "message": str(exc)},
        )

    input_text = req.log_input or next(
        (m.content for m in reversed(req.messages) if m.role == "user"), None,
    )

    # 识别前判重:文本提取请求先匹配该用户已识别过的账单唯一标识
    # (订单号/流水号)。命中 = 同一笔账单重复到达:记录重复、不调 LLM、
    # 返回 duplicate(空 content),App 端静默跳过(不记账不通知)。
    # 自由对话(entry_type='chat')永不判重 —— 用户可能在聊天里手打订单号。
    if req.entry_type == "parse_tx_text" and get_settings().ai_bill_identifier_dedup_enabled:
        duplicate_of = await _find_duplicate_identifier(
            db.get_bind(), current_user.id, input_text,
        )
        if duplicate_of:
            await _mark_duplicate_hit(db.get_bind(), current_user.id, duplicate_of)
            await write_ai_analysis_log_async(
                user_id=current_user.id,
                entry_type="parse_tx_text",
                status="ok",
                provider_id=None,
                model=None,
                ledger_id=req.ledger_id,
                input_text=input_text,
                output_text=None,
                error_message=None,
                duration_ms=0,
                client_ip=request.client.host if request.client else None,
                dedup_hit="duplicate_identifier",
            )
            logger.info(
                "ai.relay.duplicate user=%s source=%s identifier_len=%d",
                current_user.id, req.entry_type, len(duplicate_of),
            )
            return {
                "content": "",
                "provider_id": None,
                "model": None,
                "usage": None,
                "duplicate": True,
                "matched_identifier": duplicate_of,
            }

    messages = [{"role": m.role, "content": m.content} for m in req.messages]

    try:
        _preflight_host_policy(cfg)
    except AiHostNotAllowedError as exc:
        raise _host_not_allowed(exc) from exc

    t0 = time.perf_counter()
    log_status = "ok"
    output_text: str | None = None
    error_message: str | None = None
    usage: dict | None = None
    try:
        try:
            # 同 (user, provider) 的文字调用与视觉共用「并发数」上限:App 端
            # 多个自动事件并行提取时在这里排队,避免瞬间打满上游配额。
            async with _provider_sem(
                current_user.id, cfg.provider_id, cfg.vision_concurrency,
            ):
                result = await call_chat_text(
                    config=cfg,
                    messages=messages,  # type: ignore[arg-type]
                    temperature=req.temperature,
                    disable_thinking=req.disable_thinking,
                    # 自动记账提取要抢在客户端 40s deadline 之前失败;自由聊天/问 AI
                    # 允许慢(长推理),用 120s 档。
                    timeout=(
                        _UPSTREAM_TIMEOUT_PARSE_TEXT
                        if req.entry_type == "parse_tx_text"
                        else _UPSTREAM_TIMEOUT_CHAT
                    ),
                )
            usage = result.usage
            output_text = result.content
            # 收割账单唯一标识入库,供后续请求识别前判重(失败不影响响应)
            if req.entry_type == "parse_tx_text":
                harvested = harvest_identifiers(result.content)
                if harvested:
                    await _register_identifiers(
                        db.get_bind(), current_user.id, harvested,
                        source="parse_tx_text",
                    )
            return {
                "content": result.content,
                "provider_id": cfg.provider_id,
                "model": cfg.model,
                "usage": usage,
                "duplicate": False,
            }
        except ChatProviderError as exc:
            log_status = "error"
            error_message = str(exc)[:500]
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"error_code": "AI_PROVIDER_ERROR", "message": str(exc)[:200]},
            ) from exc
        except AiHostNotAllowedError as exc:
            # SSRF 策略拒绝:配置类错误 → 400(不是 502 transient,客户端不该重试)
            log_status = "error"
            error_message = str(exc)[:500]
            raise _host_not_allowed(exc) from exc
    finally:
        await write_ai_analysis_log_async(
            user_id=current_user.id,
            entry_type=req.entry_type,
            status=log_status,
            provider_id=cfg.provider_id,
            model=cfg.model,
            ledger_id=req.ledger_id,
            input_text=input_text,
            output_text=output_text,
            error_message=error_message,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            prompt_tokens=token_count(usage, "prompt_tokens"),
            completion_tokens=token_count(usage, "completion_tokens"),
            total_tokens=token_count(usage, "total_tokens"),
            client_ip=request.client.host if request.client else None,
        )


# ──────────────── /relay/vision ────────────────


@router.post("/relay/vision")
async def relay_vision(
    request: Request,
    image: UploadFile = File(...),
    prompt: str = Form(..., max_length=100_000),
    disable_thinking: bool = Form(default=True),
    ledger_id: str | None = Form(default=None, max_length=128),
    log_input: str | None = Form(default=None, max_length=50_000),
    _scopes: set[str] = Depends(_RELAY_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """截图 / 选图记账中转。App 传拼好的 prompt + 原图,server 拼 vision
    content array 代发;日志带原图落盘(Web「AI 调用记录」图片预览同现状)。"""
    _rate_limited(current_user.id)

    mime, image_bytes = await _check_image_upload(image)

    profile = _resolve_profile(db, current_user.id)
    try:
        cfg = resolve_vision_provider(current_user, profile)
    except NoVisionProviderError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_NO_VISION_PROVIDER", "message": str(exc)},
        )

    input_text = log_input or f"image(mime={mime}, size={len(image_bytes)} bytes)"
    messages = _build_vision_messages(prompt, mime, image_bytes)

    try:
        _preflight_host_policy(cfg)
    except AiHostNotAllowedError as exc:
        raise _host_not_allowed(exc) from exc

    t0 = time.perf_counter()
    log_status = "ok"
    output_text: str | None = None
    error_message: str | None = None
    usage: dict | None = None
    try:
        try:
            async with _provider_sem(
                current_user.id, cfg.provider_id, cfg.vision_concurrency,
            ):
                result = await call_chat_text(
                    config=cfg,
                    messages=messages,
                    temperature=0.3,
                    disable_thinking=disable_thinking,
                    timeout=_UPSTREAM_TIMEOUT_VISION,
                )
            usage = result.usage
            output_text = result.content
            # 截图/选图没有"识别前"的文本可比对,识别后收割标识入库,
            # 供之后的短信/通知文本请求前置判重(同一笔支付的跨通道重复)。
            harvested = harvest_identifiers(result.content)
            if harvested:
                await _register_identifiers(
                    db.get_bind(), current_user.id, harvested,
                    source="parse_tx_image",
                )
            return {
                "content": result.content,
                "provider_id": cfg.provider_id,
                "model": cfg.model,
                "usage": usage,
                "duplicate": False,
            }
        except ChatProviderError as exc:
            log_status = "error"
            error_message = str(exc)[:500]
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"error_code": "AI_PROVIDER_ERROR", "message": str(exc)[:200]},
            ) from exc
        except AiHostNotAllowedError as exc:
            log_status = "error"
            error_message = str(exc)[:500]
            raise _host_not_allowed(exc) from exc
    finally:
        await write_ai_analysis_log_with_image_async(
            user_id=current_user.id,
            entry_type="parse_tx_image",
            status=log_status,
            image_bytes=image_bytes,
            image_mime=mime,
            provider_id=cfg.provider_id,
            model=cfg.model,
            ledger_id=ledger_id,
            input_text=input_text,
            output_text=output_text,
            error_message=error_message,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            prompt_tokens=token_count(usage, "prompt_tokens"),
            completion_tokens=token_count(usage, "completion_tokens"),
            total_tokens=token_count(usage, "total_tokens"),
            client_ip=request.client.host if request.client else None,
        )


# ──────────────── /relay/vision-batch ────────────────


@router.post("/relay/vision-batch")
async def relay_vision_batch(
    request: Request,
    images: list[UploadFile] = File(...),
    prompt: str = Form(..., max_length=100_000),
    disable_thinking: bool = Form(default=True),
    ledger_id: str | None = Form(default=None, max_length=128),
    log_input: str | None = Form(default=None, max_length=50_000),
    _scopes: set[str] = Depends(_RELAY_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """一次多图识别的中转(App「AI 助手选多张图」)。

    与 /relay/vision 不同:一次收 N 张图,按该用户 vision provider 的
    `visionConcurrency`(有上限并发队列)至多 K 张并行调用大模型,其余排队;
    并发闸与 chat / 单图 vision 共享(同一 (user, provider)),整批与其它
    请求之间也互相限流。每张图仍是一次独立的 LLM 调用(每张只见自己的图 +
    同一 prompt,不跨图合并),逐张落一条 ai_analysis_logs(原图落盘)。返回
    逐张结果数组,按 `image_index` 保序;单张上游失败只记该张 `error`,整批
    仍 200(整批级的 config / 大小 / mime 问题才 4xx)。
    """
    _rate_limited(current_user.id)

    # 发起前整批校验:任何一张非法即整批失败,不调用 provider。
    if len(images) > _MAX_BATCH_IMAGES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_IMAGE_BATCH_TOO_LARGE",
                "message": f"at most {_MAX_BATCH_IMAGES} images per batch (got {len(images)})",
            },
        )
    prepared: list[tuple[str, bytes]] = []
    for image in images:
        mime, image_bytes = await _check_image_upload(image)
        prepared.append((mime, image_bytes))

    # 限流**按张数计令牌**:每张图是一次独立上游调用(独立计费),只在入口记 1
    # 个令牌会把「60/分钟」放大成 60×N 次上游调用。在这里补记剩余张数
    # (入口那次已计 1)。
    if len(prepared) > 1:
        _rate_limited(current_user.id, len(prepared) - 1)

    profile = _resolve_profile(db, current_user.id)
    try:
        cfg = resolve_vision_provider(current_user, profile)
    except NoVisionProviderError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_NO_VISION_PROVIDER", "message": str(exc)},
        )

    sem = _provider_sem(
        current_user.id, cfg.provider_id, cfg.vision_concurrency,
    )
    # host 策略在整批启动前判一次(同 provider → 各张结果一致)。
    try:
        _preflight_host_policy(cfg)
    except AiHostNotAllowedError as exc:
        raise _host_not_allowed(exc) from exc
    results: list[dict[str, object]] = [{} for _ in prepared]

    async def recognize(index: int, mime: str, image_bytes: bytes) -> None:
        async with sem:
            input_text = log_input or f"image[{index}](mime={mime}, size={len(image_bytes)} bytes)"
            messages = _build_vision_messages(prompt, mime, image_bytes)
            duration_ms = 0
            usage: dict | None = None
            content: str | None = None
            error_message: str | None = None
            t0 = time.perf_counter()
            try:
                result = await call_chat_text(
                    config=cfg,
                    messages=messages,
                    temperature=0.3,
                    disable_thinking=disable_thinking,
                    timeout=_UPSTREAM_TIMEOUT_VISION,
                )
                usage = result.usage
                content = result.content
                harvested = harvest_identifiers(result.content)
                if harvested:
                    await _register_identifiers(
                        db.get_bind(), current_user.id, harvested,
                        source="parse_tx_image",
                    )
            except ChatProviderError as exc:
                error_message = str(exc)[:500]
            except AiHostNotAllowedError as exc:
                # 单张的 host 违规让该张记 error(整批仍 200,与既有「单张失败
                # 不影响其它张」的语义一致);host 策略对同 provider 是确定的,
                # 因此整批各张会一致失败。
                error_message = str(exc)[:500]
            finally:
                duration_ms = int((time.perf_counter() - t0) * 1000)
                await write_ai_analysis_log_with_image_async(
                    user_id=current_user.id,
                    entry_type="parse_tx_image",
                    status="ok" if error_message is None else "error",
                    image_bytes=image_bytes,
                    image_mime=mime,
                    provider_id=cfg.provider_id,
                    model=cfg.model,
                    ledger_id=ledger_id,
                    input_text=input_text,
                    output_text=content,
                    error_message=error_message,
                    duration_ms=duration_ms,
                    prompt_tokens=token_count(usage, "prompt_tokens"),
                    completion_tokens=token_count(usage, "completion_tokens"),
                    total_tokens=token_count(usage, "total_tokens"),
                    client_ip=request.client.host if request.client else None,
                )
            results[index] = {
                "image_index": index,
                "content": content or "",
                "usage": usage,
                "duplicate": False,
                "error": error_message,
            }

    await asyncio.gather(
        *(recognize(i, mime, b) for i, (mime, b) in enumerate(prepared)),
        return_exceptions=False,
    )

    return {
        "provider_id": cfg.provider_id,
        "model": cfg.model,
        "results": results,
    }


# ──────────────── /relay/stt ────────────────


@router.post("/relay/stt")
async def relay_stt(
    request: Request,
    audio: UploadFile = File(...),
    log_input: str | None = Form(default=None, max_length=50_000),
    _scopes: set[str] = Depends(_RELAY_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, object]:
    """语音转文字中转。App 传录音文件,server 按用户绑定的 speech provider
    转写(内置智谱走 input_audio,其余走 /audio/transcriptions)。"""
    _rate_limited(current_user.id)

    mime = (audio.content_type or "").lower()
    if mime and not (mime.startswith("audio/") or mime == "application/octet-stream"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_AUDIO_TYPE_INVALID",
                "message": f"unsupported audio type: {mime!r}",
            },
        )
    audio_bytes = await audio.read()
    if len(audio_bytes) > _MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail={
                "error_code": "AI_AUDIO_TOO_LARGE",
                "message": f"audio size {len(audio_bytes)} exceeds 10MB",
            },
        )
    # 魔数校验:`application/octet-stream`(以及缺失 CT)是 App 的默认形态,
    # 原先它等于一个**通配符** —— 任意载荷(HTML / 脚本 / zip)都能借此进入
    # 上游 STT,server 侧零校验。这里对这类「不可信声明」做容器识别。
    #
    # 明确声明 `audio/*` 的保持放行:音频容器家族(amr / adts-aac / opus-in-ogg /
    # 各家 m4a 变体…)远比图片松散,严格白名单会误伤合法录音,而「声明 audio/*
    # 但内容不是音频」只会被上游拒(不构成放大面)。图片侧则一律校验魔数
    # ——那里白名单是封闭的 4 种,且要防的正是「声明 text/html 改名 .png」。
    # 0 字节仍放行(既有 HARDENING 锁定的行为)。
    trusted_declaration = bool(mime) and mime.startswith("audio/")
    if (
        audio_bytes
        and not trusted_declaration
        and not is_plausible_audio(audio_bytes, declared_mime=mime or None)
    ):
        logger.warning(
            "ai.relay.audio_magic_rejected declared=%r filename=%r bytes=%d",
            audio.content_type, audio.filename, len(audio_bytes),
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                "error_code": "AI_AUDIO_TYPE_INVALID",
                "message": "payload is not a recognizable audio container (magic bytes mismatch)",
            },
        )

    profile = _resolve_profile(db, current_user.id)
    try:
        cfg = resolve_audio_provider(current_user, profile)
    except NoAudioProviderError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_NO_AUDIO_PROVIDER", "message": str(exc)},
        )

    input_text = log_input or f"audio(mime={mime or 'unknown'}, size={len(audio_bytes)} bytes)"

    try:
        _preflight_host_policy(cfg)
    except AiHostNotAllowedError as exc:
        raise _host_not_allowed(exc) from exc

    t0 = time.perf_counter()
    log_status = "ok"
    output_text: str | None = None
    error_message: str | None = None
    try:
        try:
            text = await transcribe_audio(
                config=cfg,
                audio_bytes=audio_bytes,
                audio_mime=mime or None,
                filename=audio.filename,
                timeout=_UPSTREAM_TIMEOUT_STT,
            )
            output_text = text
            return {
                "text": text,
                "provider_id": cfg.provider_id,
                "model": cfg.model,
            }
        except ChatProviderError as exc:
            log_status = "error"
            error_message = str(exc)[:500]
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"error_code": "AI_PROVIDER_ERROR", "message": str(exc)[:200]},
            ) from exc
        except AiHostNotAllowedError as exc:
            log_status = "error"
            error_message = str(exc)[:500]
            raise _host_not_allowed(exc) from exc
    finally:
        await write_ai_analysis_log_async(
            user_id=current_user.id,
            entry_type="stt",
            status=log_status,
            provider_id=cfg.provider_id,
            model=cfg.model,
            input_text=input_text,
            output_text=output_text,
            error_message=error_message,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            client_ip=request.client.host if request.client else None,
        )
