"""POST /sync/push —— mobile 批量推送本地变更。

每条 change:LWW 决胜(updated_at + device_id tie-break)→ 写 SyncChange 行
→ 走 sync_applier.apply_change_to_projection 刷 projection。整批单事务
提交,一条坏 change 炸会带 traceback 日志并 rollback 整批。

P1-C1(2026-09):批处理核心(同步 DB 部分)经 ``run_in_threadpool`` 跑在
worker 线程,大批推送不再阻塞 event loop(WS 心跳 / 健康检查);与 write 路径
(issue #31 A2)同款模式 —— WS 广播留在 loop 上。advisory 锁(user→ledger 顺序,
§4.7)是事务级的:取锁与 apply 与 commit 都在同一个 worker 线程的同一个
session/事务里,不跨连接。

对抗批次 S2 对 LWW / 幂等语义的加固(详见 docs/SYNC_ARCHITECTURE.md §4.2):

- **F-01 幂等四元组**:重放判定从 ``(updated_at, device_id)`` 升级为
  ``(原始 updated_at, device_id, action, payload_hash)``。``payload_hash`` 是
  变更体的规范化 sha256(**阻塞-3**:在身份注入
  ``updatedByUserId/createdByUserId`` *之后*计算,与库内 ``payload_json`` 的
  形态一致),因此「同毫秒的第二次编辑」不再被当成重放吞掉。
- **LWW 与幂等**两层**解耦**(交叉复核 D1):
  - **LWW 决胜**用 **clamp 后的有效 ts**(= ``min(原始 ts, now+5s)``,即服务端
    真正接受的「现在」)—— 快时钟设备不能靠原始未来 ts 永久压过合法写入;
  - **重放判定**用**原始 ts**(被 clamp 的 change 把原始 ts 记进 payload 内部键
    ``__rawUpdatedAt``,只写不改;老行回退到 ``updated_at`` 列)—— 重试时 clamp
    天花板漂移不再破坏幂等,同批同实体的多次编辑也不再坍缩。
  - 有效 ts 并列 + 原始 ts 并列(同设备、action 翻转、且既有行的有效 ts 仍在
    未来)时**保持既有形态**并报 ``rejected``(确定性,不翻转存在性);既有行的
    有效 ts 一旦落到过去,后到者按有效 ts 正常胜出(可恢复,不自锁)。
- **D2 内部键边界**:``__`` 前缀键是服务端内部状态,入站一律 strip(客户端不能
  伪造 LWW 键锁死实体),出站(/sync/pull、WS fan-out)一律过滤(不下发实现细节)。
- **F-02 cascade 让位**:user-global rename 派生的 cascade-only tx 事件延后到
  批循环**之后**补发,客户端显式变更优先,不再抢占 LWW 槽位。
"""
from __future__ import annotations

import hashlib
import time

from starlette.concurrency import run_in_threadpool

from ...concurrency import lock_user_global
from ._shared import *  # noqa: F401,F403 — 拉取所有 imports / helpers / router / constants

# 显式重导入本文件新增代码引用的 star-import 符号(同对象),消除新增 F405。
from ._shared import (  # noqa: F401 — re-import for explicitness
    Ledger,
    ReadTxProjection,
    Session,
    SyncChange,
    SyncChangeIn,
    User,
    _is_internal_payload_key,
    _public_payload,
    _strip_internal_payload_keys,
    _to_utc,
    datetime,
    json,
    logger,
    select,
)

# 被 clamp 的 change 在 payload 里留下的内部标记(clamp 前的客户端 ts)。
# 前缀 ``__`` = 服务端内部键,客户端 serializer 不会产生同名字段。
# 只写不改:老 SyncChange 行没有这个键时回退到 ``updated_at`` 列。
_RAW_TS_PAYLOAD_KEY = "__rawUpdatedAt"

# entity_sync_id / sync_id 的列宽上限(models.py 的 String(255))。push 入口按
# 列宽校验,避免 SQLite 静默通过、PostgreSQL `value too long` 整批失败(F-11)。
MAX_ENTITY_SYNC_ID_LENGTH = 255


