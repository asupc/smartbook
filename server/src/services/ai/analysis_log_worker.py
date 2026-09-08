"""M6-5 AI 日志 worker:claim/lease + 幂等归档 + dead-letter。

数据流:
  pending ──claim──> processing ──success──> 写最终 AIAnalysisLog + 删 outbox
     │                    │
     │                    ├─ transient ──> retry(next_attempt_at 退避)
     │                    └─ permanent/attempts 耗尽 ──> dead
     └─ enqueue 后等待

幂等保证:
  - 图片最终名 `{source_outbox_id}.{ext}`(确定性),spool `.ready` → `os.replace`
    → 最终目录;final 已存在则视为文件步骤完成。
  - AIAnalysisLog.source_outbox_id 唯一 → 重试时 unique conflict 读取既有行视为成功。
  - final INSERT 与 outbox DELETE 同一 DB 事务。

Worker 的 DB / 文件 I/O 全部经 `asyncio.to_thread`;不共享请求 Session。
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from sqlalchemy import select

from ...config import get_settings
from ...database import SessionLocal
from ...models import AIAnalysisLog, AIAnalysisLogOutbox

logger = logging.getLogger(__name__)

# 退避序列(秒):5s → 30s → 2m → 10m → 1h → 6h
_RETRY_BACKOFF = [5, 30, 120, 600, 3600, 21600]


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _next_backoff(attempt: int) -> datetime:
    seconds = _RETRY_BACKOFF[min(attempt, len(_RETRY_BACKOFF) - 1)]
    return _now() + timedelta(seconds=seconds)


def _spool_root() -> Path:
    return Path(get_settings().ai_log_spool_dir).expanduser()


def _image_root() -> Path:
    root = Path(get_settings().ai_log_image_dir).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    return root


def recover_stale_leases() -> int:
    """startup 恢复:把 lease 过期的 processing/retry 行放回 pending。

    返回恢复条数。多进程下用条件 UPDATE 抢占,只改自己能改的。
    """
    s = get_settings()
    now = _now()
    recovered = 0
    lease_cutoff = now - timedelta(seconds=s.ai_log_outbox_lease_seconds * 2)
    with SessionLocal() as db:
        rows = db.scalars(
            select(AIAnalysisLogOutbox).where(
                AIAnalysisLogOutbox.state == "processing",
                AIAnalysisLogOutbox.lease_expires_at < lease_cutoff,
            )
        ).all()
        for row in rows:
            row.state = "retry"
            row.next_attempt_at = now  # 立即可重试
            row.lease_owner = None
            row.lease_expires_at = None
            recovered += 1
        db.commit()
    if recovered:
        logger.info("ai.log.outbox.recovered_stale_leases count=%s", recovered)
    return recovered


def _claim_next(owner: str, limit: int) -> list[AIAnalysisLogOutbox]:
    """条件 UPDATE 抢占 eligible 行(§7.5),返回本 worker 成功领取的行。

    兼容 SQLite 与 PostgreSQL:用「先从候选集选 id,再条件 UPDATE 并 commit,
    再按 owner 回读」的流程,不依赖 FOR UPDATE SKIP LOCKED。
    """
    s = get_settings()
    now = _now()
    with SessionLocal() as db:
        # 1. 候选:pending 或 (retry 且 next_attempt_at <= now)。
        idle_retry = db.scalars(
            select(AIAnalysisLogOutbox)
            .where(
                AIAnalysisLogOutbox.state.in_(["pending", "retry"]),
                AIAnalysisLogOutbox.next_attempt_at.is_(None)
                | (AIAnalysisLogOutbox.next_attempt_at <= now),
            )
            .order_by(AIAnalysisLogOutbox.created_at)
            .limit(limit)
        ).all()
        claimed_ids = []
        for row in idle_retry:
            # 2. 条件 UPDATE:进入 processing,占 lease。
            res = db.execute(
                AIAnalysisLogOutbox.__table__.update()
                .where(
                    AIAnalysisLogOutbox.id == row.id,
                    AIAnalysisLogOutbox.state.in_(["pending", "retry"]),
                )
                .values(
                    state="processing",
                    lease_owner=owner,
                    lease_expires_at=now + timedelta(seconds=s.ai_log_outbox_lease_seconds),
                    attempt_count=AIAnalysisLogOutbox.attempt_count + 1,
                    updated_at=now,
                )
            )
            if res.rowcount == 1:
                claimed_ids.append(row.id)
        db.commit()

    if not claimed_ids:
        return []
    # 3. 按 owner 回读成功领取的行(文件 I/O 在事务外执行)。
    with SessionLocal() as db:
        return db.scalars(
            select(AIAnalysisLogOutbox).where(
                AIAnalysisLogOutbox.id.in_(claimed_ids),
                AIAnalysisLogOutbox.lease_owner == owner,
            )
        ).all()


def _archive_image(spool_path: str | None, outbox_id: str, image_mime: str | None) -> str | None:
    """把 spool `.ready` 归档成最终图片。返回最终绝对路径;缺失 → None(视为已归档/缺失)。

    幂等:final 已存在则直接返回 final(文件步骤已完成);两者都不存在 → None,
    由 worker 根据 spool 是否缺失决定 retry(临时的)或判 missing。
    """
    if not spool_path:
        return None
    spool = Path(spool_path)
    final = _image_root() / f"{outbox_id}.{_ext(image_mime)}"
    if final.exists():
        return str(final)
    if spool.exists():
        os.replace(spool, final)
        return str(final)
    return None


def _ext(image_mime: str | None) -> str:
    from .analysis_log import _EXT_BY_MIME

    return _EXT_BY_MIME.get(image_mime or "", ".bin")


def _is_transient(err: BaseException) -> bool:
    """判定是否瞬时错误(可重试)。DB 死锁 / 磁盘满 → 瞬时;其它按永久处理。"""
    msg = str(err).lower()
    transient_markers = ("locked", "disk", "temporar", "busy", "transport",
                         "connection refused", "timeout", "database is locked")
    return any(m in msg for m in transient_markers)


def _process_one(row: AIAnalysisLogOutbox) -> str:
    """处理单条:归档图片 → 写最终日志 → 删 outbox。返回 'success'|'retry'|'dead'。

    幂等:source_outbox_id 唯一冲突时读取既有日志视为成功。
    """
    payload = json.loads(row.payload_json)

    # 1. 图片归档(幂等)
    final_image = None
    try:
        final_image = _archive_image(
            row.image_spool_path, row.id, row.image_mime
        )
    except Exception as e:
        logger.exception("ai.log.outbox.archive_failed id=%s", row.id)
        if _is_transient(e):
            return _fail_retry(row, e)
        return _fail_dead(row, e)

    # spool 存在但归档后没有了 → 图片已成功移走或缺失,不因图阻塞日志行。
    # 2. 写最终日志(DB 事务内)
    try:
        with SessionLocal() as db:
            log = AIAnalysisLog(
                user_id=row.user_id,
                entry_type=payload.get("entry_type"),
                status=payload.get("status"),
                provider_id=payload.get("provider_id"),
                model=payload.get("model"),
                ledger_id=payload.get("ledger_id"),
                input_text=payload.get("input_text"),
                output_text=payload.get("output_text"),
                error_message=payload.get("error_message"),
                duration_ms=int(payload.get("duration_ms") or 0),
                prompt_tokens=payload.get("prompt_tokens"),
                completion_tokens=payload.get("completion_tokens"),
                total_tokens=payload.get("total_tokens"),
                client_ip=payload.get("client_ip"),
                image_path=final_image,
                image_mime=row.image_mime,
                source_outbox_id=row.id,
                called_at=_now(),
            )
            db.add(log)
            try:
                db.commit()
            except Exception:
                # unique(source_outbox_id) 冲突:行已存在 → 幂等成功。
                db.rollback()
                existing = db.scalar(
                    select(AIAnalysisLog).where(
                        AIAnalysisLog.source_outbox_id == row.id
                    )
                )
                if existing is None:
                    raise
            # 3. 同一事务删 outbox(§7.6 final INSERT 与 outbox DELETE 同步)
            result = db.execute(
                AIAnalysisLogOutbox.__table__.delete().where(
                    AIAnalysisLogOutbox.id == row.id
                )
            )
            db.commit()
            if result.rowcount == 1:
                return "success"
            return "success"  # 已被另一 worker 处理,同样视为成功
    except Exception as e:
        logger.exception("ai.log.outbox.final_write_failed id=%s", row.id)
        if _is_transient(e):
            return _fail_retry(row, e)
        return _fail_dead(row, e)


def _fail_retry(row: AIAnalysisLogOutbox, err: BaseException) -> str:
    s = get_settings()
    with SessionLocal() as db:
        r = db.get(AIAnalysisLogOutbox, row.id)
        if r is None or r.state != "processing":
            return "success"
        if r.attempt_count >= s.ai_log_outbox_max_attempts:
            r.state = "dead"
            r.last_error = str(err)[:2000]
            r.lease_owner = None
            r.lease_expires_at = None
            r.updated_at = _now()
            db.commit()
            logger.warning("ai.log.outbox.dead id=%s attempt=%s", row.id, r.attempt_count)
            return "dead"
        r.state = "retry"
        r.next_attempt_at = _next_backoff(r.attempt_count)
        r.last_error = str(err)[:2000]
        r.lease_owner = None
        r.lease_expires_at = None
        r.updated_at = _now()
        db.commit()
        return "retry"


def _fail_dead(row: AIAnalysisLogOutbox, err: BaseException) -> str:
    with SessionLocal() as db:
        r = db.get(AIAnalysisLogOutbox, row.id)
        if r is None or r.state != "processing":
            return "success"
        r.state = "dead"
        r.last_error = str(err)[:2000]
        r.lease_owner = None
        r.lease_expires_at = None
        r.updated_at = _now()
        db.commit()
    logger.error("ai.log.outbox.dead id=%s err=%s", row.id, type(err).__name__)
    return "dead"


def drain_once(owner: str | None = None) -> dict:
    """执行一轮 worker:recover stale → claim → process。返回统计。"""
    s = get_settings()
    owner = owner or f"worker-{uuid.uuid4()}"
    stats = {"claimed": 0, "success": 0, "retry": 0, "dead": 0}
    recover_stale_leases()
    rows = _claim_next(owner, s.ai_log_outbox_batch_size)
    stats["claimed"] = len(rows)
    for row in rows:
        result = _process_one(row)
        stats[result] += 1
    return stats


async def run_worker_forever(stop_event: asyncio.Event) -> None:
    """worker 主循环:空闲 1 秒,有 backlog 立即下一批。stop_event 用于优雅关闭。"""
    while not stop_event.is_set():
        try:
            stats = await asyncio.to_thread(drain_once)
            busy = stats["claimed"] > 0
        except Exception as e:
            logger.exception("ai.log.outbox.worker_loop_error %s", e)
            busy = False
        if busy:
            continue
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=1.0)
        except asyncio.TimeoutError:
            continue
