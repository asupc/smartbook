"""交易回收站端点(0030 软删安全网)。

- GET  /read/workspace/trash —— 列出当前用户所有账本的软删交易(删除时间
  倒序,含剩余保留天数);
- POST /read/workspace/trash/{sync_id}/restore —— 恢复(deleted_at 置 NULL)
  并重发一条 upsert SyncChange,mobile pull 端自动重建本地行;
- POST /read/workspace/trash/{sync_id}/purge —— 彻底删除(物理删行+附件 GC),
  不可恢复。

权限:restore/purge 需要 tx 所属账本的 owner/editor(与 web 删除一致);
列表读权限与 workspace 其它端点一致。
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone

from fastapi import Header, Request, status
from pydantic import BaseModel

from ._shared import *  # noqa: F401,F403 — imports + helpers + router
from ... import projection
from ...ledger_access import require_accessible_ledger_by_external_id, WRITABLE_ROLES
from ...models import AuditLog, Ledger, ReadTxProjection, SyncChange, User

logger = logging.getLogger(__name__)

# 保留窗口与 data_cleanup cleaner 的过期口径保持一致(30 天)。
TRASH_RETENTION_DAYS = 30


class TrashItemOut(BaseModel):
    sync_id: str
    ledger_id: str  # external id
    ledger_name: str | None = None
    tx_type: str
    amount: float
    happened_at: datetime
    note: str | None = None
    category_name: str | None = None
    account_name: str | None = None
    deleted_at: datetime
    # 距物理清理还有几天(向上取整;0 = 今天内清)
    days_left: int


class TrashListOut(BaseModel):
    items: list[TrashItemOut]
    total: int


class TrashActionOut(BaseModel):
    sync_id: str
    ok: bool
    new_change_id: int | None = None


def _find_trash_row(
    db: Session, user_id: str, sync_id: str
) -> ReadTxProjection | None:
    return db.scalar(
        select(ReadTxProjection).where(
            ReadTxProjection.user_id == user_id,
            ReadTxProjection.sync_id == sync_id,
            ReadTxProjection.deleted_at.is_not(None),
        )
    )


def _ledger_of(db: Session, ledger_id: str) -> Ledger | None:
    return db.scalar(select(Ledger).where(Ledger.id == ledger_id))


@router.get("/workspace/trash", response_model=TrashListOut)
def list_trash(
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TrashListOut:
    base = select(ReadTxProjection).where(
        ReadTxProjection.user_id == current_user.id,
        ReadTxProjection.deleted_at.is_not(None),
    )
    total = db.scalar(select(func.count()).select_from(base.subquery())) or 0
    rows = db.scalars(
        base.order_by(ReadTxProjection.deleted_at.desc())
        .offset(offset)
        .limit(limit)
    ).all()

    # 账本名一次性补齐(账本被删会级联删行,这里的行所属账本一定还在)
    ledger_ids = list({r.ledger_id for r in rows})
    name_map: dict[str, str] = {}
    ext_map: dict[str, str] = {}
    if ledger_ids:
        for lg in db.scalars(select(Ledger).where(Ledger.id.in_(ledger_ids))):
            name_map[lg.id] = lg.name
            ext_map[lg.id] = lg.external_id

    now = datetime.now(timezone.utc)
    items = []
    for r in rows:
        deleted = r.deleted_at
        # SQLite 可能存 naive;补 UTC 再比较
        if deleted.tzinfo is None:
            deleted = deleted.replace(tzinfo=timezone.utc)
        days_left = max(
            0,
            TRASH_RETENTION_DAYS
            - int((now - deleted).total_seconds() // 86400),
        )
        items.append(
            TrashItemOut(
                sync_id=r.sync_id,
                ledger_id=ext_map.get(r.ledger_id, ""),
                ledger_name=name_map.get(r.ledger_id),
                tx_type=r.tx_type,
                amount=float(r.amount or 0.0),
                happened_at=r.happened_at,
                note=r.note,
                category_name=r.category_name,
                account_name=r.account_name,
                deleted_at=deleted,
                days_left=days_left,
            )
        )
    return TrashListOut(items=items, total=int(total))


def _require_writable_ledger(db: Session, user: User, ledger: Ledger) -> None:
    """恢复/彻底删除需要 owner/editor(与 web 删除交易同权限)。"""
    row = require_accessible_ledger_by_external_id(
        db,
        user_id=user.id,
        ledger_external_id=ledger.external_id,
        roles=WRITABLE_ROLES,
    )
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"message": "No permission to modify trash", "error_code": "LEDGER_FORBIDDEN"},
        )


@router.post(
    "/workspace/trash/{sync_id}/restore",
    response_model=TrashActionOut,
)
def restore_trash_tx(
    sync_id: str,
    request: Request,
    device_id: str = Header(default="web-console", alias="X-Device-ID"),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TrashActionOut:
    row = _find_trash_row(db, current_user.id, sync_id)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "message": "Transaction not found in trash",
                "error_code": "TRASH_TX_NOT_FOUND",
            },
        )
    ledger = _ledger_of(db, row.ledger_id)
    if ledger is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Ledger not found"
        )
    _require_writable_ledger(db, current_user, ledger)

    restored = projection.restore_tx(db, ledger_id=row.ledger_id, sync_id=sync_id)
    new_change_id: int | None = None
    if restored:
        # 重发 upsert change:mobile 端 pull 后重建本地行(即使本地 tombstone
        # 已应用,upsert payload 会覆盖)。payload 用软删期间保留的投影行。
        from ..write._shared import _projection_row_to_tx_dict
        now = datetime.now(timezone.utc)
        change = SyncChange(
            user_id=ledger.user_id,
            ledger_id=ledger.id,
            entity_type="transaction",
            entity_sync_id=sync_id,
            action="upsert",
            payload_json=_projection_row_to_tx_dict(row),
            updated_at=now,
            updated_by_device_id=device_id,
            updated_by_user_id=current_user.id,
        )
        db.add(change)
        db.flush()
        new_change_id = int(change.change_id)
        db.add(
            AuditLog(
                user_id=current_user.id,
                ledger_id=ledger.id,
                action="tx_restore_from_trash",
                metadata_json={"syncId": sync_id, "newChangeId": new_change_id},
            )
        )
    db.commit()
    if new_change_id is not None:
        # 共享账本 fan-out,让在线端立即收到恢复
        from ...websocket_manager import broadcast_to_ledger
        try:
            import asyncio

            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if loop is not None:
            loop.create_task(
                broadcast_to_ledger(
                    db=None,
                    ws_manager=request.app.state.ws_manager,
                    ledger_id=ledger.id,
                    payload={
                        "type": "sync_change",
                        "ledgerId": ledger.external_id,
                        "serverCursor": new_change_id,
                        "serverTimestamp": datetime.now(timezone.utc).isoformat(),
                    },
                )
            )
    logger.info(
        "tx.restore_from_trash ledger=%s sync_id=%s change_id=%s user=%s",
        ledger.external_id, sync_id, new_change_id, current_user.id,
    )
    return TrashActionOut(sync_id=sync_id, ok=restored, new_change_id=new_change_id)


@router.post(
    "/workspace/trash/{sync_id}/purge",
    response_model=TrashActionOut,
)
def purge_trash_tx(
    sync_id: str,
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TrashActionOut:
    row = _find_trash_row(db, current_user.id, sync_id)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "message": "Transaction not found in trash",
                "error_code": "TRASH_TX_NOT_FOUND",
            },
        )
    ledger = _ledger_of(db, row.ledger_id)
    if ledger is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Ledger not found"
        )
    _require_writable_ledger(db, current_user, ledger)

    # 物理删除:先收集附件引用,删行,再 GC 孤立附件(共享引用保留)。
    tx_file_ids = projection.collect_tx_attachment_fileids(
        db, ledger_id=ledger.id, sync_id=sync_id,
    )
    projection.purge_tx(db, ledger_id=ledger.id, sync_id=sync_id)
    projection.gc_orphan_attachments_for_ledger(
        db, ledger_id=ledger.id, file_ids=tx_file_ids,
    )
    # tombstone change 已在删除时发过;purge 不再发(客户端本地已删)。
    db.add(
        AuditLog(
            user_id=current_user.id,
            ledger_id=ledger.id,
            action="tx_purge_from_trash",
            metadata_json={"syncId": sync_id},
        )
    )
    db.commit()
    logger.info(
        "tx.purge_from_trash ledger=%s sync_id=%s user=%s",
        ledger.external_id, sync_id, current_user.id,
    )
    return TrashActionOut(sync_id=sync_id, ok=True)
