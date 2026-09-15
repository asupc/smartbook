"""POST /sync/push —— mobile 批量推送本地变更。

每条 change:LWW 决胜(updated_at + device_id tie-break)→ 写 SyncChange 行
→ 走 sync_applier.apply_change_to_projection 刷 projection。整批单事务
提交,一条坏 change 炸会带 traceback 日志并 rollback 整批。

P1-C1(2026-09):批处理核心(同步 DB 部分)经 ``run_in_threadpool`` 跑在
worker 线程,大批推送不再阻塞 event loop(WS 心跳 / 健康检查);与 write 路径
(issue #31 A2)同款模式 —— WS 广播留在 loop 上。advisory 锁(user→ledger 顺序,
§4.7)是事务级的:取锁与 apply 与 commit 都在同一个 worker 线程的同一个
session/事务里,不跨连接。
"""
from __future__ import annotations

import time

from starlette.concurrency import run_in_threadpool

from ...concurrency import lock_user_global
from ._shared import *  # noqa: F401,F403 — 拉取所有 imports / helpers / router / constants


def _user_global_prev_name(
    db: Session, *, user_id: str, entity_type: str, sync_id: str,
) -> str | None:
    """取 user-global entity 当前投影名(必须在 apply 之前调用,rename
    探测用)。entity_type 非 account/category/tag 或行不存在 → None。"""
    from ...models import (
        UserAccountProjection,
        UserCategoryProjection,
        UserTagProjection,
    )

    model = {
        "account": UserAccountProjection,
        "category": UserCategoryProjection,
        "tag": UserTagProjection,
    }.get(entity_type)
    if model is None:
        return None
    name = db.scalar(
        select(model.name).where(
            model.user_id == user_id,
            model.sync_id == sync_id,
        )
    )
    return (name or "").strip() or None


def _emit_user_global_cascade_tx_changes(
    db: Session,
    *,
    actor_user_id: str,
    device_id: str,
    updated_at: datetime,
    entity_type: str,
    entity_sync_id: str,
) -> None:
    """user-global rename 后补发 cascade-only tx SyncChange(push 路径)。

    与 web 快路径 write/_shared._emit_cascade_tx_changes 同语义:投影已由
    rename_cascade_* SQL 刷过,这里按 sync_id 稳定 FK 点查受影响 tx 行,
    bulk insert ledger-scope upsert 事件 —— 落后设备(含共享账本 owner)
    pull 后刷新本地 denorm 列。owner 拉不到 Editor 的 scope=user 改名事件
    (pull 按 user 过滤),没有这路补发的话 owner 端 mobile 永远旧名
    (P0-1)。软删行不补发:cascade upsert 会让 mobile 按重建已删交易。
    """
    from sqlalchemy import insert as sa_insert

    from ... import projection as _projection
    from ..write._shared import _projection_row_to_tx_dict

    if entity_type == "account":
        rows = _projection.cascade_tx_rows_for_account(db, account_sync_id=entity_sync_id)
    elif entity_type == "category":
        rows = _projection.cascade_tx_rows_for_category(db, category_sync_id=entity_sync_id)
    elif entity_type == "tag":
        rows = _projection.cascade_tx_rows_for_tag(db, tag_sync_id=entity_sync_id)
    else:
        return
    bulk_rows = []
    for r in rows:
        payload = _projection_row_to_tx_dict(r)
        bulk_rows.append({
            # tx 投影行的 user_id 是 ledger owner(denorm);真实操作者身份在
            # updated_by_user_id。与 ledger-scope 分支的 row_change 约定一致。
            "user_id": r.user_id,
            "ledger_id": r.ledger_id,
            "scope": "ledger",
            "entity_type": "transaction",
            "entity_sync_id": r.sync_id,
            "action": "upsert",
            "payload_json": payload,
            "updated_at": updated_at,
            "updated_by_device_id": device_id,
            "updated_by_user_id": actor_user_id,
        })
    if bulk_rows:
        db.execute(sa_insert(SyncChange), bulk_rows)
        logger.info(
            "sync.push.cascade_fanout entity=%s sync_id=%s tx_rows=%d",
            entity_type, entity_sync_id, len(bulk_rows),
        )


# ---------------------------------------------------------------------------
# P1-E1:首绑判据 / 被移除成员拒绝
# ---------------------------------------------------------------------------

