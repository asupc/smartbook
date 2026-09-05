"""Account-private evidence endpoints, outside the transaction sync channel."""
from ._shared import *  # noqa: F403

@router.post("/raw", response_model=RawEvidenceOut, status_code=status.HTTP_200_OK)
def upsert_raw_evidence(
    payload: RawEvidenceUpsertRequest,
    _scopes: set[str] = Depends(_UPLOAD_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RawEvidenceOut:
    source = _validate_source(payload.source)
    _check_ledger_access(db, current_user, payload.ledger_id)
    event_key = payload.event_key.strip()
    now = datetime.now(timezone.utc)
    if payload.expires_at is not None and _utc(payload.expires_at) <= now:
        raise HTTPException(status_code=410, detail="Evidence expired")
    row = db.scalar(
        select(RawBookkeepingEvidence).where(
            RawBookkeepingEvidence.user_id == current_user.id,
            RawBookkeepingEvidence.event_key == event_key,
        )
    )
    if row is None:
        row = RawBookkeepingEvidence(
            user_id=current_user.id,
            event_key=event_key,
            created_at=now,
        )
        db.add(row)
    _apply_payload(row, payload, now)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        row = db.scalar(select(RawBookkeepingEvidence).where(
            RawBookkeepingEvidence.user_id == current_user.id,
            RawBookkeepingEvidence.event_key == event_key,
        ))
        if row is None:
            raise HTTPException(status_code=409, detail="Evidence write conflict") from None
        _apply_payload(row, payload, now)
        db.commit()
    db.refresh(row)
    return _out(row)


@router.get("/raw", response_model=RawEvidenceListOut)
def list_raw_evidence(
    source: str | None = Query(default=None, max_length=32),
    ledger_id: str | None = Query(default=None, max_length=128),
    from_at: datetime | None = Query(default=None, alias="from"),
    to_at: datetime | None = Query(default=None, alias="to"),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RawEvidenceListOut:
    _check_ledger_access(db, current_user, ledger_id)
    now = datetime.now(timezone.utc)
    db.execute(delete(RawBookkeepingEvidence).where(
        RawBookkeepingEvidence.user_id == current_user.id,
        RawBookkeepingEvidence.expires_at.is_not(None),
        RawBookkeepingEvidence.expires_at <= now,
    ))
    db.commit()
    filters: list[Any] = [RawBookkeepingEvidence.user_id == current_user.id]
    if source:
        filters.append(RawBookkeepingEvidence.source == _validate_source(source))
    if ledger_id:
        filters.append(RawBookkeepingEvidence.ledger_id == ledger_id.strip())
    if from_at:
        filters.append(RawBookkeepingEvidence.captured_at >= (_utc(from_at) or from_at))
    if to_at:
        filters.append(RawBookkeepingEvidence.captured_at <= (_utc(to_at) or to_at))
    total = int(db.scalar(select(func.count()).select_from(RawBookkeepingEvidence).where(*filters)) or 0)
    rows = db.scalars(
        select(RawBookkeepingEvidence)
        .where(*filters)
        .order_by(RawBookkeepingEvidence.captured_at.desc(), RawBookkeepingEvidence.id.desc())
        .limit(limit)
        .offset(offset)
    ).all()
    return RawEvidenceListOut(total=total, items=[_out(row, preview=True) for row in rows])


@router.get("/raw/{evidence_id}", response_model=RawEvidenceOut)
def get_raw_evidence(
    evidence_id: str,
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RawEvidenceOut:
    row = db.scalar(
        select(RawBookkeepingEvidence).where(
            RawBookkeepingEvidence.id == evidence_id,
            RawBookkeepingEvidence.user_id == current_user.id,
        )
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Evidence not found")
    if row.expires_at is not None and _utc(row.expires_at) <= datetime.now(timezone.utc):
        db.delete(row)
        db.commit()
        raise HTTPException(status_code=404, detail="Evidence not found")
    return _out(row)


@router.patch("/raw/{evidence_id}", response_model=RawEvidenceOut)
def patch_raw_evidence(
    evidence_id: str,
    payload: RawEvidenceUpsertRequest,
    _scopes: set[str] = Depends(_UPLOAD_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RawEvidenceOut:
    """Replace an evidence row while preserving its stable id/event key."""
    row = db.scalar(
        select(RawBookkeepingEvidence).where(
            RawBookkeepingEvidence.id == evidence_id,
            RawBookkeepingEvidence.user_id == current_user.id,
        )
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Evidence not found")
    _check_ledger_access(db, current_user, payload.ledger_id)
    now = datetime.now(timezone.utc)
    if payload.expires_at is not None and _utc(payload.expires_at) <= now:
        raise HTTPException(status_code=410, detail="Evidence expired")
    _apply_payload(row, payload, now)
    db.commit()
    db.refresh(row)
    return _out(row)


@router.delete("/raw/{evidence_id}")
def delete_raw_evidence(
    evidence_id: str,
    _scopes: set[str] = Depends(_WRITE_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, bool]:
    row = db.scalar(
        select(RawBookkeepingEvidence).where(
            RawBookkeepingEvidence.id == evidence_id,
            RawBookkeepingEvidence.user_id == current_user.id,
        )
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Evidence not found")
    db.delete(row)
    db.commit()
    return {"ok": True}


@router.post("/raw/cleanup")
def cleanup_raw_evidence(
    payload: RawEvidenceCleanupRequest | None = None,
    _scopes: set[str] = Depends(_WRITE_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict[str, int]:
    request = payload or RawEvidenceCleanupRequest()
    cutoff = _utc(request.before) or datetime.now(timezone.utc)
    filters: list[Any] = [
        RawBookkeepingEvidence.user_id == current_user.id,
        RawBookkeepingEvidence.captured_at < cutoff,
    ]
    if request.source:
        filters.append(RawBookkeepingEvidence.source == _validate_source(request.source))
    result = db.execute(delete(RawBookkeepingEvidence).where(*filters))
    db.commit()
    return {"deleted": int(result.rowcount or 0)}
