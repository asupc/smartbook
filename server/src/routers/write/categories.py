"""Categories write endpoints.

POST / PATCH / DELETE for /ledgers/{ledger_id}/categories(ledgers 自身除外)。
依赖 `._shared` 里的 _commit_write_fast_entity / _prepare_write / normalize
helper / WRITE 响应表。Endpoint 自身只管参数校验 + mutate lambda 的构造。

全部走小实体快路径(F1):不 build 全量 items;DELETE 前定向点查本分类 +
子分类的关联交易喂给 mutator 做家族 in-use 校验(精确 kind+name 谓词,
与 mutator 循环一致)。
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from sqlalchemy import or_, select as sa_select

from ._shared import *  # noqa: F401,F403 — 集中从 _shared 取所有 symbol
from ...models import ReadTxProjection, UserCategoryProjection

router = APIRouter()


def _cascade_items_for_category_delete(db, current_user, ledger, category_id: str):
    """删除分类前定向点查「本分类 + 子分类家族」的关联交易,喂给快路径做
    mutator 的 tx_count 校验。None = 仍走全量路径(老数据兜底)。

    谓词与 snapshot_mutator.delete_category 完全一致:kind 相同 + name 落在
    family_names(本分类名 + 同 kind 直接子分类名)。"""
    cat = db.scalar(
        sa_select(UserCategoryProjection).where(
            UserCategoryProjection.user_id == current_user.id,
            UserCategoryProjection.sync_id == category_id,
        )
    )
    if cat is None or not (cat.name or "").strip() or not (cat.kind or "").strip():
        return None
    old_name = (cat.name or "").strip()
    old_kind = (cat.kind or "").strip()
    children = db.scalars(
        sa_select(UserCategoryProjection).where(
            UserCategoryProjection.user_id == current_user.id,
            UserCategoryProjection.sync_id != category_id,
            UserCategoryProjection.parent_name == old_name,
            UserCategoryProjection.kind == old_kind,
        )
    ).all()
    family_names = {old_name}
    for row in children:
        child_name = (row.name or "").strip()
        if child_name:
            family_names.add(child_name)
    rows = db.scalars(
        sa_select(ReadTxProjection).where(
            ReadTxProjection.user_id == current_user.id,
            ReadTxProjection.category_kind == old_kind,
            ReadTxProjection.category_name.in_(list(family_names)),
        )
    ).all()
    return list(rows)


@router.post(
    "/ledgers/{ledger_id}/categories",
    response_model=WriteCommitMeta,
    responses=_WRITE_RESPONSES,
)
async def create_cat(
    ledger_id: str,
    req: WriteCategoryCreateRequest,
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
        audit_action="web_category_create",
        entity_type="category",
        entity_sync_id=None,
        mutate=lambda snapshot: create_category(snapshot, mutate_payload),
    )


@router.patch(
    "/ledgers/{ledger_id}/categories/{category_id}",
    response_model=WriteCommitMeta,
    responses=_WRITE_RESPONSES,
)
async def update_cat(
    ledger_id: str,
    category_id: str,
    req: WriteCategoryUpdateRequest,
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
        audit_action="web_category_update",
        entity_type="category",
        entity_sync_id=category_id,
        mutate=lambda snapshot: (update_category(snapshot, category_id, mutate_payload), category_id),
    )


@router.delete(
    "/ledgers/{ledger_id}/categories/{category_id}",
    response_model=WriteCommitMeta,
    responses=_WRITE_RESPONSES,
)
async def delete_cat(
    ledger_id: str,
    category_id: str,
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
    cascade_items = _cascade_items_for_category_delete(
        db, current_user, ledger, category_id,
    )
    if cascade_items is None:
        return await _commit_write(
            request=request,
            db=db,
            current_user=current_user,
            ledger=ledger,
            base_change_id=req.base_change_id,
            request_payload=payload,
            idempotency_key=idempotency_key,
            device_id=device_id,
            audit_action="web_category_delete",
            mutate=lambda snapshot: (delete_category(snapshot, category_id, mutate_payload), category_id),
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
        audit_action="web_category_delete",
        entity_type="category",
        entity_sync_id=category_id,
        mutate=lambda snapshot: (delete_category(snapshot, category_id, mutate_payload), category_id),
        cascade_tx_items=cascade_items,
    )