def _device_has_pushed_before(db: Session, *, device_id: str) -> bool:
    """不可变事实:该 device 是否推送过任何 SyncChange。

    旧判据 ``device.last_seen_at is not None`` 是死代码 —— 请求开头就赋值,
    且 models 创建即有 default,三重保证恒非 None。SyncChange 存在性不受
    请求自身影响(本请求的行在循环里才写),在赋 last_seen_at 之前或之后
    查都等价,但语义上必须在批处理前判定一次。
    """
    return db.scalar(
        select(SyncChange.change_id)
        .where(SyncChange.updated_by_device_id == device_id)
        .limit(1)
    ) is not None


def _has_past_membership_evidence(
    db: Session, *, user_id: str, ledger_external_id: str,
) -> bool:
    """caller 是否**曾是**该 external_id 账本的成员(现已不是)。

    证据二选一(都针对该 external_id 的全部账本行 —— external_id 只在
    (user_id, external_id) 上唯一,可能多用户同名):
      1. LedgerInvite.used_by == caller —— 接受过该账本的邀请(Phase 1 成为
         Editor 的唯一入口;被移除/账本被删后邀请使用记录保留);
      2. SyncChange.updated_by_user_id == caller on that ledger —— 曾向该账本
         推过变更(只有成员能推;账本删除会清历史,此路主要覆盖被移除场景)。

    命中 → 该 external_id 对 caller 是「失去资格的旧账本」,push 必须显式拒绝,
    而不是 auto-create 在 caller 名下静默重建私有账本(数据分裂,P1-E1)。
    """
    from ...models import LedgerInvite

    ledger_ids = db.scalars(
        select(Ledger.id).where(Ledger.external_id == ledger_external_id)
    ).all()
    if not ledger_ids:
        return False
    invited = db.scalar(
        select(LedgerInvite.code)
        .where(
            LedgerInvite.ledger_id.in_(ledger_ids),
            LedgerInvite.used_by == user_id,
        )
        .limit(1)
    )
    if invited is not None:
        return True
    pushed = db.scalar(
        select(SyncChange.change_id)
        .where(
            SyncChange.ledger_id.in_(ledger_ids),
            SyncChange.updated_by_user_id == user_id,
        )
        .limit(1)
    )
    return pushed is not None


# ---------------------------------------------------------------------------
# 附录 B3:push 冲突 AuditLog 节流
# ---------------------------------------------------------------------------

_CONFLICT_AUDIT_TTL_SECONDS = 3600.0
_CONFLICT_AUDIT_MAX_KEYS = 4096
# (user_id, ledger_id|None, entity_type, entity_sync_id, device_id) → monotonic ts。
# 被拒 change 会被客户端永久重推,每条都写 AuditLog 会把 audit_logs 撑爆;
# 同 key 在 TTL 内只落一条(计数器/日志样本不受影响,只省 AuditLog 行)。
# 进程内字典:单进程部署下足够;多 worker 下最坏退化为每 worker 一条/小时。
_conflict_audit_last: dict[tuple[str, str | None, str, str, str], float] = {}


def _should_write_conflict_audit(
    *, user_id: str, ledger_id: str | None, entity_type: str,
    entity_sync_id: str, device_id: str,
) -> bool:
    key = (user_id, ledger_id, entity_type, entity_sync_id, device_id)
    now_ts = time.monotonic()
    last = _conflict_audit_last.get(key)
    if last is not None and (now_ts - last) < _CONFLICT_AUDIT_TTL_SECONDS:
        return False
    if len(_conflict_audit_last) >= _CONFLICT_AUDIT_MAX_KEYS:
        cutoff = now_ts - _CONFLICT_AUDIT_TTL_SECONDS
        stale = [k for k, v in _conflict_audit_last.items() if v < cutoff]
        for k in stale:
            del _conflict_audit_last[k]
        if len(_conflict_audit_last) >= _CONFLICT_AUDIT_MAX_KEYS:
            _conflict_audit_last.clear()
    _conflict_audit_last[key] = now_ts
    return True


