"""POST /api/v1/write/ledgers/{ledger_id}/transactions/batch/move — 批量把交易移到目标分类。

设计:mirror transactions_batch_delete.py(单 snapshot lock + 一次 SyncChange
broadcast + 一次 idempotency),区别:

- 跑 `snapshot_mutator.update_transaction`(逐个 sync_id),payload 同时传
  category_id / category_name / category_kind 三项,避免只传 category_id
  留下陈旧 categoryName/categoryKind denorm 字段。
- 目标分类存在性**预校验**:先确认 target_category_id 在快照 categories 里
  存在,再进入循环 mutate;不存在直接整体 422,避免"移到一半目标没了"。
- 部分失败按 tx 粒度返回 `failed[]`,只在事务级错误才 500。
- 与 batch_delete 一样不开放 base_change_id 严格校验(用户多选时不应被并发
  其它写入卡死)。
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ... import snapshot_builder
from ...concurrency import lock_ledger_for_materialize
from ...database import get_db
from ...deps import get_current_user
from ...models import AuditLog, SyncPushIdempotency, User
from ...snapshot_mutator import update_transaction
from ._shared import (
    _TRANSACTION_WRITE_ROLES,
    _WRITE_RESPONSES,
    _WRITE_SCOPE_DEP,
    _emit_entity_diffs,
    _hash_request,
    _load_idempotent_response,
    _payload_with_actor,
    _prepare_write,
)

logger = logging.getLogger(__name__)
router = APIRouter()


class BatchTxMoveRequest(BaseModel):
    tx_ids: list[str] = Field(..., min_length=1, max_length=200)
    target_category_id: str
    base_change_id: int = 0


class BatchTxFailure(BaseModel):
    tx_id: str
    reason: Literal[
        "not_found", "permission_denied", "conflict", "invalid_target_category"
    ]
    message: str | None = None


class BatchTxMoveResponse(BaseModel):
    ledger_id: str
    base_change_id: int
    new_change_id: int
    server_timestamp: datetime
    moved_tx_ids: list[str] = Field(default_factory=list)
    failed: list[BatchTxFailure] = Field(default_factory=list)


def _find_category_in_snapshot(
    snapshot: dict, category_id: str
) -> dict | None:
    """在快照 categories 里按 syncId 找目标分类,返回 {syncId,name,kind}。"""
    normalized = category_id.strip()
    for cat in snapshot.get("categories") or []:
        if str(cat.get("syncId")) == normalized:
            return cat
    return None


@router.post(
    "/ledgers/{ledger_id}/transactions/batch/move",
    response_model=BatchTxMoveResponse,
    responses=_WRITE_RESPONSES,
)
async def move_tx_batch(
    ledger_id: str,
    req: BatchTxMoveRequest,
    request: Request,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    device_id: str = Header(default="web-console", alias="X-Device-ID"),
    _scopes: set[str] = Depends(_WRITE_SCOPE_DEP),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> BatchTxMoveResponse:
    payload_for_ide = req.model_dump(mode="json")
    ledger, replay = _prepare_write(
        db=db,
        current_user=current_user,
        ledger_external_id=ledger_id,
        required_roles=_TRANSACTION_WRITE_ROLES,
        idempotency_key=idempotency_key,
        device_id=device_id,
        method=request.method,
        path=request.url.path,
        payload=payload_for_ide,
    )
    if replay:
        row = db.scalar(
            select(SyncPushIdempotency).where(
                SyncPushIdempotency.user_id == current_user.id,
                SyncPushIdempotency.device_id == device_id,
                SyncPushIdempotency.idempotency_key == idempotency_key,
            )
        )
        if row is not None and row.response_json:
            return BatchTxMoveResponse.model_validate(row.response_json)
        return BatchTxMoveResponse(
            ledger_id=ledger.external_id,
            base_change_id=req.base_change_id,
            new_change_id=replay.new_change_id,
            server_timestamp=replay.server_timestamp,
            moved_tx_ids=[],
            failed=[],
        )

    # 去重 —— 同一 sync_id 只 move 一次
    unique_ids: list[str] = []
    seen: set[str] = set()
    for tx_id in req.tx_ids:
        if tx_id and tx_id not in seen:
            unique_ids.append(tx_id)
            seen.add(tx_id)

    lock_ledger_for_materialize(db, ledger.id)
    snapshot = snapshot_builder.build(db, ledger)

    # 预校验目标分类存在且属可归类 kind(expense/income)。分类是 user-global,
    # 但写入时需要 name/kind 同时下发给 transaction(denorm),故从快照取。
    target = _find_category_in_snapshot(snapshot, req.target_category_id)
    if target is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "error": "write validation failed",
                "message": f"target category {req.target_category_id} not found in ledger",
                "reason": "invalid_target_category",
            },
        )
    target_kind = str(target.get("kind") or "").strip()
    if target_kind not in {"expense", "income", "transfer"}:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "error": "write validation failed",
                "message": f"target category {req.target_category_id} has invalid kind",
                "reason": "invalid_target_category",
            },
        )

    # 深拷贝快照用于 diff(跟 batch_delete 同模式)
    prev_snapshot = {**snapshot}
    for _k in ("items", "accounts", "categories", "tags", "budgets"):
        arr = snapshot.get(_k)
        if isinstance(arr, list):
            prev_snapshot[_k] = [dict(e) if isinstance(e, dict) else e for e in arr]

    # 循环 mutate;单个 tx 报错 → 记 failed 继续。事务级错误不在这里捕获。
    moved_ids: list[str] = []
    failed: list[BatchTxFailure] = []
    # 三项同传,避免只传 category_id 留下陈旧 categoryName/categoryKind。
    move_payload = _payload_with_actor(
        {
            "category_id": req.target_category_id,
            "category_name": str(target.get("name") or ""),
            "category_kind": target_kind,
        },
        current_user,
        ledger=ledger,
    )

    for tx_id in unique_ids:
        try:
            snapshot = update_transaction(snapshot, tx_id, move_payload)
            moved_ids.append(tx_id)
        except KeyError:
            # _find_by_sync_id 抛 KeyError → tx 不在 snapshot(已删 / ID 错 / 跨 ledger)
            failed.append(
                BatchTxFailure(tx_id=tx_id, reason="not_found", message="transaction not in ledger")
            )
        except PermissionError as exc:
            failed.append(
                BatchTxFailure(tx_id=tx_id, reason="permission_denied", message=str(exc))
            )
        except ValueError as exc:
            # snapshot_mutator 在 sync_id prefix 不对 / 其它校验失败时抛
            failed.append(BatchTxFailure(tx_id=tx_id, reason="conflict", message=str(exc)))

    # diff + emit changes(只针对实际变更的 items)
    now = datetime.now(timezone.utc)
    if moved_ids:
        emitted_change_ids = _emit_entity_diffs(
            db,
            ledger=ledger,
            current_user=current_user,
            device_id=device_id,
            prev=prev_snapshot,
            next_snapshot=snapshot,
            now=now,
        )
        new_change_id = max(emitted_change_ids) if emitted_change_ids else (
            snapshot_builder.latest_change_id(db, ledger.id)
        )
    else:
        new_change_id = snapshot_builder.latest_change_id(db, ledger.id)

    db.add(
        AuditLog(
            user_id=current_user.id,
            ledger_id=ledger.id,
            action="web_tx_batch_move",
            metadata_json={
                "ledgerId": ledger.external_id,
                "targetCategoryId": req.target_category_id,
                "targetCategoryName": target.get("name"),
                "baseChangeId": req.base_change_id,
                "newChangeId": new_change_id,
                "movedCount": len(moved_ids),
                "movedIds": moved_ids,
                "failedCount": len(failed),
                "failedIds": [f.tx_id for f in failed],
            },
        )
    )

    response = BatchTxMoveResponse(
        ledger_id=ledger.external_id,
        base_change_id=req.base_change_id,
        new_change_id=new_change_id,
        server_timestamp=now,
        moved_tx_ids=moved_ids,
        failed=failed,
    )

    request_hash = _hash_request(request.method, request.url.path, payload_for_ide)
    if idempotency_key:
        db.add(
            SyncPushIdempotency(
                user_id=current_user.id,
                device_id=device_id,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                response_json=response.model_dump(mode="json"),
                created_at=now,
                expires_at=now + timedelta(hours=24),
            )
        )

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        if idempotency_key:
            replay = _load_idempotent_response(
                db,
                user_id=current_user.id,
                device_id=device_id,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
            )
            if replay is not None:
                return BatchTxMoveResponse(**replay.model_dump()) if hasattr(replay, "model_dump") else replay  # type: ignore[return-value]
        raise

    logger.info(
        "tx.batch_move ledger=%s target=%s moved=%d failed=%d change_id=%d device=%s user=%s",
        ledger.external_id, req.target_category_id, len(moved_ids), len(failed),
        new_change_id, device_id, current_user.id,
    )

    if moved_ids:
        # 共享账本:fan-out 给所有 LedgerMember,Editor 端 mobile 实时收到。
        from ...websocket_manager import broadcast_to_ledger
        await broadcast_to_ledger(
            db=db,
            ws_manager=request.app.state.ws_manager,
            ledger_id=ledger.id,
            payload={
                "type": "sync_change",
                "ledgerId": ledger.external_id,
                "serverCursor": new_change_id,
                "serverTimestamp": now.isoformat(),
            },
        )
    return response
