"""Account adjustment write endpoints(余额调整记录,0028)。

POST for /ledgers/{ledger_id}/account-adjustments。「调整余额」不再
落一笔 exclude_from_stats 交易,而是独立 ledger-scope 实体 account_adjustment:
不进收支统计 / 预算 / 分类排行,只参与账户余额与净资产口径。

调整记录是对账审计数据,**append-only**:不提供 DELETE(记错反向再调一笔)。
sync_applier 侧的 delete dispatch 保留作防御(旧客户端 push delete 不炸),
web 写路径没有删除通道。

Create 走小实体快路径(F1,_commit_write_fast_entity)—— accountAdjustments[]
是独立实体数组,不涉及 items,无需全量 snapshot。
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Header, Request

from ._shared import *  # noqa: F401,F403 — 集中从 _shared 取所有 symbol
from ...schemas import WriteAccountAdjustmentCreateRequest
from ...snapshot_mutator import (
    create_account_adjustment as _mutate_create_adjustment,
)

router = APIRouter()


@router.post(
    "/ledgers/{ledger_id}/account-adjustments",
    response_model=WriteCommitMeta,
    responses=_WRITE_RESPONSES,
)
async def create_account_adjustment(
    ledger_id: str,
    req: WriteAccountAdjustmentCreateRequest,
    request: Request,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    device_id: str = Header(default="web-console", alias="X-Device-ID"),
    _scopes: set[str] = Depends(_WRITE_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> WriteCommitMeta:
    payload = req.model_dump(mode="json")
    ledger, replay = _prepare_write(
        db=db,
        current_user=current_user,
        ledger_external_id=ledger_id,
        required_roles=_TRANSACTION_WRITE_ROLES,
        idempotency_key=idempotency_key,
        device_id=device_id,
        method=request.method,
        path=request.url.path,
        payload=payload,
    )
    if replay:
        return replay
    mutate_payload = _payload_with_actor(payload, current_user, ledger=ledger)
    return await _commit_write_fast_entity(
        request=request,
        db=db,
        current_user=current_user,
        ledger=ledger,
        base_change_id=req.base_change_id,
        request_payload=payload,
        idempotency_key=idempotency_key,
        device_id=device_id,
        audit_action="web_account_adjustment_create",
        entity_type="account_adjustment",
        entity_sync_id=None,
        mutate=lambda snapshot: _mutate_create_adjustment(snapshot, mutate_payload),
    )
