"""AI 分析调用日志写入 — ask / parse-tx-image / parse-tx-text 每次调用落一行。

跟 `mcp/server.py` 的 `_write_call_log` 同模式:
  - 用独立 `SessionLocal`(与请求 session 解耦)
  - 同步 writer 失败静默(打日志告警即可),不改变 AI 主流程
  - async endpoint 必须走本文末尾的异步 wrapper，把 DB / 图片 I/O 丢到线程池

区别是**记录完整输入输出**(含用户文本与模型回复全文,截断到合理上限),
而不是脱敏摘要 —— 这是调试 prompt、排查 provider 问题的核心价值。图片输入
本体不落 DB(可能 5MB),由调用方换成图片元信息摘要字符串;App 上报路径
额外把原图存磁盘(ai_log_image_dir),DB 只记 image_path / image_mime,
方便 Web 详情查看 —— 见 `write_ai_analysis_log_with_image`。
"""
from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable
from pathlib import Path
from typing import Any

from ...config import get_settings
from ...database import SessionLocal
from ...models import AIAnalysisLog

logger = logging.getLogger(__name__)

# 全文存储的截断上限 — 足够装一次完整问答(罕见超长输出),又避免单行
# Text 字段过大拖慢查询 / 撑爆日志表体积。
_MAX_INPUT_CHARS = 50_000
_MAX_OUTPUT_CHARS = 100_000

# mime → 落盘扩展名(与 routers/ai/logs.py 的白名单对齐)
_EXT_BY_MIME = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
}


def _image_root() -> Path:
    root = Path(get_settings().ai_log_image_dir).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    return root


def token_count(usage: dict | None, key: str) -> int | None:
    """从 provider usage dict 取 token 数;缺字段 / 非数字 → None。"""
    if not usage:
        return None
    v = usage.get(key)
    return int(v) if isinstance(v, (int, float)) else None


def write_ai_analysis_log(
    *,
    user_id: str,
    entry_type: str,
    status: str,
    provider_id: str | None = None,
    model: str | None = None,
    ledger_id: str | None = None,
    input_text: str | None = None,
    output_text: str | None = None,
    error_message: str | None = None,
    duration_ms: int = 0,
    prompt_tokens: int | None = None,
    completion_tokens: int | None = None,
    total_tokens: int | None = None,
    client_ip: str | None = None,
    dedup_hit: str | None = None,
) -> None:
    """同步落库 — INSERT 单行,毫秒级。失败静默(打日志,不 raise)。"""
    try:
        with SessionLocal() as db:
            db.add(
                AIAnalysisLog(
                    user_id=user_id,
                    entry_type=entry_type,
                    status=status,
                    provider_id=provider_id,
                    model=model,
                    ledger_id=ledger_id,
                    input_text=input_text[: _MAX_INPUT_CHARS] if input_text else None,
                    output_text=output_text[: _MAX_OUTPUT_CHARS] if output_text else None,
                    error_message=error_message[:500] if error_message else None,
                    duration_ms=duration_ms,
                    prompt_tokens=prompt_tokens,
                    completion_tokens=completion_tokens,
                    total_tokens=total_tokens,
                    client_ip=client_ip,
                    dedup_hit=dedup_hit,
                )
            )
            db.commit()
    except Exception:
        logger.exception(
            "ai: failed to write analysis log entry_type=%s user=%s", entry_type, user_id,
        )


def write_ai_analysis_log_with_image(
    *,
    user_id: str,
    entry_type: str,
    status: str,
    image_bytes: bytes,
    image_mime: str,
    provider_id: str | None = None,
    model: str | None = None,
    ledger_id: str | None = None,
    input_text: str | None = None,
    output_text: str | None = None,
    error_message: str | None = None,
    duration_ms: int = 0,
    prompt_tokens: int | None = None,
    completion_tokens: int | None = None,
    total_tokens: int | None = None,
    client_ip: str | None = None,
) -> None:
    """带图版本(App 上报截图记账):日志行照常落库,图片落盘。

    层级上仍是「失败静默」:DB 写失败只打日志;**图片写盘失败只断图**
    (image_path 留空,日志行不丢) —— 审计记录是主诉求,图片是增强。
    文件名 {log_id}{ext},随日志行手动删除时一并删除(日志不设自动保留期)。
    """
    try:
        with SessionLocal() as db:
            row = AIAnalysisLog(
                user_id=user_id,
                entry_type=entry_type,
                status=status,
                provider_id=provider_id,
                model=model,
                ledger_id=ledger_id,
                input_text=input_text[: _MAX_INPUT_CHARS] if input_text else None,
                output_text=output_text[: _MAX_OUTPUT_CHARS] if output_text else None,
                error_message=error_message[:500] if error_message else None,
                duration_ms=duration_ms,
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
                total_tokens=total_tokens,
                client_ip=client_ip,
            )
            db.add(row)
            db.flush()  # 拿自增 id,图片文件名要用
            try:
                ext = _EXT_BY_MIME.get(image_mime, "")
                storage_path = _image_root() / f"{row.id}{ext}"
                storage_path.write_bytes(image_bytes)
                row.image_path = str(storage_path)
                row.image_mime = image_mime
            except Exception:
                logger.exception(
                    "ai: failed to store log image log_id=%s type=%s", row.id, entry_type,
                )
            db.commit()
    except Exception:
        logger.exception(
            "ai: failed to write analysis log with image entry_type=%s user=%s",
            entry_type, user_id,
        )

async def _run_log_write_in_thread(
    writer: Callable[..., None],
    kwargs: dict[str, Any],
) -> None:
    """在线程池执行同步日志写入，避免 SQLite/文件 I/O 阻塞事件循环。"""
    await asyncio.to_thread(writer, **kwargs)


async def write_ai_analysis_log_async(**kwargs: Any) -> None:
    """异步 endpoint 使用的无图日志入口；完成后再返回，保持日志可靠性。

    M6-5:开关 `AI_LOG_OUTBOX_ENABLED` 开启时改走可靠 outbox(先落 pending 行
    即返回,worker 异步归档);关闭时维持原「线程池同步落库」路径。
    """
    from .analysis_log_outbox import enqueue_ai_analysis_log

    if get_settings().ai_log_outbox_enabled:
        await asyncio.to_thread(enqueue_ai_analysis_log, **kwargs)
        return
    await _run_log_write_in_thread(write_ai_analysis_log, kwargs)


async def write_ai_analysis_log_with_image_async(**kwargs: Any) -> None:
    """异步 endpoint 使用的带图日志入口；图片写盘同样在线程池执行。

    M6-5:开关开启时改走可靠 outbox(图片先落 spool,再落 pending 行)。
    """
    from .analysis_log_outbox import enqueue_ai_analysis_log_with_image

    if get_settings().ai_log_outbox_enabled:
        await asyncio.to_thread(enqueue_ai_analysis_log_with_image, **kwargs)
        return
    await _run_log_write_in_thread(write_ai_analysis_log_with_image, kwargs)