@router.post("/push", response_model=SyncPushResponse)
async def push_changes(
    req: SyncPushRequest,
    request: Request,
    _scopes: set[str] = Depends(require_scopes(SCOPE_APP_WRITE)),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SyncPushResponse:
    metrics.inc("smartbook_sync_push_requests_total")

    # ------------------------------------------------------------------ #
    # P1-C1:批处理核心(全部同步 DB 工作)在 worker 线程跑。事务级 advisory
    # 锁(§4.7 user→ledger)与 apply、commit 同线程同事务,不拆连接。
    # ------------------------------------------------------------------ #
    def _core() -> dict[str, Any]:
        device = db.scalar(
            select(Device).where(
                Device.id == req.device_id,
                Device.user_id == current_user.id,
                Device.revoked_at.is_(None),
            )
        )
        if not device:
            metrics.inc("smartbook_sync_push_failed_total")
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid device")

        now = datetime.now(timezone.utc)
        # P1-E1:首绑判据用不可变事实(SyncChange 存在性,批前语义上等价 —— 本
        # 请求的行循环里才写)。懒查询:只有真的走到「未知 external_id」分支才
        # 需要;last_seen_at 只是心跳展示字段,不再参与判定。
        device_pushed_before: bool | None = None

        def _has_pushed_before() -> bool:
            nonlocal device_pushed_before
            if device_pushed_before is None:
                device_pushed_before = _device_has_pushed_before(
                    db, device_id=req.device_id,
                )
            return device_pushed_before

        device.last_seen_at = now

        accepted = 0
        rejected = 0
        conflict_count = 0
        conflict_samples: list[dict[str, Any]] = []
        # 批次3:apply 抛异常的 change 隔离计数(不再整批 500 → 客户端无限重推
        # 同一批的确定性死循环)。savepoint 回滚该条,其余照常 commit。
        failed_count = 0
        failed_samples: list[dict[str, Any]] = []
        max_cursor = 0
        touched_ledgers: dict[str, str] = {}
        # 共享账本 Phase 1:user-global category/account/tag 变更要 fan-out 给
        # 该 user 作为 owner 的所有共享账本的非 owner member。收集后 commit 后广播。
        pending_shared_resource_events: list[dict[str, Any]] = []

        # 是否触动 user-global —— 触动了就额外给 owner 广播一条 __user_global__
        # 通道的 sync_change(让其他设备拉这一份)。
        touched_user_global = False

        # F10:批内缓存。追赶推送 500 条 = 旧路径对同一 ledger 重复解析 500 次、
        # 同一 tx 的 creator 重复点查;字典缓存后各只查一次。
        ledger_cache: dict[str, Ledger | None] = {}
        tx_creator_cache: dict[tuple[str, str], str | None] = {}

        # P0-2 锁顺序契约(user→ledger,SYNC_ARCHITECTURE §4.7):批内含
        # user-global 变更时,在循环里任何 ledger 锁**之前**先取 caller 的
        # user 锁 —— 否则「批前半 ledger-scope(取 ledger 锁)→ 后半
        # user-scope(取 user 锁)」的批次会与其它固定 user→ledger 顺序的路径
        # (push ledger 分支 / web 写路径)交叉死锁。user-global 的 rename
        # cascade 与 ledger-scope tx upsert 写同一批投影行,两把锁把这对竞态
        # 串行化(谓词改造后锁降级为防抖,遗留窗口也会被后续 rename 幂等纠正)。
        if any(c.entity_type in USER_GLOBAL_ENTITY_TYPES for c in req.changes):
            lock_user_global(db, current_user.id)

        for change in req.changes:
            is_user_global = change.entity_type in USER_GLOBAL_ENTITY_TYPES

            # ============================================================
            # 路径分流:user-global vs ledger-scoped
            # ============================================================
            # user-global(category/account/tag)在新协议下不依附 ledger:
            #   - SyncChange.user_id = current_user.id(真请求方,非账本 owner)
            #   - SyncChange.ledger_id = NULL
            #   - SyncChange.scope = 'user'
            #   - LWW 按 (user_id, scope='user', entity_type, entity_sync_id) 决胜
            #   - 不做 ledger 自动创建(user-global 不挂账本)
            # ledger-scoped(transaction/budget/ledger)沿用老路径。
            # ============================================================

            ledger: Ledger | None = None  # 仅 ledger-scoped 用
            if is_user_global:
                # 老 mobile 可能填了 change.ledger_id(借车协议),server 端忽略;
                # 不做 get_accessible_ledger 校验。
                pass
            else:
                if change.ledger_id is None:
                    # 老协议契约要求 ledger-scoped 必须带 ledger_id;新协议同样要求。
                    logger.warning(
                        "sync.push.skip ledger-scoped change missing ledger_id "
                        "entity=%s sync_id=%s",
                        change.entity_type,
                        change.entity_sync_id,
                    )
                    rejected += 1
                    continue
                # F10:批内缓存 —— 同一 external_id 只解析一次。None = 首次解析
                # 不存在(auto-create 后续 change 复用 __auto__ 里已建的 Ledger,
                # 不再重复创建);命中过的直接取。
                if change.ledger_id not in ledger_cache:
                    row0 = get_accessible_ledger_by_external_id(
                        db,
                        user_id=current_user.id,
                        ledger_external_id=change.ledger_id,
                    )
                    if row0 is None:
                        ledger_cache[change.ledger_id] = None
                    else:
                        ledger_cache[change.ledger_id] = row0
                cached_entry = ledger_cache.get(change.ledger_id)
                if isinstance(cached_entry, tuple):
                    row = cached_entry
                elif cached_entry is None and f"__auto__{change.ledger_id}" in ledger_cache:
                    # 本批早前 auto-create 过 → 复用(本批内不会有人删它)。
                    ledger = ledger_cache[f"__auto__{change.ledger_id}"]
                    row = (ledger, "owner")
                else:
                    row = None
                if row is None:
                    # P1-E1:caller 曾是该账本成员但已被移除 / 账本已被删 →
                    # 显式拒绝,绝不落入 auto-create(旧口径会以 owner 的
                    # external_id 在 caller 名下静默重建私有账本 → 数据分裂)。
                    if _has_past_membership_evidence(
                        db,
                        user_id=current_user.id,
                        ledger_external_id=change.ledger_id,
                    ):
                        logger.warning(
                            "sync.push.reject removed-member ledger "
                            "user=%s device=%s ledger=%s entity=%s",
                            current_user.id, req.device_id, change.ledger_id,
                            change.entity_type,
                        )
                        rejected += 1
                        if len(failed_samples) < 20:
                            failed_samples.append({
                                "reason": "membership_revoked",
                                "ledgerId": change.ledger_id,
                                "entityType": change.entity_type,
                                "entitySyncId": change.entity_sync_id,
                            })
                        continue
                    # 批次3(幽灵账本收紧):auto-create 只在「首次绑定」放行 —— 该
                    # device 从未推送过任何账本(全新设备首绑)。老口径无差别自动建
                    # 账本,客户端 syncId 丢失/降级回退本地 int id 时,服务端会静默
                    # 建出幽灵空账本:旧账本数据"消失"、统计被空账本稀释,且之后
                    # 正确 syncId 的推送与幽灵账本并存,极难自查。非首绑场景返回
                    # 404 让客户端走 fullPush/重新绑定,而不是制造数据分裂。
                    if _has_pushed_before():
                        # 首绑 = 该 device 从未推送过(SyncChange 存在性,不可变)。
                        # 非首绑 + 用户名下 ≥2 个账本时突然推未知 external_id,
                        # 大概率是客户端 syncId 丢失回退本地 int id,拒绝并让客户端
                        # 走 fullPush;名下 ≤1 的迁移期仍放行。
                        _owned = db.scalar(
                            select(func.count(Ledger.id)).where(
                                Ledger.user_id == current_user.id
                            )
                        )
                        if (_owned or 0) >= 2:
                            logger.warning(
                                "sync.push.reject unknown ledger (ghost-ledger guard) "
                                "user=%s device=%s ledger=%s entity=%s",
                                current_user.id, req.device_id, change.ledger_id,
                                change.entity_type,
                            )
                            rejected += 1
                            if len(failed_samples) < 20:
                                failed_samples.append({
                                    "reason": "unknown_ledger",
                                    "ledgerId": change.ledger_id,
                                    "entityType": change.entity_type,
                                    "entitySyncId": change.entity_sync_id,
                                })
                            continue
                    # Caller doesn't own a ledger with this external_id — auto-create.
                    # The (user_id, external_id) unique constraint keeps per-user ids
                    # isolated, so two users can independently own "default".
                    ledger = Ledger(user_id=current_user.id, external_id=change.ledger_id)
                    db.add(ledger)
                    db.flush()
                    # 共享账本 Phase 1:auto-create 时同步建 owner LedgerMember 行
                    db.add(LedgerMember(
                        ledger_id=ledger.id,
                        user_id=current_user.id,
                        role="owner",
                        joined_at=now,
                    ))
                    db.flush()
                    # F10:本批内后续 change 复用,不再重复解析/创建。
                    ledger_cache[f"__auto__{change.ledger_id}"] = ledger
                else:
                    ledger, caller_role = row
                    # 共享账本 Phase 1:Editor 只能推 transaction / budget;不能推
                    # ledger / ledger_snapshot(账本 meta 改 / 删账本属 owner 操作)。
                    # 老协议没有 entity_type='ledger_snapshot' 路径(0011 后),所以
                    # 实际只挡 'ledger'。
                    if caller_role != "owner" and change.entity_type in ("ledger", "ledger_snapshot"):
                        logger.warning(
                            "sync.push.reject ledger-meta change from non-owner "
                            "user=%s ledger=%s role=%s entity=%s",
                            current_user.id, change.ledger_id, caller_role, change.entity_type,
                        )
                        rejected += 1
                        continue

            # Clamp incoming updated_at to the server clock to neutralize client
            # clock skew. Without this, a mobile device whose local clock is ahead
            # of the server by minutes/hours will always win LWW against a legitimate
            # web write that used server time — silently overriding the user's latest
            # change. Cap the incoming timestamp at (server_now + 5s); legitimate
            # small skew still passes, intentional-or-accidental future dates don't.
            raw_updated_at = _to_utc(change.updated_at)
            max_allowed = now + timedelta(seconds=5)
            incoming_updated_at = min(raw_updated_at, max_allowed)

            # ============================================================
            # LWW lookup —— scope-aware
            # ============================================================
            if is_user_global:
                latest_entity_change = db.scalar(
                    select(SyncChange)
                    .where(
                        SyncChange.user_id == current_user.id,
                        SyncChange.scope == "user",
                        SyncChange.entity_type == change.entity_type,
                        SyncChange.entity_sync_id == change.entity_sync_id,
                    )
                    .order_by(SyncChange.change_id.desc())
                    .limit(1)
                )
            else:
                assert ledger is not None
                latest_entity_change = db.scalar(
                    select(SyncChange)
                    .where(
                        SyncChange.ledger_id == ledger.id,
                        SyncChange.entity_type == change.entity_type,
                        SyncChange.entity_sync_id == change.entity_sync_id,
                    )
                    .order_by(SyncChange.change_id.desc())
                    .limit(1)
                )

            # Deterministic LWW with device_id tie-break:
            # compare (updated_at, device_id) tuples lexicographically so two servers
            # or retried calls produce the same winner regardless of arrival order.
            incoming_device_id = req.device_id or ""
            incoming_tuple = (incoming_updated_at, incoming_device_id)
            existing_tuple: tuple[datetime, str] | None = None
            if latest_entity_change:
                existing_tuple = (
                    _to_utc(latest_entity_change.updated_at),
                    latest_entity_change.updated_by_device_id or "",
                )

            if existing_tuple is not None and existing_tuple > incoming_tuple:
                rejected += 1
                conflict_count += 1
                sample = {
                    "reason": "lww_rejected_older_change",
                    "ledgerId": change.ledger_id,
                    "entityType": change.entity_type,
                    "entitySyncId": change.entity_sync_id,
                    "existingChangeId": latest_entity_change.change_id,
                }
                if len(conflict_samples) < 20:
                    conflict_samples.append(sample)
                logger.warning(
                    "sync.push.conflict entity=%s action=%s ledger=%s sync_id=%s device=%s "
                    "incoming_ts=%s existing_ts=%s existing_change=%d",
                    change.entity_type,
                    change.action,
                    change.ledger_id,
                    change.entity_sync_id,
                    req.device_id,
                    incoming_updated_at.isoformat(),
                    existing_tuple[0].isoformat(),
                    latest_entity_change.change_id,
                )
                # 附录 B3:被拒 change 会被客户端永久重推,同 key 冲突的
                # AuditLog 在 TTL 内只落一条,防 audit_logs 无界膨胀。
                if _should_write_conflict_audit(
                    user_id=current_user.id,
                    ledger_id=ledger.id if ledger is not None else None,
                    entity_type=change.entity_type,
                    entity_sync_id=change.entity_sync_id,
                    device_id=incoming_device_id,
                ):
                    db.add(
                        AuditLog(
                            user_id=current_user.id,
                            ledger_id=ledger.id if ledger is not None else None,
                            action="sync_conflict",
                            metadata_json={
                                **sample,
                                "incomingUpdatedAt": incoming_updated_at.isoformat(),
                                "existingUpdatedAt": existing_tuple[0].isoformat(),
                                "incomingDeviceId": req.device_id,
                                "existingDeviceId": existing_tuple[1],
                            },
                        )
                    )
                continue

            if existing_tuple is not None and existing_tuple == incoming_tuple:
                # Idempotent replay (same device, same timestamp) — don't duplicate.
                accepted += 1
                logger.debug(
                    "sync.push.replay entity=%s action=%s ledger=%s sync_id=%s device=%s",
                    change.entity_type,
                    change.action,
                    change.ledger_id,
                    change.entity_sync_id,
                    req.device_id,
                )
                continue

            # ============================================================
            # SyncChange row + apply 路径
            # ============================================================
            if is_user_global:
                # P0-2:user 锁已在本批循环前预取(见上方锁顺序注释);这里幂等
                # 再取一次(PG 下同事务重入是 no-op),保持分支自含 —— user-scope
                # change 改 user-global 实体的投影写必须在 lock_user_global 下。
                lock_user_global(db, current_user.id)

                # P0-1:apply 前先取旧名(apply 后投影行即被刷成新名);apply
                # 成功后若确为 rename,按 sync_id 点查受影响 tx 行补发
                # cascade-only SyncChange —— owner 端 pull 可见,否则共享账本里
                # Editor 改名只有服务端投影刷新,owner 的 mobile 永远旧名。
                prev_entity_name = (
                    _user_global_prev_name(
                        db,
                        user_id=current_user.id,
                        entity_type=change.entity_type,
                        sync_id=change.entity_sync_id,
                    )
                    if change.action == "upsert"
                    and change.entity_type in ("account", "category", "tag")
                    else None
                )
                row_change = SyncChange(
                    user_id=current_user.id,       # 真请求方
                    ledger_id=None,
                    scope="user",
                    entity_type=change.entity_type,
                    entity_sync_id=change.entity_sync_id,
                    action=change.action,
                    payload_json=change.payload,
                    updated_at=incoming_updated_at,
                    updated_by_device_id=req.device_id,
                    updated_by_user_id=current_user.id,
                )
                try:
                    with db.begin_nested():
                        # add+flush 必须在 savepoint 内:apply 抛错时 SyncChange 行随
                        # 投影应用一起回滚。在外面 flush 的话,孤儿事件行会被外层
                        # commit 提交 —— pull 端按事件删实体而投影未删,且该孤儿行
                        # 成为 LWW 最新,阻塞后续合法 upsert。
                        db.add(row_change)
                        db.flush()
                        extra_fanout = apply_user_change_to_projection(
                            db,
                            user_id=current_user.id,
                            change=row_change,
                        )
                except Exception as exc:
                    # 批次3:坏 change 隔离 —— savepoint 回滚这一条的投影应用与
                    # SyncChange 行,不再 raise 炸整批(旧行为:客户端无限重推同一批,
                    # 同步永久卡死)。row_change 已回滚,except 内不可访问其属性。
                    logger.exception(
                        "sync.push.apply_failed (user-scope, isolated) entity=%s action=%s "
                        "sync_id=%s payload=%s",
                        change.entity_type,
                        change.action,
                        change.entity_sync_id,
                        change.payload,
                    )
                    failed_count += 1
                    if len(failed_samples) < 20:
                        failed_samples.append({
                            "reason": "apply_failed",
                            "entityType": change.entity_type,
                            "entitySyncId": change.entity_sync_id,
                            "action": change.action,
                            "error": str(exc)[:200],
                        })
                    continue
                touched_user_global = True
                # P0-1:rename 落定(apply 内 cascade 已刷投影),补发 cascade-only
                # tx SyncChange。在 savepoint 之后跑:补发失败不应回滚已接受的
                # rename 本身。
                if prev_entity_name is not None:
                    new_entity_name = str((change.payload or {}).get("name") or "").strip()
                    if new_entity_name and new_entity_name != prev_entity_name:
                        _emit_user_global_cascade_tx_changes(
                            db,
                            actor_user_id=current_user.id,
                            device_id=req.device_id,
                            updated_at=incoming_updated_at,
                            entity_type=change.entity_type,
                            entity_sync_id=change.entity_sync_id,
                        )
                # 共享账本 fan-out:只对 category/account/tag 三种 user-global 类型
                # 推 shared_resource_change(其他 user-global 类型如 device 等不外推)
                if change.entity_type in ("category", "account", "tag"):
                    pending_shared_resource_events.append({
                        "resource_type": change.entity_type,
                        "action": change.action,
                        "sync_id": change.entity_sync_id,
                        "payload": change.payload or {"sync_id": change.entity_sync_id},
                    })
                    # category delete 的服务端级联会连带删掉子分类(见
                    # sync_applier._delete_user_category_cascade),这些子分类的
                    # delete 也要 fan-out,否则成员端镜像留僵尸子分类。
                    if extra_fanout:
                        pending_shared_resource_events.extend(extra_fanout)
            else:
                assert ledger is not None
                # §7 共享账本:mobile 历史路径未在本地 transactions.created_by_user_id
                # / last_edited_by_user_id 上回填(addTransaction / updateTransaction
                # 不写这两列),所以 EntitySerializer 序列化出来的 payload 缺这俩
                # 字段。server 这里兜底注入,让 SyncChange.payload_json 保留正确身份;
                # 否则 pull 端拿到的 payload 没有 user id,mobile 本地 DB 的
                # created_by / last_edited 字段全空,UI 无法显示"X 创建 / Y 编辑"。
                #
                # createdByUserId:first-write-wins — 已存在 read_tx_projection
                # 行就保留(避免 B 编辑 A 创建的 tx 时把 created 改成 B),否则用
                # 当前 actor。
                # updatedByUserId:始终用当前 actor(谁 push 就是谁编辑)。
                if change.entity_type == "transaction" and isinstance(change.payload, dict):
                    if not change.payload.get("updatedByUserId"):
                        change.payload["updatedByUserId"] = current_user.id
                    if not change.payload.get("createdByUserId"):
                        cache_key = (ledger.id, change.entity_sync_id)
                        if cache_key not in tx_creator_cache:
                            tx_creator_cache[cache_key] = db.scalar(
                                select(ReadTxProjection.created_by_user_id).where(
                                    ReadTxProjection.ledger_id == ledger.id,
                                    ReadTxProjection.sync_id == change.entity_sync_id,
                                )
                            )
                        change.payload["createdByUserId"] = (
                            tx_creator_cache[cache_key] or current_user.id
                        )
                row_change = SyncChange(
                    user_id=ledger.user_id,
                    ledger_id=ledger.id,
                    scope="ledger",
                    entity_type=change.entity_type,
                    entity_sync_id=change.entity_sync_id,
                    action=change.action,
                    payload_json=change.payload,
                    updated_at=incoming_updated_at,
                    updated_by_device_id=req.device_id,
                    updated_by_user_id=current_user.id,
                )
                # 方案 B:projection 随 push 同事务刷新。不再写 ledger_snapshot 行。
                if change.entity_type in INDIVIDUAL_ENTITY_TYPES:
                    # P0-2 锁顺序契约(user→ledger):先取 owner(ledger.user_id)
                    # 的 user 锁再取 ledger 锁,与 user-scope 分支(批首预取
                    # caller user 锁)和 web 写路径保持全局固定顺序,防死锁。
                    # user 锁把「owner 侧 user-global rename cascade」与「本账本
                    # tx upsert 刷 denorm 列」这对竞态串行化(防抖;谓词改造后
                    # 遗留窗口由后续 rename 幂等纠正)。
                    lock_user_global(db, ledger.user_id)
                    # lock 一次/账本,避免两个 push 并发走同个 ledger 的 cascade
                    lock_ledger_for_materialize(db, ledger.id)
                    try:
                        with db.begin_nested():
                            # 同 user-scope:add+flush 必须在 savepoint 内,apply 抛错
                            # 时 SyncChange 行随投影应用一起回滚,不留孤儿事件行。
                            db.add(row_change)
                            db.flush()
                            apply_change_to_projection(
                                db,
                                ledger_id=ledger.id,
                                ledger_owner_id=ledger.user_id,
                                change=row_change,
                            )
                    except Exception as exc:
                        # 批次3:坏 change 隔离 —— savepoint 回滚这一条的投影应用与
                        # SyncChange 行,其余 change 照常 commit。旧行为(raise 整批
                        # 500)会让一条 poison change 永久卡死该设备的全部推送。
                        # row_change 已回滚,except 内不可访问其属性。
                        logger.exception(
                            "sync.push.apply_failed (isolated) entity=%s action=%s ledger=%s sync_id=%s "
                            "payload=%s",
                            change.entity_type,
                            change.action,
                            change.ledger_id,
                            change.entity_sync_id,
                            change.payload,
                        )
                        failed_count += 1
                        if len(failed_samples) < 20:
                            failed_samples.append({
                                "reason": "apply_failed",
                                "ledgerId": change.ledger_id,
                                "entityType": change.entity_type,
                                "entitySyncId": change.entity_sync_id,
                                "action": change.action,
                                "error": str(exc)[:200],
                            })
                        continue
                else:
                    db.add(row_change)
                    db.flush()
                touched_ledgers[ledger.external_id] = ledger.id

            accepted += 1
            max_cursor = max(max_cursor, row_change.change_id)
            logger.info(
                "sync.push.accept entity=%s action=%s ledger=%s sync_id=%s change_id=%d device=%s user=%s scope=%s",
                change.entity_type,
                change.action,
                change.ledger_id,
                change.entity_sync_id,
                row_change.change_id,
                req.device_id,
                current_user.id,
                row_change.scope,
            )

        # P1-B2:owner 的 user-global 变更派生 ledger-scope 镜像 SyncChange
        # (与批内事件同事务;Editor 常规 pull 可见,WS 退化为加速通道,§4.9)。
        # 镜像只覆盖 user-global 实体自身 —— tx cascade 事件已在上面逐条补发,
        # 这里不重复。
        if pending_shared_resource_events:
            from ..write._shared import _emit_user_global_ledger_mirrors
            mirror_max = _emit_user_global_ledger_mirrors(
                db,
                actor_user_id=current_user.id,
                device_id=req.device_id,
                now=now,
                events=pending_shared_resource_events,
            )
            if mirror_max:
                max_cursor = max(max_cursor, mirror_max)

        if max_cursor == 0:
            accessible = list_accessible_ledgers(db, user_id=current_user.id)
            max_cursor = _max_cursor_for_ledgers(db, [lg.id for lg in accessible])

        db.commit()

        return {
            "now": now,
            "accepted": accepted,
            "rejected": rejected,
            "conflict_count": conflict_count,
            "conflict_samples": conflict_samples,
            "failed_count": failed_count,
            "failed_samples": failed_samples,
            "max_cursor": max_cursor,
            "touched_ledgers": touched_ledgers,
            "touched_user_global": touched_user_global,
            "pending_shared_resource_events": pending_shared_resource_events,
        }

    result = await run_in_threadpool(_core)

    now: datetime = result["now"]
    accepted: int = result["accepted"]
    rejected: int = result["rejected"]
    conflict_count: int = result["conflict_count"]
    max_cursor: int = result["max_cursor"]
    touched_ledgers: dict[str, str] = result["touched_ledgers"]
    touched_user_global: bool = result["touched_user_global"]
    pending_shared_resource_events: list[dict[str, Any]] = result[
        "pending_shared_resource_events"
    ]

    # ------------------------------------------------------------------ #
    # WS 广播留在 event loop 上(P1-C1,与 write 路径同款)。
    # ------------------------------------------------------------------ #
    if touched_ledgers:
        ws_manager = request.app.state.ws_manager
        # 共享账本 Phase 1:fan-out 给该 ledger 所有 member(LedgerMember 表),
        # 包含 owner 自己(其他设备需要拉)+ Editor 等。client 用 device_id 去重。
        from ...websocket_manager import broadcast_to_ledger
        for ledger_external_id, ledger_id in touched_ledgers.items():
            await broadcast_to_ledger(
                db=db,
                ws_manager=ws_manager,
                ledger_id=ledger_id,
                payload={
                    "type": "sync_change",
                    "ledgerId": ledger_external_id,
                    "serverCursor": max_cursor,
                    "serverTimestamp": now.isoformat(),
                },
            )

    if touched_user_global:
        # user-global change broadcast 走 sentinel ledger external id,mobile/web
        # 收到后会去 pull __user_global__ 拉这一份增量。
        ws_manager = request.app.state.ws_manager
        await ws_manager.broadcast_to_user(
            current_user.id,
            {
                "type": "sync_change",
                "ledgerId": "__user_global__",
                "serverCursor": max_cursor,
                "serverTimestamp": now.isoformat(),
            },
        )

    if pending_shared_resource_events:
        # 共享账本 fan-out:对 caller 作为 owner 的所有共享账本,推该事件给
        # 非 owner member。Editor 收到后更新本地 SharedLedger* 镜像。
        # (P1-B2 后这是加速通道 —— 掉线的 Editor 靠 ledger-scope 镜像事件
        # 通过常规 /sync/pull 补拉,不再依赖这条 WS。)
        ws_manager = request.app.state.ws_manager
        from sqlalchemy import func as _func

        from ...models import Ledger as _L
        from ...models import LedgerMember as _LM
        rows = db.execute(
            select(_L.id, _L.external_id)
            .join(_LM, _LM.ledger_id == _L.id)
            .where(_L.user_id == current_user.id)
            .group_by(_L.id, _L.external_id)
            .having(_func.count(_LM.user_id) > 1)
        ).all()
        from ...ledger_access import list_ledger_members
        for ledger_id, ledger_external_id in rows:
            for member_user_id, role in list_ledger_members(db, ledger_id=ledger_id):
                if role == "owner":
                    continue
                for ev in pending_shared_resource_events:
                    await ws_manager.broadcast_to_user(member_user_id, {
                        "type": "shared_resource_change",
                        "ledgerId": ledger_external_id,
                        "resourceType": ev["resource_type"],
                        "action": ev["action"],
                        "payload": ev["payload"],
                    })

    logger.info(
        "sync.push user=%s device=%s accepted=%d rejected=%d conflict=%d ledgers=%d user_global=%s",
        current_user.id,
        req.device_id,
        accepted,
        rejected,
        conflict_count,
        len(touched_ledgers),
        touched_user_global,
    )
    return SyncPushResponse(
        accepted=accepted,
        rejected=rejected,
        conflict_count=conflict_count,
        conflict_samples=result["conflict_samples"],
        failed_count=result["failed_count"],
        failed_samples=result["failed_samples"],
        server_cursor=max_cursor,
        server_timestamp=now,
    )
