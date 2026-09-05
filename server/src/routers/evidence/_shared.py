"""Display-only raw evidence captured by automatic bookkeeping.

Raw SMS/notification/page text intentionally bypasses the sync event log. The
client may opt in to upload it; the web/mobile clients can only inspect or
remove it after upload.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.routing import APIRoute
from fastapi.exceptions import RequestValidationError
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError

from ...database import get_db
from ...deps import get_current_user, require_any_scopes
from ...ledger_access import get_accessible_ledger_by_external_id
from ...models import RawBookkeepingEvidence, User
from ...schemas import (
    RawEvidenceCleanupRequest,
    RawEvidenceListOut,
    RawEvidenceOut,
    RawEvidenceUpsertRequest,
)
from ...security import SCOPE_APP_WRITE, SCOPE_WEB_READ, SCOPE_WEB_WRITE

logger = logging.getLogger(__name__)
class EvidenceRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def safe_handler(request):
            try:
                response = await handler(request)
            except RequestValidationError:
                raise HTTPException(status_code=422, detail="Invalid evidence payload", headers={"Cache-Control": "no-store"}) from None
            except SQLAlchemyError:
                # SQL exception strings include bound raw content. Never pass
                # them to the global exception logger or to the viewer.
                logger.warning("evidence.request status=storage_failed")
                raise HTTPException(status_code=500, detail="Evidence storage unavailable", headers={"Cache-Control": "no-store"}) from None
            response.headers["Cache-Control"] = "no-store"
            return response
        return safe_handler


router = APIRouter(route_class=EvidenceRoute)
_READ_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_READ, SCOPE_WEB_WRITE)
_WRITE_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_WRITE)
_UPLOAD_SCOPE_DEP = require_any_scopes(SCOPE_APP_WRITE)

_ALLOWED_SOURCES = {
    "sms", "notification", "screenText", "screenshot", "sharedImage",
    "deepLinkText", "deepLinkDirect", "import", "recurring", "manual",
}
_MAX_SOURCE = 32


def _utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _validate_source(source: str) -> str:
    normalized = source.strip()
    if not normalized or len(normalized) > _MAX_SOURCE:
        raise HTTPException(status_code=422, detail="Invalid evidence source")
    # Keep forward compatibility for new client source names, while rejecting
    # whitespace/control characters that make filters and audit output unsafe.
    if any(ch.isspace() or ord(ch) < 32 for ch in normalized):
        raise HTTPException(status_code=422, detail="Invalid evidence source")
    return normalized


def _check_ledger_access(db: Session, user: User, ledger_id: str | None) -> None:
    if not ledger_id:
        return
    if get_accessible_ledger_by_external_id(
        db, user_id=user.id, ledger_external_id=ledger_id
    ) is None:
        # Do not reveal whether another user owns the external id.
        raise HTTPException(status_code=404, detail="Ledger not found")


def _out(row: RawBookkeepingEvidence, *, preview: bool = False) -> RawEvidenceOut:
    return RawEvidenceOut(
        id=row.id,
        event_key=row.event_key,
        ledger_id=row.ledger_id,
        source=row.source,
        source_channel=row.source_channel,
        external_id=row.external_id,
        content_hash=row.content_hash,
        actor=row.actor,
        title=row.title,
        body=(row.body[:499] + "…") if preview and row.body and len(row.body) > 500 else row.body,
        metadata=dict(row.metadata_json or {}),
        captured_at=row.captured_at,
        occurred_at=row.occurred_at,
        expires_at=row.expires_at,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


def _apply_payload(row: RawBookkeepingEvidence, payload: RawEvidenceUpsertRequest, now: datetime) -> None:
    row.ledger_id = payload.ledger_id.strip() if payload.ledger_id else None
    row.source = _validate_source(payload.source)
    row.source_channel = payload.source_channel.strip() if payload.source_channel else None
    row.external_id = payload.external_id.strip() if payload.external_id else None
    row.content_hash = payload.content_hash.strip() if payload.content_hash else None
    row.actor = payload.actor.strip() if payload.actor else None
    row.title = payload.title
    row.body = payload.body
    row.metadata_json = dict(payload.metadata)
    row.captured_at = _utc(payload.captured_at) or now
    row.occurred_at = _utc(payload.occurred_at)
    row.expires_at = _utc(payload.expires_at)
    row.updated_at = now



__all__ = ["router", "_READ_SCOPE_DEP", "_WRITE_SCOPE_DEP", "_UPLOAD_SCOPE_DEP",
    "_utc", "_validate_source", "_check_ledger_access", "_out", "_apply_payload",
    "RawBookkeepingEvidence", "RawEvidenceCleanupRequest", "RawEvidenceListOut",
    "RawEvidenceOut", "RawEvidenceUpsertRequest", "User", "Session", "Depends",
    "HTTPException", "Query", "status", "delete", "func", "select", "Any",
    "datetime", "timezone", "IntegrityError", "get_current_user", "get_db"]