def _normalized_payload_hash(payload: object) -> str:
    """变更体规范化 sha256(F-01 幂等四元组的第 4 位)。

    规范化 = 排序 key + 紧凑分隔符 + 非 JSON 值 ``str()`` 兜底,保证
    「同一逻辑 payload」在两次请求里 hash 相同(键序 / 空白 / SQLite 的
    JSON 文本往返都不影响)。``payload_json`` 在 SQLite 下可能取回字符串,
    先解析回对象再规范化。

    **命令-3(幂等回归)**:hash 在**身份注入之后**计算(与库内
    ``payload_json`` 的形态一致)。**D2(内部键边界)**:两侧都剔除 ``__``
    前缀的服务端内部键(如 ``__rawUpdatedAt``)—— 入站侧它们已被 strip,
    库内行(服务端自己写的 clamp 标记 / 老行)也剔除,否则「本次请求是否
    触发 clamp」会改变 hash,导致真重放 hash 不等 → 重复落 SyncChange 行
    (tests/test_sync_concurrency.py 的幂等契约会翻红)。
    """
    if isinstance(payload, (str, bytes)):
        try:
            payload = json.loads(payload)
        except (ValueError, TypeError):
            return hashlib.sha256(str(payload).encode("utf-8", "replace")).hexdigest()
    if isinstance(payload, dict):
        payload = {k: v for k, v in payload.items() if not _is_internal_payload_key(k)}
    try:
        canonical = json.dumps(
            payload, sort_keys=True, separators=(",", ":"),
            ensure_ascii=False, default=str,
        )
    except (TypeError, ValueError):
        canonical = repr(payload)
    return hashlib.sha256(canonical.encode("utf-8", "replace")).hexdigest()


def _raw_updated_at_of(change_row: SyncChange) -> datetime | None:
    """取该 SyncChange 行 clamp 前的原始 ts(payload 内部标记)。

    没有标记(未 clamp / 老行 / cascade 补发行)→ None,调用方回退到
    ``updated_at`` 列(对未 clamp 的行二者等价)。

    **仅用于重放判定**(交叉复核 D1):LWW 决胜不得用原始 ts —— 否则快时钟
    设备的未来 ts 会永久压过合法写入(clamp 形同虚设)。该键只由服务端写入
    (``_emit_user_global_cascade_tx_changes`` 与 clamp 分支),入站 payload 的
    同名字段已在批处理前被 ``_strip_internal_payload_keys`` 清除。
    """
    payload = change_row.payload_json
    if isinstance(payload, (str, bytes)):
        try:
            payload = json.loads(payload)
        except (ValueError, TypeError):
            return None
    if not isinstance(payload, dict):
        return None
    raw = payload.get(_RAW_TS_PAYLOAD_KEY)
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        return _to_utc(datetime.fromisoformat(raw.replace("Z", "+00:00")))
    except ValueError:
        return None


