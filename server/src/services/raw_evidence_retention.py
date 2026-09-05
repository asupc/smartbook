"""Expiry-based evidence deletion, independent of read traffic and sync."""
from datetime import datetime, timezone

from sqlalchemy import delete
from sqlalchemy.orm import Session

from ..models import RawBookkeepingEvidence


def purge_expired_raw_evidence(db: Session, *, now: datetime | None = None) -> int:
    cutoff = now or datetime.now(timezone.utc)
    result = db.execute(delete(RawBookkeepingEvidence).where(
        RawBookkeepingEvidence.expires_at.is_not(None),
        RawBookkeepingEvidence.expires_at <= cutoff,
    ))
    db.commit()
    return int(result.rowcount or 0)
