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

from ...database import get_db
from ...deps import get_current_user, require_any_scopes
from ...models import User, UserProfile
from ...security import SCOPE_APP_WRITE, SCOPE_WEB_WRITE
from ...config import get_settings
from ...services.ai import (
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
from ...services.ai.bill_identifier import (
    find_duplicate_identifier,
    harvest_identifiers,
    mark_duplicate_hit,
    register_identifiers,
)
from ...services.ai.analysis_log import (
    token_count,
    write_ai_analysis_log,
    write_ai_analysis_log_with_image,
)
from sqlalchemy import select
from sqlalchemy.orm import Session

logger = logging.getLogger(__name__)
router = APIRouter()

_RELAY_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_WRITE)

# 限流:单 user 60 秒内最多 60 次(自动化渠道批量触发时的防风暴上限,
# 正常手动 + 自动记账远达不到)。test-provider 的 30/min 是独立计数。
_RATE_WINDOWS: dict[str, deque[float]] = defaultdict(deque)
_RATE_LIMIT_WINDOW_S = 60.0
_RATE_LIMIT_MAX = 60

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

# M2-5 上游 timeout。每档都比客户端 deadline 小 5s:服务端先放弃,客户端才能
# 拿到 502 AI_PROVIDER_ERROR(transient)并落 retry 状态;反过来客户端先超时,
# 上游请求还在跑,既白烧 token 又没有失败日志。
# 客户端 deadline 见 client/lib/ai/relay/ai_relay_client.dart(40/65/65/130s)。
_UPSTREAM_TIMEOUT_PARSE_TEXT = 35.0  # 自动记账文本提取
_UPSTREAM_TIMEOUT_CHAT = 120.0  # 自由聊天 / 问 AI,允许长推理
_UPSTREAM_TIMEOUT_VISION = 60.0  # 图片提取
_UPSTREAM_TIMEOUT_STT = 60.0  # 语音转写


def _check_rate_limit(user_id: str) -> bool:
    now = time.monotonic()
    window = _RATE_WINDOWS[user_id]
    while window and now - window[0] > _RATE_LIMIT_WINDOW_S:
        window.popleft()
    if len(window) >= _RATE_LIMIT_MAX:
        return False
    window.append(now)
    return True


def _rate_limited(user_id: str) -> None:
    if not _check_rate_limit(user_id):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={"error_code": "AI_RELAY_RATE_LIMITED"},
        )


def _resolve_profile(db: Session, user_id: str) -> UserProfile | None:
    return db.scalar(select(UserProfile).where(UserProfile.user_id == user_id))


def _resolve_image_mime(
    content_type: str | None, filename: str | None,
) -> str:
    """校验图片 mime;非法返回 ""。content-type 缺失时按文件后缀兜底。"""
    mime = (content_type or "").lower()
    if mime not in _ALLOWED_IMAGE_MIMES:
        mime = _SUFFIX_MIME.get(Path(filename or "").suffix.lower(), "")
    return mime


async def _check_image_upload(image: UploadFile) -> tuple[str, bytes]:
    """对单个 UploadFile 做 mime + 大小校验,返回 (mime, bytes)。

    非法 mime → 400 AI_IMAGE_TYPE_INVALID;超过 5MB → 413 AI_IMAGE_TOO_LARGE。
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
        duplicate_of = find_duplicate_identifier(db, current_user, input_text)
        if duplicate_of:
            mark_duplicate_hit(db, current_user, duplicate_of)
            write_ai_analysis_log(
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

    t0 = time.perf_counter()
    log_status = "ok"
    output_text: str | None = None
    error_message: str | None = None
    usage: dict | None = None
    try:
        try:
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
                    register_identifiers(
                        db, current_user, harvested, source="parse_tx_text",
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
    finally:
        write_ai_analysis_log(
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

    t0 = time.perf_counter()
    log_status = "ok"
    output_text: str | None = None
    error_message: str | None = None
    usage: dict | None = None
    try:
        try:
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
                register_identifiers(db, current_user, harvested, source="parse_tx_image")
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
    finally:
        write_ai_analysis_log_with_image(
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
    每张图仍是一次独立的 LLM 调用(每张只见自己的图 + 同一 prompt,不跨图
    合并),逐张落一条 ai_analysis_logs(原图落盘)。返回逐张结果数组,按
    `image_index` 保序;单张上游失败只记该张 `error`,整批仍 200(整批级的
    config / 大小 / mime 问题才 4xx)。
    """
    _rate_limited(current_user.id)

    # 发起前整批校验:任何一张非法即整批失败,不调用 provider。
    prepared: list[tuple[str, bytes]] = []
    for image in images:
        mime, image_bytes = await _check_image_upload(image)
        prepared.append((mime, image_bytes))

    profile = _resolve_profile(db, current_user.id)
    try:
        cfg = resolve_vision_provider(current_user, profile)
    except NoVisionProviderError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_NO_VISION_PROVIDER", "message": str(exc)},
        )

    sem = asyncio.Semaphore(cfg.vision_concurrency)
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
                    register_identifiers(db, current_user, harvested, source="parse_tx_image")
            except ChatProviderError as exc:
                error_message = str(exc)[:500]
            finally:
                duration_ms = int((time.perf_counter() - t0) * 1000)
                write_ai_analysis_log_with_image(
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

    profile = _resolve_profile(db, current_user.id)
    try:
        cfg = resolve_audio_provider(current_user, profile)
    except NoAudioProviderError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error_code": "AI_NO_AUDIO_PROVIDER", "message": str(exc)},
        )

    input_text = log_input or f"audio(mime={mime or 'unknown'}, size={len(audio_bytes)} bytes)"

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
    finally:
        write_ai_analysis_log(
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
