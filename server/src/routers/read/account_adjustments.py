"""余额调整记录读端点(0028)。

GET /ledgers/{ledger_id}/account-adjustments —— 按账本列调整记录(倒序),
可选 account_id 过滤。调整不进收支统计,这里只服务「调整历史」查看。
"""
from __future__ import annotations

from ._shared import *  # noqa: F401,F403 — imports + helpers + router
from ...models import ReadAccountAdjustmentProjection
from ...schemas import AccountAdjustmentOut


@router.get(
    "/ledgers/{ledger_id}/account-adjustments",
    response_model=list[AccountAdjustmentOut],
)
def list_account_adjustments(
    ledger_id: str,
    account_id: str | None = Query(default=None),
    limit: int = Query(default=200, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
    _scopes: set[str] = Depends(_READ_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[AccountAdjustmentOut]:
    ledger, _ = _require_ledger(
        db,
        user_id=current_user.id,
        ledger_external_id=ledger_id,
        is_admin=_is_admin(current_user),
    )
    stmt = (
        select(ReadAccountAdjustmentProjection)
        .where(ReadAccountAdjustmentProjection.ledger_id == ledger.id)
        .order_by(
            ReadAccountAdjustmentProjection.happened_at.desc(),
            ReadAccountAdjustmentProjection.created_at.desc(),
        )
    )
    if account_id:
        stmt = stmt.where(
            ReadAccountAdjustmentProjection.account_sync_id == account_id
        )
    rows = db.scalars(stmt.offset(offset).limit(limit)).all()
    return [
        AccountAdjustmentOut(
            id=row.sync_id,
            account_id=row.account_sync_id,
            account_name=row.account_name,
            amount=float(row.amount or 0.0),
            balance_before=row.balance_before,
            balance_after=row.balance_after,
            happened_at=row.happened_at,
            created_at=row.created_at,
            note=row.note,
            created_by_user_id=row.created_by_user_id,
        )
        for row in rows
    ]
