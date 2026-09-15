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

# S10 新增 helper 用到的 star-import 符号在此显式导入(同对象,消除新增 F405)
from fastapi import Header, HTTPException, Query, Request, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from ... import projection
from ...ledger_access import (
    WRITABLE_ROLES,
    get_accessible_ledger_ids,
    require_accessible_ledger_by_external_id,
)
from ...models import AuditLog, Ledger, ReadTxProjection, SyncChange, User
from ._shared import *  # noqa: F401,F403 — imports + helpers + router

logger = logging.getLogger(__name__)

# 保留窗口与 data_cleanup cleaner 的过期清算口径保持一致(30 天)。
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
    # S10:本次操作命中的账本(external id)—— sync_id 只在账本内唯一,
    # 跨账本同名时 caller 用 ledger_id 参数消歧,响应回带实际账本。
    ledger_id: str | None = None


def _accessible_trash_rows(
    db: Session,
    user_id: str,
    sync_id: str,
    *,
    ledger_int_id: str | None = None,
) -> list[ReadTxProjection]:
    """按表 PK 语义查回收站行(S10)。

    旧实现按 ``user_id == caller`` 过滤 —— 共享账本的 tx 投影行 user_id 是
    ledger owner,Editor 删除的交易自己查不到/恢复不了;且 PK 是
    ``(ledger_id, sync_id)``,跨账本同 sync_id 时旧行为会静默命中不确定的
    一行。现改为「caller 可访问账本集合 ∩ sync_id」,可选 ledger_int_id
    收敛到单账本。"""
    conds: list[object] = [
        ReadTxProjection.sync_id == sync_id,
        ReadTxProjection.deleted_at.is_not(None),
        ReadTxProjection.ledger_id.in_(
            get_accessible_ledger_ids(db, user_id=user_id)
        ),
    ]
    if ledger_int_id is not None:
        conds.append(ReadTxProjection.ledger_id == ledger_int_id)
    return list(db.scalars(select(ReadTxProjection).where(*conds)).all())


def _resolve_trash_row_for_action(
    db: Session,
    current_user: User,
    sync_id: str,
    ledger_external_id: str | None,
) -> tuple[ReadTxProjection, Ledger]:
    """restore/purge 共用:定位唯一目标行(按可访问账本集合 + 可选账本消歧)。

    - 0 行 → 404;
    - 多行且未传 ledger_id → 409(列出候选账本,让前端让用户选);
    - 多行且传了 ledger_id → 按 (ledger_id, sync_id) PK 唯一收敛;
    - 传了 ledger_id 但其中无该行 → 404。"""
    ledger_int_id: str | None = None
    if ledger_external_id:
        ledger_int_id = db.scalar(
            select(Ledger.id).where(Ledger.external_id == ledger_external_id)
        )
        if ledger_int_id is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="Ledger not found"
            )
    rows = _accessible_trash_rows(
        db, current_user.id, sync_id, ledger_int_id=ledger_int_id
    )
    if not rows:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "message": "Transaction not found in trash",
                "error_code": "TRASH_TX_NOT_FOUND",
            },
        )
    if len(rows) > 1:
        # 同 sync_id 在多个可访问账本 —— 不再静默取第一行(可能操作错账本)。
        candidates = [
            lg.external_id
            for lg in db.scalars(
                select(Ledger).where(Ledger.id.in_([r.ledger_id for r in rows]))
            )
        ]
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": "sync_id exists in multiple accessible ledgers; "
                "pass ledger_id to disambiguate",
                "error_code": "TRASH_TX_AMBIGUOUS",
                "ledger_ids": candidates,
            },
        )
    row = rows[0]
    ledger = db.scalar(select(Ledger).where(Ledger.id == row.ledger_id))
    if ledger is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Ledger not found"
        )
    return row, ledger


