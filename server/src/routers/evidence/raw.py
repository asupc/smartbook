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
    # S3(审核记录 建议-14 / S1 handed-off):offset 必须有 int64 上界 ——
    # Python int 无界,超过 int64 会在 SQLAlchemy → SQLite/PG INTEGER/int8
    # 转换时抛 OverflowError → 500(对抗 injection: offset=2**63)。
    # 上界取 MAX_INT64(不用更小值):`test_ai_relay_adversarial.py` 的
    # HARDENING 锁 `offset=1e14 → 200 空页`,小上界会让它翻红。
    offset: int = Query(default=0, ge=0, le=MAX_INT64),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> RawEvidenceListOut:
    _check_ledger_access(db, current_user, ledger_id)
    # 永久保留:读时不再删除过期行,过期行正常返回。
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
    # 永久保留:过期行正常返回,不再读时删除/404。
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
    from ...services import raw_evidence_retention as retention_svc

    request = payload or RawEvidenceCleanupRequest()
    source = _validate_source(request.source) if request.source else None
    if request.before is None:
        # 缺省语义 = TTL 清理:只删已过期(expires_at <= now)的行。历史上
        # 缺省 cutoff=now 会把**全部**证据一次删光(captured_at < now 无条件
        # 成立),客户端误发清理请求即不可逆丢失取证数据。显式传 before 才
        # 走按采集时间的窗口删除。
        return {
            "deleted": retention_svc.purge_expired_raw_evidence(
                db, user_id=current_user.id, source=source
            )
        }
    return {
        "deleted": retention_svc.purge_captured_before(
            db, cutoff=_utc(request.before), user_id=current_user.id, source=source
        )
    }
