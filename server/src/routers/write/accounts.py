"""Accounts write endpoints.

POST / PATCH / DELETE for /ledgers/{ledger_id}/accounts(ledgers 自身除外)。
依赖 `._shared` 里的 _commit_write_fast_entity / _prepare_write / normalize
helper / WRITE 响应表。Endpoint 自身只管参数校验 + mutate lambda 的构造。

全部走小实体快路径(F1):不 build 全量 items,改名级联由 rename_cascade_*
SQL + 定向 cascade SyncChange 补发处理,成本 O(1)。
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status

from ._shared import *  # noqa: F401,F403 — 集中从 _shared 取所有 symbol

router = APIRouter()


def _cascade_items_for_account_delete(db, current_user, account_id: str):
    """删除账户前定向点查关联交易(精确 sync_id 谓词,与 mutator 关联校验
    一致),喂给快路径做 in-use 校验。None = 仍走全量路径(老数据兜底)。"""
    rows = _cascade_tx_rows_for_account(
        db, user_id=current_user.id, account_sync_id=account_id,
    )
    # 行上三个 account id 列全 NULL 的老数据走名字匹配 → 退化全量路径。
    for r in rows:
        if (
            r.account_sync_id is None
            and r.from_account_sync_id is None
            and r.to_account_sync_id is None
        ):
            return None, None
    return rows, rows


@router.post(
    "/ledgers/{ledger_id}/accounts",
    response_model=WriteCommitMeta,
    responses=_WRITE_RESPONSES,
)
async def create_acc(
    ledger_id: str,
    req: WriteAccountCreateRequest,
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
        required_roles=_OWNER_ONLY_ROLES,
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
        audit_action="web_account_create",
        entity_type="account",
        entity_sync_id=None,
        mutate=lambda snapshot: create_account(snapshot, mutate_payload),
    )


@router.patch(
    "/ledgers/{ledger_id}/accounts/{account_id}",
    response_model=WriteCommitMeta,
    responses=_WRITE_RESPONSES,
)
async def update_acc(
    ledger_id: str,
    account_id: str,
    req: WriteAccountUpdateRequest,
    request: Request,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    device_id: str = Header(default="web-console", alias="X-Device-ID"),
    _scopes: set[str] = Depends(_WRITE_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> WriteCommitMeta:
    payload = req.model_dump(mode="json", exclude_unset=True)
    ledger, replay = _prepare_write(
        db=db,
        current_user=current_user,
        ledger_external_id=ledger_id,
        required_roles=_OWNER_ONLY_ROLES,
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
        audit_action="web_account_update",
        entity_type="account",
        entity_sync_id=account_id,
        mutate=lambda snapshot: (update_account(snapshot, account_id, mutate_payload), account_id),
    )


@router.delete(
    "/ledgers/{ledger_id}/accounts/{account_id}",
    response_model=WriteCommitMeta,
    responses=_WRITE_RESPONSES,
)
async def delete_acc(
    ledger_id: str,
    account_id: str,
    req: WriteEntityDeleteRequest,
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
        required_roles=_OWNER_ONLY_ROLES,
        idempotency_key=idempotency_key,
        device_id=device_id,
        method=request.method,
        path=request.url.path,
        payload=payload,
    )
    if replay:
        return replay
    mutate_payload = _payload_with_actor(payload, current_user, ledger=ledger)
    cascade_rows, cascade_items = _cascade_items_for_account_delete(
        db, current_user, account_id,
    )
    if cascade_items is None:
        # 老数据(id 列缺失)回退全量路径 —— mutator 的名字匹配校验需要全量 items。
        return await _commit_write(
            request=request,
            db=db,
            current_user=current_user,
            ledger=ledger,
            base_change_id=req.base_change_id,
            request_payload=payload,
            idempotency_key=idempotency_key,
            device_id=device_id,
            audit_action="web_account_delete",
            mutate=lambda snapshot: (delete_account(snapshot, account_id, mutate_payload), account_id),
        )
    return await _commit_write_fast_entity(
        request=request,
        db=db,
        current_user=current_user,
        ledger=ledger,
        base_change_id=req.base_change_id,
        request_payload=payload,
        idempotency_key=idempotency_key,
        device_id=device_id,
        audit_action="web_account_delete",
        entity_type="account",
        entity_sync_id=account_id,
        mutate=lambda snapshot: (delete_account(snapshot, account_id, mutate_payload), account_id),
        cascade_tx_items=cascade_items,
    )
