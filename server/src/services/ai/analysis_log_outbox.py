"""M6-5 AI 日志可靠 outbox:原子入队 + 失败 fallback。

请求路径不再等待最终日志落库/图片写盘,而是:
  1. 生成 outbox UUID;
  2. 独立 Session INSERT pending 行(带图任务先写 spool `.tmp`→原子 rename `.ready`);
  3. commit 成功即返回;
  4. commit 失败 fallback 到现有同步 writer(`analysis_log.py` 的
     write_ai_analysis_log[_with_image]),保证不丢日志,并累计 fallback 计数。

worker 侧见 `analysis_log_worker.py`。这里只负责「可靠入队 + 兜底」。
"""
from __future__ import annotations

import asyncio
import logging
import os
import uuid
from pathlib import Path
from typing import Any

from ...config import get_settings
from ...database import SessionLocal
from ...models import AIAnalysisLogOutbox
from .analysis_log import (
    _EXT_BY_MIME,
    _MAX_INPUT_CHARS,
    _MAX_OUTPUT_CHARS,
    write_ai_analysis_log,
    write_ai_analysis_log_with_image,
)

logger = logging.getLogger(__name__)


def _spool_root() -> Path:
    root = Path(get_settings().ai_log_spool_dir).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    return root


def _truncate(text: str | None, limit: int) -> str | None:
    return text[:limit] if text else None


def _build_payload(kwargs: dict[str, Any]) -> str:
    """从调用 kwargs 组装最终日志所需的 payload_json(不含图片二进制)。"""
    import json

    return json.dumps(
        {
            "entry_type": kwargs.get("entry_type"),
            "status": kwargs.get("status"),
            "provider_id": kwargs.get("provider_id"),
            "model": kwargs.get("model"),
            "ledger_id": kwargs.get("ledger_id"),
            "input_text": _truncate(kwargs.get("input_text"), _MAX_INPUT_CHARS),
            "output_text": _truncate(kwargs.get("output_text"), _MAX_OUTPUT_CHARS),
            "error_message": _truncate(kwargs.get("error_message"), 500),
            "duration_ms": int(kwargs.get("duration_ms") or 0),
            "prompt_tokens": kwargs.get("prompt_tokens"),
            "completion_tokens": kwargs.get("completion_tokens"),
            "total_tokens": kwargs.get("total_tokens"),
            "client_ip": kwargs.get("client_ip"),
        },
        ensure_ascii=False,
    )


def _insert_outbox_row(
    *,
    outbox_id: str,
    user_id: str,
    payload_json: str,
    image_spool_path: str | None = None,
    image_mime: str | None = None,
) -> None:
    """独立 Session 插入 pending 行并 commit。失败 raise(由调用方 fallback)。"""
    with SessionLocal() as db:
        db.add(
            AIAnalysisLogOutbox(
                id=outbox_id,
                user_id=user_id,
                payload_json=payload_json,
                image_spool_path=image_spool_path,
                image_mime=image_mime,
                state="pending",
                attempt_count=0,
            )
        )
        db.commit()


def _stage_image_spool(outbox_id: str, image_bytes: bytes, image_mime: str) -> str | None:
    """把图片写入 spool 目录:写 `{id}.tmp` 后原子 rename 成 `.ready`。

    返回 `.ready` 的绝对路径;mime 不入白名单 / 写盘失败返回 None(日志行仍可入队,
    图片当作缺失,worker 侧按 asset_missing 处理)。文件名只由 outbox_id + 白名单
    扩展名派生,绝不使用用户输入。
    """
    ext = _EXT_BY_MIME.get(image_mime or "")
    if not ext:
        return None
    root = _spool_root()
    tmp = root / f"{outbox_id}.tmp"
    ready = root / f"{outbox_id}.ready"
    try:
        tmp.write_bytes(image_bytes)
        os.replace(tmp, ready)
        return str(ready)
    except Exception:
        logger.exception("ai: failed to stage spool outbox_id=%s", outbox_id)
        # 清理可能残留的 .tmp
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return None


def enqueue_ai_analysis_log(**kwargs: Any) -> None:
    """文本日志入队:落 pending 行即返回。失败 fallback 到同步 writer。"""
    user_id = kwargs.get("user_id")
    if not get_settings().ai_log_outbox_enabled:
        write_ai_analysis_log(**kwargs)
        return

    outbox_id = str(uuid.uuid4())
    payload = _build_payload(kwargs)
    try:
        _insert_outbox_row(
            outbox_id=outbox_id, user_id=user_id, payload_json=payload
        )
    except Exception:
        logger.exception(
            "ai: outbox enqueue failed, fallback to sync writer type=%s user=%s",
            kwargs.get("entry_type"), user_id,
        )
        write_ai_analysis_log(**kwargs)
        return
    logger.info(
        "ai.log.outbox.enqueued outbox_id=%s type=%s user=%s",
        outbox_id, kwargs.get("entry_type"), user_id,
    )


def enqueue_ai_analysis_log_with_image(
    *,
    user_id: str,
    entry_type: str,
    status: str,
    image_bytes: bytes,
    image_mime: str,
    **kwargs: Any,
) -> None:
    """带图日志入队:先落图片 spool,再落 pending 行。失败 fallback 同步 writer。"""
    if not get_settings().ai_log_outbox_enabled:
        write_ai_analysis_log_with_image(
            user_id=user_id,
            entry_type=entry_type,
            status=status,
            image_bytes=image_bytes,
            image_mime=image_mime,
            **kwargs,
        )
        return

    outbox_id = str(uuid.uuid4())
    # entry_type/status 是具名参数,不在 **kwargs 里,需显式并入 payload。
    payload = _build_payload({
        "entry_type": entry_type,
        "status": status,
        **kwargs,
    })
    spool_path = _stage_image_spool(outbox_id, image_bytes, image_mime)
    try:
        _insert_outbox_row(
            outbox_id=outbox_id,
            user_id=user_id,
            payload_json=payload,
            image_spool_path=spool_path,
            image_mime=image_mime,
        )
    except Exception:
        logger.exception(
            "ai: outbox enqueue(with image) failed, fallback to sync writer "
            "type=%s user=%s", entry_type, user_id,
        )
        # 清理可能已落的 spool,避免 orphan。
        if spool_path:
            try:
                Path(spool_path).unlink(missing_ok=True)
            except OSError:
                pass
        write_ai_analysis_log_with_image(
            user_id=user_id,
            entry_type=entry_type,
            status=status,
            image_bytes=image_bytes,
            image_mime=image_mime,
            **kwargs,
        )
        return
    logger.info(
        "ai.log.outbox.enqueued outbox_id=%s type=%s user=%s",
        outbox_id, entry_type, user_id,
    )


async def enqueue_ai_analysis_log_async(**kwargs: Any) -> None:
    """异步 endpoint 使用的文本入队入口。"""
    await asyncio.to_thread(enqueue_ai_analysis_log, **kwargs)


async def enqueue_ai_analysis_log_with_image_async(**kwargs: Any) -> None:
    """异步 endpoint 使用的带图入队入口。"""
    await asyncio.to_thread(enqueue_ai_analysis_log_with_image, **kwargs)