def _inject_actor_ids_early(
    db: Session,
    *,
    change: SyncChangeIn,
    ledger: Ledger | None,
    current_user: User,
    tx_creator_cache: dict[tuple[str, str], str | None],
) -> None:
    """事务 payload 的身份字段注入 —— **必须在幂等判定之前**跑(阻塞-3)。

    契约:库内 ``SyncChange.payload_json`` 是**注入后**的形态。若对入站的裸
    payload 算 hash,真重放的 hash 不匹配 → 重复落 Event 行 → 既有幂等绿测
    (``tests/test_sync_concurrency.py::test_lww_idempotent_replay_does_not_duplicate``)
    翻红。因此把注入提前到 replay 判定之前,两侧(hash 与落库)看到同一份 payload。

    - ``updatedByUserId``:始终用当前 actor(谁 push 就是谁编辑);
    - ``createdByUserId``:first-write-wins —— 已有投影行就保留原创建人
      (避免 B 编辑 A 创建的 tx 时把 created 改成 B),否则用当前 actor。
    - 与**旧实现逐字同条件**(entity_type='transaction' + ledger 非 None),
      delete 的 payload 同样注入 —— 保持库内 payload 形态不变(既有 delete
      事件的 payload 契约 / 回归测试不受影响)。

    ``ledger`` 为 None(auto-create 之前的路径 / user-global)时跳过 —— 那两种
    情况本来也不注入。
    """
    if change.entity_type != "transaction" or not isinstance(change.payload, dict):
        return
    if ledger is None:
        return
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
) -> int:
    """user-global rename 后补发 cascade-only tx SyncChange(push 路径)。

    与 web 快路径 write/_shared._emit_cascade_tx_changes 同语义:投影已由
    rename_cascade_* SQL 刷过,这里按 sync_id 稳定 FK 点查受影响 tx 行,
    bulk insert ledger-scope upsert 事件 —— 落后设备(含共享账本 owner)
    pull 后刷新本地 denorm 列。owner 拉不到 Editor 的 scope=user 改名事件
    (pull 按 user 过滤),没有这路补发的话 owner 端 mobile 永远旧名
    (P0-1)。软删行不补发:cascade upsert 会让 mobile 按重建已删交易。

    **F-02**:补发事件不参与同批 LWW 槽位抢占 —— 调用方把它延后到批循环
    **之后**(见 ``pending_cascade_emissions``),所以客户端显式 tx 变更先落库,
    cascade 事件随后补发(事件流顺序与投影终态一致)。

    返回插入的 cascade 行数(诊断 / 测试用)。
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
        return 0
    bulk_rows = []
    for r in rows:
        payload = _projection_row_to_tx_dict(r)
        # F-01/F-06:补发行同样标注原始 ts,重放判定才能稳定。cascade 行不是
        # 客户端变更体,不参与「客户端显式变更」的 identity。
        payload[_RAW_TS_PAYLOAD_KEY] = _to_utc(updated_at).isoformat()
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
    return len(bulk_rows)



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

        # F-02:cascade-only tx 事件延后到批循环之后补发。旧行为在循环内即时
        # bulk insert —— 抢占了同批客户端 tx 变更的 LWW 槽位(同 ts → replay
        # 分支吞掉真变更)。现在收集到此列表,循环结束后统一 emit。
        pending_cascade_emissions: list[dict[str, Any]] = []

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
            # D2(交叉复核):入站 payload 剥离服务端内部键
            # ============================================================
            # ``__`` 前缀键是服务端内部状态(当前只有 clamp 的原始 ts 标记
            # ``__rawUpdatedAt``)。旧实现只在服务端 clamp 时 ``setdefault``,
            # 但**从不清理入站 payload** —— 客户端可以自带
            # ``payload: {"__rawUpdatedAt": "2999-01-01T00:00:00+00:00"}``,
            # 服务端随后 ``_raw_updated_at_of`` 把该值当作既有侧 LWW 键,
            # 实体被永久锁死(D2 repro:首次 accepted=1,之后所有编辑
            # accepted=0)。内部状态只能由服务端写,入站一律 strip 并留日志。
            if isinstance(change.payload, dict):
                _stripped = _strip_internal_payload_keys(change.payload)
                if _stripped:
                    logger.warning(
                        "sync.push.strip_internal_payload_keys entity=%s sync_id=%s "
                        "device=%s removed=%d",
                        change.entity_type, change.entity_sync_id,
                        req.device_id, _stripped,
                    )

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
                        # round-3 缺陷 3:被拒分支同时计数 failed_count —— 客户端
                        # 按 conflict+failed 与 rejected 取 max 对账,不计数会让
                        # unclassified 落进 conflict 桶,语义错位。
                        failed_count += 1
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
                            # round-3 缺陷 3:同上,被拒分支计入 failed_count。
                            failed_count += 1
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
                    # F-10:push 到已软删账本必须拒绝(与 web 写路径同口径)。
                    # 旧行为照常 upsert 投影行 → read 路径因账本墓碑全部 404/过滤
                    # (用户看不见),但 read_tx_projection 留下**幽灵行**;账本一旦
                    # 恢复/快照重建,这些行凭空冒出来。web 侧同款检查见
                    # write/_shared._load_ledger_for_write(404 拒绝)。
                    from ..read._shared import _is_ledger_deleted  # late import 防循环

                    if _is_ledger_deleted(db, ledger_id=ledger.id):
                        logger.warning(
                            "sync.push.reject soft-deleted ledger "
                            "user=%s device=%s ledger=%s entity=%s",
                            current_user.id, req.device_id, change.ledger_id,
                            change.entity_type,
                        )
                        rejected += 1
                        # round-3 缺陷 3:同上,被拒分支计入 failed_count。
                        failed_count += 1
                        if len(failed_samples) < 20:
                            failed_samples.append({
                                "reason": "ledger_deleted",
                                "ledgerId": change.ledger_id,
                                "entityType": change.entity_type,
                                "entitySyncId": change.entity_sync_id,
                            })
                        continue
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

            # ============================================================
            # F-05:entity_sync_id 与 payload.syncId 必须一致
            # ============================================================
            # 事件行 / LWW 键用 `entity_sync_id`,而投影 PK 用 `payload.syncId`
            # (sync_applier.setdefault 只在缺键时注入)。两者不一致时:
            #   - 投影落 `payload.syncId` 那行;
            #   - 后续 delete(用 entity_sync_id)永远删不掉它 → 永久幽灵行
            #     (read / 统计 / 导出都看得到,任何事件都改不动)。
            # 入口直接拒绝,不给幽灵行留机会(客户端修好 syncId 后重推即成功)。
            # 例外:delete 的 payload 通常为空(或只带 syncId),缺键时无可比对。
            _payload_sync_id = (
                change.payload.get("syncId")
                if isinstance(change.payload, dict)
                else None
            )
            if (
                _payload_sync_id is not None
                and str(_payload_sync_id) != change.entity_sync_id
            ):
                logger.warning(
                    "sync.push.reject sync_id mismatch entity=%s entity_sync_id=%s "
                    "payload_sync_id=%s",
                    change.entity_type, change.entity_sync_id, _payload_sync_id,
                )
                rejected += 1
                # round-3 缺陷 3:同上,被拒分支计入 failed_count。
                failed_count += 1
                if len(failed_samples) < 20:
                    failed_samples.append({
                        "reason": "sync_id_mismatch",
                        "ledgerId": change.ledger_id,
                        "entityType": change.entity_type,
                        "entitySyncId": change.entity_sync_id,
                        "payloadSyncId": str(_payload_sync_id)[:255],
                    })
                continue

            # ============================================================
            # F-11:entity_sync_id 长度上限
            # ============================================================
            # `sync_changes.entity_sync_id` / 各 projection 的 `sync_id` 都是
            # String(255)(models.py),且 `attachment_files` 等多表共用该长度
            # 假设。SQLite 静默接受 400+ 字符,PostgreSQL 抛
            # `value too long for type character varying(255)` → 整批 500 或
            # savepoint 隔离。正常客户端是 UUID / `tx_<12hex>`,超长必是脏数据,
            # 入口拒绝(比静默截断安全:截断会让两条不同实体撞成同一个 sync_id)。
            if len(change.entity_sync_id) > MAX_ENTITY_SYNC_ID_LENGTH:
                logger.warning(
                    "sync.push.reject overlong entity_sync_id entity=%s len=%d",
                    change.entity_type, len(change.entity_sync_id),
                )
                rejected += 1
                # round-3 缺陷 3:同上,被拒分支计入 failed_count。
                failed_count += 1
                if len(failed_samples) < 20:
                    failed_samples.append({
                        "reason": "entity_sync_id_too_long",
                        "ledgerId": change.ledger_id,
                        "entityType": change.entity_type,
                        # round-3 缺陷 4:sample 的 entitySyncId 必须**完整**
                        # (客户端拿本地全长 syncId 与 sample 比对决定丢弃哪些
                        # 本地实体;截断到 255 会让比对永不命中 → 整批
                        # "不 markPushed" 保护生效,健康同批 change 永远重推)。
                        # 这是客户端自己的数据回显,不构成注入面;列宽截断
                        # (String(255))只作用于落库,与本回显无关。
                        "entitySyncId": change.entity_sync_id,
                        "maxLength": MAX_ENTITY_SYNC_ID_LENGTH,
                    })
                continue

            # Clamp incoming updated_at to the server clock to neutralize client
            # clock skew. Without this, a mobile device whose local clock is ahead
            # of the server by minutes/hours will always win LWW against a legitimate
            # web write that used server time — silently overriding the user's latest
            # change. Cap the incoming timestamp at (server_now + 5s); legitimate
            # small skew still passes, intentional-or-accidental future dates don't.
            #
            # **D1(交叉复核,BLOCKER)**:LWW 与幂等是**两个不同用途**,必须解耦:
            #
            #   - **LWW 决胜键** = ``comparison_ts`` = **clamp 后的有效 ts**
            #     (``min(原始 ts, now+5s)``,即服务端真正接受的「现在」)。
            #     既有侧同样用落库的 ``updated_at`` 列(clamp 值,非 payload 标记)。
            #     若两侧都比原始 ts,clamp 对 LWW 完全失效:快时钟设备一条
            #     ``now+1h`` 的变更会以「原始 ts = now+1h」永久占据 LWW 槽位,
            #     之后所有合法写入(web 服务端时间 / 其他设备)全部被拒 —— 实体
            #     永久不可修(D1 repro:amount 永远停在 10)。
            #     改用有效 ts 后,该变更的实际领先幅度被压到 5s:天花板一过,
            #     任何合法写入(ts ≥ 旧天花板)即胜出 —— 最长 5s 写入真空
            #     (H-04 已记录的接受项),绝不永久锁死。
            #
            #   - **重放/并列键** = 原始 ts(被 clamp 的 change 把它记进 payload
            #     内部键 ``__rawUpdatedAt``,只写不改;老行回退 ``updated_at`` 列)。
            #     重试同一批时 clamp 天花板 ``now+5s`` 会随请求漂移,用有效 ts
            #     当重放键会让真重放 hash/元组不等 → 重复事件行(F-06);
            #     同批同实体多编辑也会坍缩到同一天花板而丢失后序编辑(F-03)。
            #
            # 落库的 ``updated_at`` 仍是 clamp 后的值(时钟偏移防御不放松)。
            raw_updated_at = _to_utc(change.updated_at)
            max_allowed = now + timedelta(seconds=5)
            incoming_updated_at = min(raw_updated_at, max_allowed)
            was_clamped = incoming_updated_at != raw_updated_at
            if was_clamped and isinstance(change.payload, dict):
                # 内部标记写进 payload(随 SyncChange.payload_json 持久化);
                # 入站同名字段已在循环开头 strip,客户端无法伪造;出站
                # (/sync/pull)由 _public_payload 过滤,不下发。
                change.payload.setdefault(
                    _RAW_TS_PAYLOAD_KEY, raw_updated_at.isoformat(),
                )
            comparison_ts = incoming_updated_at

            # ============================================================
            # LWW lookup —— scope-aware
            # ============================================================
            # F-02:cascade-only 补发行**不再出现在本批的槽位历史里** —— 它们
            # 已延后到批循环之后 emit(见 pending_cascade_emissions),所以这里
            # 的 latest 只可能看到客户端显式变更 / 跨批的历史行,不存在
            # 「服务端派生事件抢占同批客户端变更」的窗口。
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
            #
            # **D1(交叉复核,BLOCKER):两个键,两种用途。**
            #
            # (a) **LWW 决胜键** ``(有效 ts, device_id)`` —— 有效 ts 是 clamp 后的
            #     落库值,既有侧也取 ``updated_at`` 列(clamp 值),**不取** payload
            #     里的原始 ts 标记。这样快时钟设备的未来 ts 无法永久占住槽位:
            #     它的领先幅度被 clamp 压到最长 5s,天花板一过,任何 ts ≥ 天花板的
            #     合法写入即胜出(最长 5s 真空,见 H-04 接受项,不自锁死)。
            #     旧实现两侧都比原始 ts → clamp 对 LWW 完全失效 → 一条 ``now+1h``
            #     的变更把实体永久锁死(之后所有合法编辑被拒)。
            #
            # (b) **重放/并列键** ``(原始 ts, device_id)`` —— 被 clamp 的 change 用
            #     payload 内部标记 ``__rawUpdatedAt``(服务端写入,入站已 strip),
            #     老行回退 ``updated_at`` 列。重试同一批时 clamp 天花板随请求漂移,
            #     只有原始 ts 才能让元组稳定(F-06 幂等);同批同实体多编辑也靠
            #     原始 ts 保序,不坍缩(F-03)。
            #
            # 两个键只在「元组全等」时交叉:重放判定额外比对 action + payload_hash。
            incoming_device_id = req.device_id or ""
            incoming_lww_tuple = (comparison_ts, incoming_device_id)
            incoming_replay_tuple = (raw_updated_at, incoming_device_id)
            existing_lww_tuple: tuple[datetime, str] | None = None
            existing_replay_tuple: tuple[datetime, str] | None = None
            if latest_entity_change:
                existing_effective_ts = _to_utc(latest_entity_change.updated_at)
                existing_raw_ts = (
                    _raw_updated_at_of(latest_entity_change) or existing_effective_ts
                )
                existing_device_id = latest_entity_change.updated_by_device_id or ""
                existing_lww_tuple = (existing_effective_ts, existing_device_id)
                existing_replay_tuple = (existing_raw_ts, existing_device_id)

            if existing_lww_tuple is not None and existing_lww_tuple > incoming_lww_tuple:
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
                    comparison_ts.isoformat(),
                    existing_lww_tuple[0].isoformat(),
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
                                "incomingUpdatedAt": comparison_ts.isoformat(),
                                "existingUpdatedAt": existing_lww_tuple[0].isoformat(),
                                "incomingDeviceId": req.device_id,
                                "existingDeviceId": existing_lww_tuple[1],
                            },
                        )
                    )
                continue

            # ============================================================
            # F-01 幂等四元组:(原始 ts, device_id, action, payload_hash)
            # ============================================================
            # 旧实现只看 (updated_at, device_id) 相等就 `continue` —— 同毫秒的
            # **第二次编辑**(payload 不同)或「upsert 之后同 ts 的 delete」都被
            # 当成重放静默丢弃,而响应照算 accepted(客户端以为成功 ⇒ 幽灵交易 /
            # 丢失更新)。现在必须四元组全等才算重放:
            #   - action 不同(upsert vs delete)→ 不是重放;
            #   - payload_hash 不同(内容变了)→ 不是重放。
            #
            # **阻塞-3**:身份注入 `updatedByUserId/createdByUserId` 必须在
            # **重放判定之前**完成 —— 库内 `payload_json` 是注入后的形态,若对
            # 入站裸 payload 算 hash,真重放的 hash 不匹配 → 重复落 SyncChange 行
            # (tests/test_sync_concurrency.py 的既有幂等契约翻红)。
            # 注入本身是两次 dict 取值 + 至多一次点查(带批内缓存),很便宜。
            if isinstance(change.payload, dict):
                _inject_actor_ids_early(
                    db, change=change, ledger=ledger, current_user=current_user,
                    tx_creator_cache=tx_creator_cache,
                )

            # 性能:payload_hash 只在「重放键全等」(潜在重放)时才计算 —— 正常增量
            # 推送(ts 严格递增)完全跳过 json.dumps+sha256,400 条批次的 worker
            # 线程 GIL 占用与旧实现同级(否则 event-loop 探针会漂移)。
            if (
                existing_replay_tuple is not None
                and existing_replay_tuple == incoming_replay_tuple
            ):
                incoming_payload_hash = _normalized_payload_hash(
                    change.payload if change.action != "delete" else {}
                )
                if (
                    latest_entity_change is not None
                    and latest_entity_change.action == change.action
                    and _normalized_payload_hash(
                        latest_entity_change.payload_json
                        if latest_entity_change.action != "delete" else {}
                    ) == incoming_payload_hash
                ):
                    # Idempotent replay (same device / raw ts / action / payload) —
                    # don't duplicate.
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

            # 非重放但原始 ts 并列(F-03 坍缩窗口的残留形态):本 change 被 clamp
            # 过(设备时钟超前 → 落库 ts 被压到 ceiling)且原始 ts 与既有行相同。
            # 原始 ts 相等说明客户端确实复用了同一个 ts;此时 action 不同
            # (upsert↔delete)无法判定先后(有效 ts 也相等)⇒ **保持首个已落库的
            # 形态**,不翻转存在性(确定性优先)。
            #
            # D3(交叉复核):这个分支**没有 apply**,因此绝不能报 accepted ——
            # 旧实现 `accepted += 1` 让客户端以为 delete 成功,而投影行仍在、
            # `deleted_at IS NULL`,本地与服务端永久分叉(客户端不重试)。
            # 现在如实报 rejected + conflict sample(带 entitySyncId):客户端
            # `rejectedEntitySyncIds` 命中 → 不 markPushed → 保留待重推/pull 对齐;
            # 用户重新编辑(更大 ts)即可越过(不会自锁)。
            #
            # 未 clamp 的窗口内真实并列(action 不同)不走这里 —— 后到者胜
            # (F-01 核心诉求:delete 不再被静默吞掉)。
            if (
                was_clamped
                and existing_replay_tuple is not None
                and existing_replay_tuple == incoming_replay_tuple
                and latest_entity_change is not None
                and latest_entity_change.action != change.action
            ):
                rejected += 1
                conflict_count += 1
                sample = {
                    "reason": "lww_tie_action_kept",
                    "ledgerId": change.ledger_id,
                    "entityType": change.entity_type,
                    "entitySyncId": change.entity_sync_id,
                    "existingChangeId": latest_entity_change.change_id,
                    "incomingAction": change.action,
                    "existingAction": latest_entity_change.action,
                }
                if len(conflict_samples) < 20:
                    conflict_samples.append(sample)
                logger.warning(
                    "sync.push.tie_action_kept entity=%s incoming_action=%s "
                    "existing_action=%s ledger=%s sync_id=%s device=%s ts=%s "
                    "(not applied, reported rejected)",
                    change.entity_type, change.action, latest_entity_change.action,
                    change.ledger_id, change.entity_sync_id, req.device_id,
                    comparison_ts.isoformat(),
                )
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
                                "incomingUpdatedAt": comparison_ts.isoformat(),
                                # 条件已保证 latest_entity_change 非 None ⇒
                                # existing_lww_tuple 非 None。
                                "existingUpdatedAt": existing_lww_tuple[0].isoformat(),
                                "incomingDeviceId": req.device_id,
                                "existingDeviceId": existing_lww_tuple[1],
                            },
                        )
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
                #
                # F-02:**延后到批循环之后**(`pending_cascade_emissions`)——
                # 旧实现在这里即时 bulk insert,同一批里后到的客户端 tx 编辑
                # 会命中那条 cascade 行的 LWW 槽位(同 ts → 旧 replay 分支吞掉),
                # 客户端以为成功而数据丢失。延后 + updated_at 保持 rename 的 ts
                # ⇒ 显式变更先落、cascade 之后补,事件流顺序与投影一致。
                if prev_entity_name is not None:
                    new_entity_name = str((change.payload or {}).get("name") or "").strip()
                    if new_entity_name and new_entity_name != prev_entity_name:
                        pending_cascade_emissions.append({
                            "entity_type": change.entity_type,
                            "entity_sync_id": change.entity_sync_id,
                            "updated_at": incoming_updated_at,
                        })
                # 共享账本 fan-out:只对 category/account/tag 三种 user-global 类型
                # 推 shared_resource_change(其他 user-global 类型如 device 等不外推)
                if change.entity_type in ("category", "account", "tag"):
                    pending_shared_resource_events.append({
                        "resource_type": change.entity_type,
                        "action": change.action,
                        "sync_id": change.entity_sync_id,
                        # D2:WS 出站同样过滤内部键(与 /sync/pull 同口径);
                        # 入站已 strip,这里是纵深防御 + 不带实现细节给成员端。
                        "payload": _public_payload(
                            change.payload
                        ) or {"sync_id": change.entity_sync_id},
                    })
                    # category delete 的服务端级联会连带删掉子分类(见
                    # sync_applier._delete_user_category_cascade),这些子分类的
                    # delete 也要 fan-out,否则成员端镜像留僵尸子分类。
                    if extra_fanout:
                        pending_shared_resource_events.extend(extra_fanout)
            else:
                assert ledger is not None
                # §7 共享账本:身份字段注入(updatedByUserId / createdByUserId)
                # 已在**幂等判定之前**由 `_inject_actor_ids_early` 完成 ——
                # 阻塞-3 要求 hash 与落库看到同一份 payload(库内 payload_json
                # 是注入后的形态),否则真重放 hash 不匹配 → 重复事件行。
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

        # F-02:cascade-only tx 事件在**全部显式变更之后**补发。语义:
        #   1. 客户端显式变更优先落库(LWW 槽位不被服务端派生事件抢占);
        #   2. cascade 行按 rename 的 ts 写,落后设备 pull 后仍能刷新 denorm
        #      (事件流完整);
        #   3. 补发时投影已是最终状态(rename + 显式编辑都 apply 完),所以
        #      `_emit_user_global_cascade_tx_changes` 点查出的 payload 就是
        #      新名 + 客户端最终金额 —— 同批「rename 后新建/编辑的交易」不再
        #      沿用旧 denorm 名(F-07 的同批分支)。
        for _pend in pending_cascade_emissions:
            _emit_user_global_cascade_tx_changes(
                db,
                actor_user_id=current_user.id,
                device_id=req.device_id,
                updated_at=_pend["updated_at"],
                entity_type=_pend["entity_type"],
                entity_sync_id=_pend["entity_sync_id"],
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
