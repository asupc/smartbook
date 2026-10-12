"""Expiry-based evidence deletion, independent of read traffic and sync."""
from datetime import datetime, timezone

from sqlalchemy import delete
from sqlalchemy.orm import Session

from ..models import RawBookkeepingEvidence


def purge_expired_raw_evidence(
    db: Session,
    *,
    now: datetime | None = None,
    user_id: str | None = None,
    source: str | None = None,
) -> int:
    """删除已过期的原始证据(``expires_at`` 非空且 <= cutoff)。

    ``user_id`` 非 None 时只清该用户(用户面 cleanup 端点);None = 站点级
    清理(保留期循环用)。``source`` 非 None 时只清该来源。没有 TTL 的行
    永不删除。
    """
    cutoff = now or datetime.now(timezone.utc)
    conditions = [
        RawBookkeepingEvidence.expires_at.is_not(None),
        RawBookkeepingEvidence.expires_at <= cutoff,
    ]
    if user_id is not None:
        conditions.append(RawBookkeepingEvidence.user_id == user_id)
    if source is not None:
        conditions.append(RawBookkeepingEvidence.source == source)
    result = db.execute(delete(RawBookkeepingEvidence).where(*conditions))
    db.commit()
    return int(result.rowcount or 0)


def purge_captured_before(
    db: Session,
    *,
    cutoff: datetime,
    user_id: str,
    source: str | None = None,
) -> int:
    """删除某用户在 ``cutoff`` 之前**采集**的证据(显式窗口语义)。

    与 ``purge_expired_raw_evidence`` 的区别:这里按 ``captured_at`` 而不是
    ``expires_at`` 判定 —— 只在调用方显式给了 ``before`` 时才允许,避免
    「空请求 = 全删」。未过期(expires_at 在未来)的行同样会被删,这是显式
    窗口删除的预期语义。
    """
    conditions = [
        RawBookkeepingEvidence.user_id == user_id,
        RawBookkeepingEvidence.captured_at < cutoff,
    ]
    if source:
        conditions.append(RawBookkeepingEvidence.source == source)
    result = db.execute(delete(RawBookkeepingEvidence).where(*conditions))
    db.commit()
    return int(result.rowcount or 0)