@router.get("/workspace/trash", response_model=TrashListOut)
def list_trash(
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TrashListOut:
    # S10:按「可访问账本集合」而非 user_id 过滤 —— 共享账本 tx 投影行的
    # user_id 是 owner,Editor 删除的交易也要出现在自己的回收站里。
    base = select(ReadTxProjection).where(
        ReadTxProjection.ledger_id.in_(
            get_accessible_ledger_ids(db, user_id=current_user.id)
        ),
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


def _fanout_restore_ws(
    request: Request,
    member_user_ids: list[str],
    payload: dict,
) -> None:
    """把 trash 恢复通知广播给账本全部成员(P1-B1)。

    本路由是同步 def(FastAPI 跑线程池),worker 线程里没有 running loop ——
    旧实现在这里 `asyncio.get_running_loop()` 必抛 RuntimeError 被 catch,
    广播 task 从未被创建(实时通知从未生效)。改为与 backup scheduler 的
    WS progress 同款:经 run_coroutine_threadsafe 推回主 loop
    (app.state.main_loop,由 main.py 的 backup scheduler startup 设置)。

    member 列表在 **commit 前**由 caller 查出(本函数不碰 db —— 请求
    Session commit 后再开查询会重新开事务,而线程池里也没有 loop 能跑
    async broadcast_to_ledger);广播本身在 commit 后发,与 write/push 的
    「commit 后广播」模式对齐。main loop 不可用(未起 lifespan 的测试 /
    极早期)时跳过并留痕,不吞其它异常。
    """
    import asyncio

    loop = getattr(request.app.state, "main_loop", None)
    if loop is None or loop.is_closed():
        logger.warning(
            "tx.restore fanout skipped: main loop unavailable (lifespan not started?)"
        )
        return
    ws_manager = request.app.state.ws_manager
    for uid in member_user_ids:
        asyncio.run_coroutine_threadsafe(
            ws_manager.broadcast_to_user(uid, payload), loop,
        )


@router.post(
    "/workspace/trash/{sync_id}/restore",
    response_model=TrashActionOut,
)
def restore_trash_tx(
    sync_id: str,
    request: Request,
    device_id: str = Header(default="web-console", alias="X-Device-ID"),
    ledger_id: str | None = Query(
        default=None,
        description="跨账本同 sync_id 时用于消歧(external id);单命中时可省",
    ),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TrashActionOut:
    row, ledger = _resolve_trash_row_for_action(db, current_user, sync_id, ledger_id)
    _require_writable_ledger(db, current_user, ledger)

    restored = projection.restore_tx(db, ledger_id=row.ledger_id, sync_id=sync_id)
    new_change_id: int | None = None
    member_user_ids: list[str] = []
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
        # commit 前把成员列表查出(见 _fanout_restore_ws 说明);commit 后
        # 逐成员 broadcast_to_user。
        from ...ledger_access import list_ledger_members

        member_user_ids = [
            uid for uid, _role in list_ledger_members(db, ledger_id=ledger.id)
        ]
    db.commit()
    if new_change_id is not None:
        # 共享账本 fan-out,让在线端立即收到恢复
        _fanout_restore_ws(
            request,
            member_user_ids,
            {
                "type": "sync_change",
                "ledgerId": ledger.external_id,
                "serverCursor": new_change_id,
                "serverTimestamp": datetime.now(timezone.utc).isoformat(),
            },
        )
    logger.info(
        "tx.restore_from_trash ledger=%s sync_id=%s change_id=%s user=%s",
        ledger.external_id, sync_id, new_change_id, current_user.id,
    )
    return TrashActionOut(
        sync_id=sync_id,
        ok=restored,
        new_change_id=new_change_id,
        ledger_id=ledger.external_id,
    )


@router.post(
    "/workspace/trash/{sync_id}/purge",
    response_model=TrashActionOut,
)
def purge_trash_tx(
    sync_id: str,
    ledger_id: str | None = Query(
        default=None,
        description="跨账本同 sync_id 时用于消歧(external id);单命中时可省",
    ),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TrashActionOut:
    row, ledger = _resolve_trash_row_for_action(db, current_user, sync_id, ledger_id)
    _require_writable_ledger(db, current_user, ledger)

    # 物理删除:先收集附件引用,删行,再 GC 孤立附件(共享引用保留)。
    tx_file_ids = projection.collect_tx_attachment_fileids(
        db, ledger_id=ledger.id, sync_id=sync_id,
    )
    projection.purge_tx(db, ledger_id=ledger.id, sync_id=sync_id)
    projection.gc_orphan_attachments_for_ledger(
        db, ledger_id=ledger.id, file_ids=tx_file_ids,
    )
    # 物理删除后 compact 该交易的 upsert 事件历史(P1-A3,与 data_cleanup
    # cleaner 的过期清理同款);delete 墓碑保留,落后设备仍能 apply 删除。
    from ...sync_applier import _compact_entity_upsert_events

    _compact_entity_upsert_events(
        db, user_id=row.user_id, entity_type="transaction", entity_sync_id=sync_id,
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
    return TrashActionOut(sync_id=sync_id, ok=True, ledger_id=ledger.external_id)
