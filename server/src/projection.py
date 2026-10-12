"""CQRS Q-side projection writers.

snapshot 是权威源。每次 materialize / diff emit 都在**同事务**内把对应的实体
upsert / delete 到这里的 read_*_projection 表。web `/read/*` 路径只查这些表,
不再 parse 3MB 的 ledger_snapshot JSON。

所有函数都只做"按入参写库",不读 snapshot、不关心上下文 —— 上层调用方(sync /
write / admin)负责把正确的 payload 字段拆出来传进来。
"""

from __future__ import annotations

import json
import logging
import math
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable

from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from .models import (
    AttachmentFile,
    Ledger,
    ReadAccountAdjustmentProjection,
    ReadBudgetProjection,
    ReadTxProjection,
    UserAccountProjection,
    UserCategoryProjection,
    UserExchangeRateProjection,
    UserTagProjection,
    utcnow,
)

logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------- #
# Payload 字段提取                                                              #
# --------------------------------------------------------------------------- #
# snapshot items 里的 key 是 camelCase(mobile Flutter 友好);projection 列
# 是 snake_case。这些 helper 把两边对齐。入参宽松:None / 空字符串 / 缺失都
# 当作 None 处理,不抛。
#
# 对抗批次 S2(F-04 / F-12):`float(v)` 裸转会把 `'inf'` / `Infinity` /
# 指数溢出(`'1e400'`)放进 projection 的金额列 —— 落库后所有读路径 / 聚合 /
# CSV 导出 / `/sync/full`(RFC 8259 非法 token)全部中毒。这里的口径:
#
#   - NaN / 不可解析的字符串 / bool  → **拒绝**(抛 InvalidNumericValue,由
#     push 的 savepoint 隔离成 `failed_count++`,不写投影也不留孤儿事件);
#   - ±Infinity / 超出双精度上限(如 `'1e400'` / `10**400`)→ **封顶**到
#     ±DBL_MAX(绝不写非有限值;`/sync/full` 的 `allow_nan=False` 因此不会
#     500,读路径聚合也永远拿到数字)。
#
# 为什么「封顶」而不是「拒绝」:金额语义上 ±Inf 是客户端溢出 / 缺失量纲的
# 产物,折叠到可表示的最大值既保住事件的可用性(客户端拿到确定值、投影不
# 丢行),又不违反 JSON 契约;而 NaN 无法归一(任何确定值都是伪造),必须
# 拒绝。该口径与 `finite_aggregate`(读侧 SUM 溢出封顶)同源。

class InvalidNumericValue(ValueError):
    """投影写入收到无法安全表示 / 归一的数值(NaN、垃圾字符串、bool)。"""


# 双精度最大有限值(避免依赖 sys.float_info 的拼写,显式写死)。
MAX_FINITE_FLOAT = 1.7976931348623157e308


def _coerce_finite(v: Any) -> float:
    """把任意输入归一成**有限** float;NaN / 不可解析 / bool → 抛。

    ``None`` 由调用方决定语义(``_as_float`` 给默认值,``_as_float_or_none``
    保留 NULL),本函数只处理「非 None 的数值输入」。
    """
    if isinstance(v, bool):
        # bool 是 int 子类,True/False 当金额几乎一定是客户端 bug(JSON 形态
        # 里应是数字),静默变 1.0/0.0 属于「静默变形」,直接拒。
        raise InvalidNumericValue("boolean is not a valid number")
    if isinstance(v, (int, float)):
        if isinstance(v, float) and math.isnan(v):
            raise InvalidNumericValue("NaN is not a valid number")
        try:
            f = float(v)
        except OverflowError:
            # 超大整数(10**400)超出双精度上限 → 封顶
            return MAX_FINITE_FLOAT if v > 0 else -MAX_FINITE_FLOAT
        if math.isinf(f):
            return math.copysign(MAX_FINITE_FLOAT, f)
        return f
    if isinstance(v, str):
        s = v.strip()
        if not s:
            raise InvalidNumericValue("empty string is not a valid number")
        try:
            d = Decimal(s)
        except (InvalidOperation, ValueError):
            # `'0x1p3'` / `'abc'` / `'1,5'` —— 旧实现静默归零(float 失败 →
            # 0.0),现在拒绝,让客户端拿到 failed 反馈而不是"金额变 0"。
            raise InvalidNumericValue(f"not a decimal number: {s[:32]!r}") from None
        if d.is_nan():
            raise InvalidNumericValue(f"NaN is not a valid number: {s[:32]!r}")
        try:
            f = float(d)
        except OverflowError:
            # Decimal 指数无上限(`'1e400'`)→ 双精度溢出 → 封顶。
            return MAX_FINITE_FLOAT if d > 0 else -MAX_FINITE_FLOAT
        if math.isinf(f):
            # `'inf'` / `'Infinity'` 字符串字面量 → 封顶(与 float inf 同口径)。
            return math.copysign(MAX_FINITE_FLOAT, f)
        return f
    raise InvalidNumericValue(f"unsupported numeric type: {type(v).__name__}")


def _as_str(v: Any) -> str | None:
    if v is None:
        return None
    s = str(v).strip()
    return s or None


def _as_currency(v: Any) -> str | None:
    """币种代码归一(对齐 web 的 `_normalize_currency`):strip + upper + 截断
    到列宽 String(16)。对抗 F-11(超长 → PG `value too long`)/ F-14
    (push 不归一大小写,与 web 落库值分裂)。"""
    s = _as_str(v)
    if s is None:
        return None
    return s.upper()[:16] or None


def _as_float(v: Any) -> float:
    """金额 / 余额:None → 0.0;非有限 / 不可解析 → 抛(见模块注释)。"""
    if v is None:
        return 0.0
    return _coerce_finite(v)  # type: ignore[return-value]


def _as_float_or_none(v: Any) -> float | None:
    """同 _as_float 但保留 NULL 语义(native_amount 缺失必须落 NULL,
    统计端靠 NULL 触发 COALESCE 回退 amount;默认 0.0 会把统计清零)。"""
    if v is None:
        return None
    return _coerce_finite(v)


def _as_finite_or_none(v: Any) -> float | None:
    """可选数值字段(credit_limit / balance_before / balance_after / 预算
    金额):None 或**无意义值** → None,不抛。

    与 `_as_float_or_none` 的区别:这些列 nullable 且语义上"没填 / 填了非法
    值"的后果一样(展示为空),所以非法输入不阻断整条 change(预算 F-15:
    push 侧金额 -50 / 'inf' 必须与 web 的 `gt=0` 口径对齐 —— 归一成 NULL 而
    不是照原样落库)。
    """
    if v is None:
        return None
    try:
        return _coerce_finite(v)
    except InvalidNumericValue:
        return None


def _as_positive_or_none(v: Any) -> float | None:
    """金额必须 > 0 的字段(预算 amount,web 侧 `Field(gt=0)`):非法 / 非正 →
    None。对抗 F-15:push 曾接受 -50 / 'inf',与 web 422 相反。"""
    f = _as_finite_or_none(v)
    if f is None or f <= 0:
        return None
    return f


def finite_aggregate(value: Any, *, default: float = 0.0) -> float:
    """读路径聚合值归一(对抗 F-12):SUM 溢出成 ±inf / NaN 时,HTTP 层
    `allow_nan=False` 会把它序列化成 `null`(用户看到"合计为空");

    这里封顶到有限值,保证 `expense_total` / `balance` 永远是数字。
    """
    if value is None:
        return default
    try:
        f = float(value)
    except (TypeError, ValueError):
        return default
    if math.isnan(f):
        return default
    if math.isinf(f):
        return math.copysign(MAX_FINITE_FLOAT, f)
    return f


def active_only(model) -> Any:
    """软删过滤谓词(0030 回收站):`deleted_at IS NULL` 的单点口径。

    所有「业务可见」的 projection 点查 / 计数 / 聚合都应带上它;回收站自身
    (`read/trash.py`)与「彻底删除 / 过期清理」走 `deleted_at IS NOT NULL`,
    不走这里。收敛到这里是为了避免 39 处内联写法各自漂移 —— 新增读路径
    请直接 `query.where(active_only(ReadTxProjection))`。
    """
    return model.deleted_at.is_(None)



def _as_int(v: Any, default: int = 0) -> int:
    if v is None:
        return default
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _as_bool(v: Any, default: bool = True) -> bool:
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    if isinstance(v, str):
        return v.strip().lower() in {"true", "1", "yes", "y", "t"}
    return default


def _parse_happened_at(raw: Any):
    """happenedAt 通常是 ISO 8601 字符串,偶见 datetime 对象。"""
    from datetime import datetime, timezone

    if raw is None:
        return datetime.now(timezone.utc)
    if isinstance(raw, datetime):
        return raw if raw.tzinfo is not None else raw.replace(tzinfo=timezone.utc)
    if isinstance(raw, str):
        s = raw.strip()
        if not s:
            return datetime.now(timezone.utc)
        # Python 3.11+ fromisoformat 吃 "Z" 结尾
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        except ValueError:
            return datetime.now(timezone.utc)
    return datetime.now(timezone.utc)


# --------------------------------------------------------------------------- #
# Dialect 中立的 upsert                                                         #
# --------------------------------------------------------------------------- #
# SQLite / PostgreSQL 都用 INSERT ... ON CONFLICT DO UPDATE。SQLAlchemy 的
# `dialects.sqlite.insert` 在两种库上语法基本一致;`dialects.postgresql.insert`
# 同理。我们按 bind 方言走对应 insert,fallback 到先 SELECT 再 UPDATE/INSERT。

def _is_sqlite(bind) -> bool:
    try:
        name = bind.dialect.name if hasattr(bind, "dialect") else bind.bind.dialect.name
    except AttributeError:
        return True
    return name == "sqlite"


def _upsert(db: Session, model, pk_fields: tuple[str, ...], values: dict) -> None:
    """通用 upsert:主键撞了就 UPDATE 其他所有列。

    S12-①:按 bind 方言选 insert 构造器 —— 之前一律用 SQLite 方言 insert
    跑在 PG 上,靠两方言 ON CONFLICT 语法恰好兼容才没炸;引入任一方言
    特性(例如 PG 的 index_where / sqlite 的 OR REPLACE)即断。现在
    SQLite / PG 各走各的方言 insert,其余方言 fallback 到 merge 风格。
    """
    bind = db.get_bind()
    dialect_name = getattr(bind.dialect, "name", "")
    if dialect_name in ("sqlite", "postgresql"):
        insert_ctor = sqlite_insert if dialect_name == "sqlite" else pg_insert
        stmt = insert_ctor(model).values(**values)
        update_cols = {k: stmt.excluded[k] for k in values.keys() if k not in pk_fields}
        if update_cols:
            stmt = stmt.on_conflict_do_update(
                index_elements=list(pk_fields), set_=update_cols
            )
        else:
            # 没有非主键列要改(理论不会发生),退化成 DO NOTHING
            stmt = stmt.on_conflict_do_nothing(index_elements=list(pk_fields))
        db.execute(stmt)
        return

    # 兜底:未知方言用 merge 风格(select → insert or update)
    filters = [getattr(model, k) == values[k] for k in pk_fields]
    existing = db.scalar(select(model).where(*filters))
    if existing is None:
        db.add(model(**values))
    else:
        for k, v in values.items():
            if k not in pk_fields:
                setattr(existing, k, v)


# --------------------------------------------------------------------------- #
# 单实体:upsert / delete                                                       #
# --------------------------------------------------------------------------- #

def _auth_name_cache(db: Session) -> dict[str, Any]:
    """请求级(per-session)权威 denorm 名缓存。

    F-07 的 denorm 回填(分类名 / 账户名)对同一实体在一条 push 批里会被
    反复查 —— 400 条 tx 指向同一个分类/账户时,逐条点查 = 800 次冗余 SELECT,
    在 worker 线程里拖长 GIL 占用(实测会让 event-loop 探针漂移)。
    缓存在 `db.info`(SQLAlchemy 官方 per-session 字典)上,请求结束即回收,
    不会跨请求泄漏脏值。

    **失效契约**:任何**权威实体**(account / category / tag)自身的 upsert /
    delete 都必须调用 `_invalidate_auth_name_cache(db)` —— 否则同批
    「先 tx(缓存旧名)→ 再 rename → 再 tx」的第二个 tx 会拿到过期名
    (F-07 的漂移换了个形态复现)。缓存是请求级廉价的,整块清即可。

    结构:``{"cat": {sync_id: (name, kind)}, "acc": {sync_id: name},
    "tag_deleted": set, "tag_seen": set}``。
    """
    cache = db.info.get("_sb_auth_denorm_cache")
    if cache is None:
        cache = {"cat": {}, "acc": {}, "tag_deleted": set(), "tag_seen": set()}
        db.info["_sb_auth_denorm_cache"] = cache
    return cache


def _invalidate_auth_name_cache(db: Session) -> None:
    """权威实体(account / category / tag)变更后清空 denorm 名缓存。

    调用点:各 user-global 实体的 upsert_* / delete_*。清整块而不是只删一项:
    缓存只在单请求内有效,重建成本是一次点查,而「漏删一项」的后果是 denorm
    名永久漂移(比一次多余 SELECT 严重得多)。
    """
    db.info.pop("_sb_auth_denorm_cache", None)


def _resolve_account_sync_id_by_name(
    db: Session, *, user_id: str, name: str | None
) -> str | None:
    """按 (user_id, name) 唯一反查 user_account_projection 的 sync_id。

    #41:老 web / 前端映射 miss 的交易只带账户名不带 id → 投影 account_sync_id
    为 NULL,被 sync_id 维度的统计/过滤漏算。恰好一个命中才补(0 个或同名多账户
    返回 None,宁缺勿错);与 mobile sync_engine_apply 的按名 fallback 同语义。
    """
    if not name:
        return None
    rows = db.scalars(
        select(UserAccountProjection.sync_id)
        .where(
            UserAccountProjection.user_id == user_id,
            UserAccountProjection.name == name,
        )
        .limit(2)
    ).all()
    return rows[0] if len(rows) == 1 else None


def upsert_tx(
    db: Session,
    *,
    ledger_id: str,
    user_id: str,
    source_change_id: int,
    payload: dict[str, Any],
) -> None:
    sync_id = _as_str(payload.get("syncId"))
    if sync_id is None:
        return
    tags_raw = payload.get("tags")
    if isinstance(tags_raw, list):
        tags_csv = ",".join(str(t).strip() for t in tags_raw if str(t).strip())
    else:
        tags_csv = _as_str(tags_raw)

    tag_sync_ids = payload.get("tagIds")
    tag_sync_ids_json = json.dumps(tag_sync_ids) if isinstance(tag_sync_ids, list) else None

    attachments = payload.get("attachments")
    attachments_json = (
        json.dumps(attachments) if isinstance(attachments, list) and attachments else None
    )

    tx_type = (
        _as_str(payload.get("txType"))
        or _as_str(payload.get("tx_type"))
        or _as_str(payload.get("type"))
        or "expense"
    )

    # --- F-07 投影 denorm 名以**权威实体行**为准 -------------------------- #
    # 离线设备推的旧 payload 带着改名前的 categoryName / accountName;merge 只
    # 补 None 字段,不校验 FK 一致性 → 同一 FK 的两个 denorm 副本分裂(web 交易
    # 列表显示旧分类名,分类列表显示新名)。这里在落盘前按稳定 FK
    # (category_sync_id / account_sync_id / from / to)点查权威行回填。
    #
    # 谓词按 sync_id 且**不按 user_id**(P0-1 契约):共享账本 tx 投影行的
    # user_id 是 ledger owner,而 user-global 实体行按操作者存;两者不一致时
    # 按 sync_id 匹配才不会漏。查不到权威行(离线先到 / 老数据)时保留 payload
    # 原值 —— 宁缺勿错,等实体行到位后由 rename cascade 统一纠正。
    category_sync_id = _as_str(payload.get("categoryId"))
    category_name = _as_str(payload.get("categoryName"))
    category_kind = _as_str(payload.get("categoryKind"))
    if category_sync_id:
        _cache = _auth_name_cache(db)
        if category_sync_id not in _cache["cat"]:
            cat_row = db.execute(
                select(UserCategoryProjection.name, UserCategoryProjection.kind)
                .where(UserCategoryProjection.sync_id == category_sync_id)
                .order_by(UserCategoryProjection.source_change_id.desc())
                .limit(1)
            ).first()
            _cache["cat"][category_sync_id] = (
                (_as_str(cat_row[0]), _as_str(cat_row[1])) if cat_row is not None else None
            )
        auth_cat = _cache["cat"][category_sync_id]
        if auth_cat is not None:
            if auth_cat[0]:
                category_name = auth_cat[0]
            if auth_cat[1]:
                category_kind = auth_cat[1]

    account_sync_id = _as_str(payload.get("accountId"))
    account_name = _as_str(payload.get("accountName"))
    from_account_sync_id = _as_str(payload.get("fromAccountId"))
    from_account_name = _as_str(payload.get("fromAccountName"))
    to_account_sync_id = _as_str(payload.get("toAccountId"))
    to_account_name = _as_str(payload.get("toAccountName"))
    _acc_ids = [
        sid for sid in (account_sync_id, from_account_sync_id, to_account_sync_id) if sid
    ]
    if _acc_ids:
        _cache = _auth_name_cache(db)
        missing = [sid for sid in _acc_ids if sid not in _cache["acc"]]
        if missing:
            for sid, nm in db.execute(
                select(UserAccountProjection.sync_id, UserAccountProjection.name).where(
                    UserAccountProjection.sync_id.in_(missing)
                )
            ).all():
                _cache["acc"][sid] = _as_str(nm)
            for sid in missing:
                _cache["acc"].setdefault(sid, None)
        if _cache["acc"].get(account_sync_id):
            account_name = _cache["acc"][account_sync_id]
        if _cache["acc"].get(from_account_sync_id):
            from_account_name = _cache["acc"][from_account_sync_id]
        if _cache["acc"].get(to_account_sync_id):
            to_account_name = _cache["acc"][to_account_sync_id]

    # --- F-08 悬挂 tag 引用剥离 ------------------------------------------- #
    # tag 删除后离线设备推回旧 payload(tags/tagIds 仍带该标签)→ 引用复活成
    # 永久孤儿(标签列表里没有,`cascade_tx_rows_for_tag` 却还会为它补发事件)。
    # 只剥离**有 delete 墓碑**的 tag —— 从未同步过的 tag(先建交易后同步标签)
    # 必须保留,否则离线排序的合法数据被削平。
    if isinstance(tag_sync_ids, list) and tag_sync_ids:
        from .models import SyncChange as _SyncChange  # 局部 import 防循环

        _cache = _auth_name_cache(db)
        tombstoned = _cache.setdefault("tag_deleted", set())
        _cand = [str(t) for t in tag_sync_ids]
        _unknown = [t for t in _cand if t not in _cache.setdefault("tag_seen", set())]
        if _unknown:
            tombstoned.update(db.scalars(
                select(_SyncChange.entity_sync_id).where(
                    _SyncChange.entity_type == "tag",
                    _SyncChange.entity_sync_id.in_(_unknown),
                    _SyncChange.action == "delete",
                )
            ).all())
            _cache["tag_seen"].update(_unknown)
        hit = [t for t in _cand if t in tombstoned]
        if hit:
            kept_ids = [t for t in tag_sync_ids if str(t) not in tombstoned]
            if kept_ids:
                tag_sync_ids_json = json.dumps(kept_ids)
            else:
                # 该交易的标签全部指向已删标签 → id 与 name 一起清干净,
                # 否则 web 列表仍显示一个标签列表里不存在的名字。
                tag_sync_ids_json = None
                tags_csv = None

    # F11:prev 行只查一次,三个用途共用 —— (1) 附件 GC diff;(2) created_by
    # first-write-wins;(3) created_at 首插盖章。旧实现对同一行做了 3 次独立
    # SELECT + collect_tx_attachment_fileids 再 1 次,push 500 条 = 2500 次点查。
    prev_row = db.execute(
        select(
            ReadTxProjection.attachments_json,
            ReadTxProjection.created_by_user_id,
            ReadTxProjection.created_at,
        ).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
        )
    ).first()
    prev_file_ids = _extract_tx_cloud_file_ids(prev_row[0]) if prev_row else set()
    existing_creator = prev_row[1] if prev_row else None
    existing_created_at = prev_row[2] if prev_row else None

    # 共享账本:created_by_user_id 一旦写入就不能被后续 upsert 覆盖
    # (B 编辑 A 创建的 tx 时,payload 不带 createdByUserId,如果 _upsert
    # 把列设成 NULL,server 端 created_by 信息就丢了)。prev_row 查过,
    # payload 没带 created → 保留 existing.created_by_user_id。
    payload_creator = _as_str(payload.get("createdByUserId"))

    # 记录时间(0024):首次插入盖章为服务端当前时刻;已有行保留旧值(update
    # 不刷新)。客户端不提交,也不读 payload —— snapshot/pull 下发键为
    # createdAt。存量迁移行(0024 之前)保持 NULL。

    values = {
        "ledger_id": ledger_id,
        "sync_id": sync_id,
        "user_id": user_id,
        "tx_type": tx_type,
        "amount": _as_float(payload.get("amount")),
        "happened_at": _parse_happened_at(
            payload.get("happenedAt") or payload.get("happened_at")
        ),
        "created_at": existing_created_at or utcnow(),
        "note": _as_str(payload.get("note")),
        "category_sync_id": category_sync_id,
        "category_name": category_name,
        "category_kind": category_kind,
        "account_sync_id": account_sync_id,
        "account_name": account_name,
        "from_account_sync_id": from_account_sync_id,
        "from_account_name": from_account_name,
        "to_account_sync_id": to_account_sync_id,
        "to_account_name": to_account_name,
        "tags_csv": tags_csv,
        "tag_sync_ids_json": tag_sync_ids_json,
        "attachments_json": attachments_json,
        "tx_index": _as_int(payload.get("txIndex") or payload.get("tx_index"), default=0),
        # 创建人 first-write-wins:有 existing 就保留;首次插入用 payload 或回退
        # 到当前 actor(updatedByUserId)。
        "created_by_user_id": existing_creator
            or payload_creator
            or _as_str(payload.get("updatedByUserId")),
        # 共享账本 Phase 1:每次 upsert 都更新 last_edited_by_user_id;
        # payload 没带就回退 created。
        "last_edited_by_user_id": _as_str(payload.get("updatedByUserId")) or payload_creator,
        # 账单标记(.docs/transaction-flags)。缺键保留由上游 merge_with_existing
        # 负责(payload 已含既有行值),这里只做布尔强转;default=False 兜底首次插入。
        "exclude_from_stats": _as_bool(payload.get("excludeFromStats"), default=False),
        "exclude_from_budget": _as_bool(payload.get("excludeFromBudget"), default=False),
        # 交易级多币种(0018):缺键保留由上游 merge_with_existing 负责;首次
        # 插入且旧 payload 无字段 → NULL(统计端 COALESCE 回退 amount)。
        # F-14:归一(strip+upper+截断 16)与 web `_normalize_currency` 同口径 ——
        # 旧实现原样透传,'usd' 与 'EUR' 在按原值分组的下游被当成两种币。
        "currency_code": _as_currency(payload.get("currencyCode")),
        "native_amount": _as_float_or_none(payload.get("nativeAmount")),
        # P0-5 复活语义(2026-09):upsert 是「此实体存在且内容如此」的声明,
        # 能通过 LWW 胜出的 upsert 同时清软删标记(与 trash restore 对齐,
        # 见 SYNC_ARCHITECTURE §4.8)。老语义「不清 deleted_at 但照常广播
        # upsert」会让 pull 端重建交易而服务端读路径/统计视其不存在(幽灵
        # 交易)。首次插入时列默认也是 NULL,行为不变。
        "deleted_at": None,
        "source_change_id": source_change_id,
    }

    # #41:payload 只带名不带 id 时(老 web / 前端映射 miss),按名唯一反查补全。
    # 三组 account 字段各自独立处理;同名多账户保持 NULL,宁缺勿错。
    for id_key, name_key in (
        ("account_sync_id", "account_name"),
        ("from_account_sync_id", "from_account_name"),
        ("to_account_sync_id", "to_account_name"),
    ):
        if values[id_key] is None and values[name_key]:
            values[id_key] = _resolve_account_sync_id_by_name(
                db, user_id=user_id, name=values[name_key]
            )

    _upsert(db, ReadTxProjection, ("ledger_id", "sync_id"), values)

    # 新行已落地,对 prev - new 的 fileId 查还有无引用 → GC。
    # gc_orphan_attachments 契约要求新行就位后再调,这里顺序正确。
    new_file_ids = _extract_tx_cloud_file_ids(attachments_json)
    removed = prev_file_ids - new_file_ids
    if removed:
        gc_orphan_attachments(db, user_id=user_id, file_ids=removed)


def upsert_account(
    db: Session,
    *,
    user_id: str,
    source_change_id: int,
    payload: dict[str, Any],
) -> None:
    """user-global account upsert。PK=(user_id, sync_id),跟账本无关。"""
    sync_id = _as_str(payload.get("syncId"))
    if sync_id is None:
        return

    # 扩展字段读 snapshot 的 camelCase key,空 / 非法数转 None。这些字段是
    # nullable 的(老 snapshot 没这些 key 时落 None,前端展示空)。
    #
    # 建议-13②:`_opt_float` 是内联副本(旧实现无 isfinite 守卫,NaN/inf
    # 可落库)。本批统一收敛到模块级 `_as_finite_or_none`,删掉两份重复实现。
    def _opt_int(raw: Any) -> int | None:
        if raw is None:
            return None
        try:
            return int(raw)
        except (TypeError, ValueError):
            return None

    values = {
        "user_id": user_id,
        "sync_id": sync_id,
        "name": _as_str(payload.get("name")),
        "account_type": _as_str(payload.get("type")),
        # F-14:币种归一(strip+upper+截断 16)与 web `_normalize_currency` 同口径。
        "currency": _as_currency(payload.get("currency")),
        "initial_balance": _as_float(payload.get("initialBalance")),
        "note": _as_str(payload.get("note")),
        "credit_limit": _as_finite_or_none(payload.get("creditLimit")),
        "billing_day": _opt_int(payload.get("billingDay")),
        "payment_due_day": _opt_int(payload.get("paymentDueDay")),
        "bank_name": _as_str(payload.get("bankName")),
        "card_last_four": _as_str(payload.get("cardLastFour")),
        # 账户隐藏(issue #240)。merge_with_existing_user 已把缺键的 hidden
        # 从旧行补齐,这里直接取 merged payload 的值;全新 insert 首次缺失时给
        # False(未隐藏)。
        "hidden": _as_bool(payload.get("hidden"), default=False),
        "source_change_id": source_change_id,
    }
    _upsert(db, UserAccountProjection, ("user_id", "sync_id"), values)
    # F-07 缓存失效:权威账户行变更 → 后续 tx 的 denorm 回填必须重新查。
    _invalidate_auth_name_cache(db)


def upsert_category(
    db: Session,
    *,
    user_id: str,
    source_change_id: int,
    payload: dict[str, Any],
) -> None:
    """user-global category upsert。PK=(user_id, sync_id),跟账本无关。"""
    sync_id = _as_str(payload.get("syncId"))
    if sync_id is None:
        return

    # 取 prev icon_cloud_file_id —— upsert 后跟 new 比对,若变更则 GC 旧 attachment。
    # 防止用户在 web 点 "remove 自定义图标" 后旧 cloud blob 永远成孤儿。
    prev_icon_file_id: str | None = None
    prev_row = db.scalar(
        select(UserCategoryProjection.icon_cloud_file_id).where(
            UserCategoryProjection.user_id == user_id,
            UserCategoryProjection.sync_id == sync_id,
        )
    )
    if prev_row:
        prev_icon_file_id = prev_row.strip() if isinstance(prev_row, str) else None

    # 共享账本父子稳定关系:优先用 payload['parentSyncId'](mobile entity_serializer
    # / web snapshot_mutator 写入);若没有(老 client / 老数据),按
    # (user_id, parent_name, kind, level=1) 反查同 user 的 level=1 行兜底。
    parent_name = _as_str(payload.get("parentName"))
    parent_sync_id = _as_str(payload.get("parentSyncId"))
    if parent_sync_id is None and parent_name:
        parent_sync_id = db.scalar(
            select(UserCategoryProjection.sync_id).where(
                UserCategoryProjection.user_id == user_id,
                UserCategoryProjection.name == parent_name,
                UserCategoryProjection.kind == _as_str(payload.get("kind")),
                func.coalesce(UserCategoryProjection.level, 1) == 1,
            )
        )

    values = {
        "user_id": user_id,
        "sync_id": sync_id,
        "name": _as_str(payload.get("name")),
        "kind": _as_str(payload.get("kind")),
        "level": _as_int(payload.get("level"), default=0) if payload.get("level") is not None else None,
        "sort_order": _as_int(payload.get("sortOrder"), default=0)
        if payload.get("sortOrder") is not None
        else None,
        "icon": _as_str(payload.get("icon")),
        "icon_type": _as_str(payload.get("iconType")),
        "custom_icon_path": _as_str(payload.get("customIconPath")),
        "icon_cloud_file_id": _as_str(payload.get("iconCloudFileId")),
        "icon_cloud_sha256": _as_str(payload.get("iconCloudSha256")),
        "parent_name": parent_name,
        "parent_sync_id": parent_sync_id,
        "source_change_id": source_change_id,
    }
    _upsert(db, UserCategoryProjection, ("user_id", "sync_id"), values)
    # F-07 缓存失效:权威分类行变更(name/kind)→ 后续 tx 的 denorm 回填
    # 必须重新查,否则同批「先 tx(缓存旧名)→ 再 rename → 再 tx」漂移。
    _invalidate_auth_name_cache(db)

    # 如果 prev_icon_file_id 跟新值不一样(包括清空、换图),且 prev 不是空,
    # 把旧 fileId 交给 gc_orphan_attachments —— 真孤儿才删 AttachmentFile +
    # 物理文件,被共用的会留着。
    new_icon_file_id = _as_str(payload.get("iconCloudFileId")) or None
    if prev_icon_file_id and prev_icon_file_id != new_icon_file_id:
        gc_orphan_attachments(db, user_id=user_id, file_ids=[prev_icon_file_id])


def upsert_tag(
    db: Session,
    *,
    user_id: str,
    source_change_id: int,
    payload: dict[str, Any],
) -> None:
    """user-global tag upsert。PK=(user_id, sync_id),跟账本无关。"""
    sync_id = _as_str(payload.get("syncId"))
    if sync_id is None:
        return
    # F-11:color 列声明 String(32);push payload 无长度校验,超长在 PG 上会
    # `value too long` 整批失败(SQLite 静默)。按列宽截断。
    color = _as_str(payload.get("color"))
    values = {
        "user_id": user_id,
        "sync_id": sync_id,
        "name": _as_str(payload.get("name")),
        "color": color[:32] if color else None,
        "source_change_id": source_change_id,
    }
    _upsert(db, UserTagProjection, ("user_id", "sync_id"), values)
    _invalidate_auth_name_cache(db)


def upsert_budget(
    db: Session,
    *,
    ledger_id: str,
    user_id: str,
    source_change_id: int,
    payload: dict[str, Any],
) -> None:
    """预算 upsert。

    F-15:push 侧历史无任何校验,`amount = -50` / `'inf'` 原样落库,而 web 侧
    `WriteBudgetCreateRequest.amount: float = Field(gt=0)` 直接 422 —— 同一
    操作两条路径语义相反(mobile 能建出负预算,UI 进度条/剩余额崩坏)。
    这里对齐 web 口径:金额非有限 / 非正 → NULL(展示为空,不阻断整批)。
    """
    sync_id = _as_str(payload.get("syncId"))
    if sync_id is None:
        return
    values = {
        "ledger_id": ledger_id,
        "sync_id": sync_id,
        "user_id": user_id,
        "budget_type": _as_str(payload.get("type")),
        "category_sync_id": _as_str(payload.get("categoryId")),
        "amount": _as_positive_or_none(payload.get("amount")),
        "period": _as_str(payload.get("period")),
        "start_day": _as_int(payload.get("startDay"), default=1)
        if payload.get("startDay") is not None
        else None,
        "enabled": _as_bool(payload.get("enabled"), default=True),
        "source_change_id": source_change_id,
    }
    _upsert(db, ReadBudgetProjection, ("ledger_id", "sync_id"), values)


def delete_entity(
    db: Session, model, *, ledger_id: str, sync_id: str
) -> None:
    db.execute(
        delete(model).where(
            model.ledger_id == ledger_id,
            model.sync_id == sync_id,
        )
    )


def delete_tx(db: Session, *, ledger_id: str, sync_id: str) -> None:
    """交易删除 → 软删(0030 回收站):写 deleted_at,读路径/统计/导出统一
    过滤;30 天后 cleaner 物理删除。恢复见 read/trash.py 的 restore。
    行不存在时静默返回(幂等,与旧行为一致)。"""
    db.execute(
        update(ReadTxProjection)
        .where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
            ReadTxProjection.deleted_at.is_(None),
        )
        .values(deleted_at=func.now())
    )


def purge_tx(db: Session, *, ledger_id: str, sync_id: str) -> None:
    """物理删除(回收站「彻底删除」/过期清理专用)。幂等。"""
    db.execute(
        delete(ReadTxProjection).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
        )
    )


def restore_tx(db: Session, *, ledger_id: str, sync_id: str) -> bool:
    """回收站恢复:软删标记置回 NULL。返回是否确有恢复(行存在且在回收站)。"""
    result = db.execute(
        update(ReadTxProjection)
        .where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
            ReadTxProjection.deleted_at.is_not(None),
        )
        .values(deleted_at=None)
    )
    return bool(result.rowcount)


def delete_account(db: Session, *, user_id: str, sync_id: str) -> None:
    """user-global account delete。PK=(user_id, sync_id)。"""
    _invalidate_auth_name_cache(db)
    db.execute(
        delete(UserAccountProjection).where(
            UserAccountProjection.user_id == user_id,
            UserAccountProjection.sync_id == sync_id,
        )
    )


def delete_category(db: Session, *, user_id: str, sync_id: str) -> None:
    """user-global category delete。PK=(user_id, sync_id)。"""
    _invalidate_auth_name_cache(db)
    db.execute(
        delete(UserCategoryProjection).where(
            UserCategoryProjection.user_id == user_id,
            UserCategoryProjection.sync_id == sync_id,
        )
    )


def delete_tag(db: Session, *, user_id: str, sync_id: str) -> None:
    """user-global tag delete。PK=(user_id, sync_id)。"""
    _invalidate_auth_name_cache(db)
    db.execute(
        delete(UserTagProjection).where(
            UserTagProjection.user_id == user_id,
            UserTagProjection.sync_id == sync_id,
        )
    )


def delete_budget(db: Session, *, ledger_id: str, sync_id: str) -> None:
    delete_entity(db, ReadBudgetProjection, ledger_id=ledger_id, sync_id=sync_id)



def _server_side_account_balance(
    db: Session, *, ledger_id: str, account_sync_id: str
) -> float | None:
    """服务端视角的账户当前余额(调整写入前):初始余额 + Σ收支 ± 转账 + Σ此前调整。

    与 /read/workspace accounts 的 balance 口径同源(初始值+流水+调整);
    仅用于审计快照校验,失败/缺账户返回 None(不阻断写入)。
    """
    from .models import ReadAccountAdjustmentProjection, UserAccountProjection

    if not account_sync_id:
        return None
    init = db.scalar(
        select(UserAccountProjection.initial_balance).where(
            UserAccountProjection.user_id
            == db.scalar(
                select(ReadTxProjection.user_id).where(
                    ReadTxProjection.ledger_id == ledger_id
                ).limit(1)
            ),
            UserAccountProjection.sync_id == account_sync_id,
        )
    )
    if init is None:
        # 账户不在 user 投影里(可能来自别的设备且未同步账户)——无法校验
        return None
    income = db.scalar(
        select(func.coalesce(func.sum(ReadTxProjection.amount), 0.0)).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.deleted_at.is_(None),
            ReadTxProjection.account_sync_id == account_sync_id,
            ReadTxProjection.tx_type == "income",
        )
    ) or 0.0
    expense = db.scalar(
        select(func.coalesce(func.sum(ReadTxProjection.amount), 0.0)).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.deleted_at.is_(None),
            ReadTxProjection.account_sync_id == account_sync_id,
            ReadTxProjection.tx_type == "expense",
        )
    ) or 0.0
    out_transfer = db.scalar(
        select(func.coalesce(func.sum(ReadTxProjection.amount), 0.0)).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.deleted_at.is_(None),
            ReadTxProjection.from_account_sync_id == account_sync_id,
            ReadTxProjection.tx_type == "transfer",
        )
    ) or 0.0
    in_transfer = db.scalar(
        select(func.coalesce(func.sum(ReadTxProjection.amount), 0.0)).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.deleted_at.is_(None),
            ReadTxProjection.to_account_sync_id == account_sync_id,
            ReadTxProjection.tx_type == "transfer",
        )
    ) or 0.0
    prior_adj = db.scalar(
        select(func.coalesce(
            func.sum(ReadAccountAdjustmentProjection.amount), 0.0
        )).where(
            ReadAccountAdjustmentProjection.ledger_id == ledger_id,
            ReadAccountAdjustmentProjection.account_sync_id == account_sync_id,
        )
    ) or 0.0
    return float(init) + float(income) - float(expense) - float(out_transfer) + float(in_transfer) + float(prior_adj)


def upsert_account_adjustment(
    db: Session,
    *,
    ledger_id: str,
    user_id: str,
    source_change_id: int,
    payload: dict[str, Any],
) -> None:
    """余额调整记录 upsert(0028)。amount 带符号,正=调增负=调减。

    balance_before/after 是审计快照,统计不读;缺键时落 NULL(旧 payload /
    partial update 由上游 merge 补齐,这里只兜首次插入)。
    created_at 同 tx 的 0024 契约:首次插入服务端盖章,update 保留。
    """
    sync_id = _as_str(payload.get("syncId"))
    if sync_id is None:
        return

    existing_row = db.execute(
        select(
            ReadAccountAdjustmentProjection.created_at,
            ReadAccountAdjustmentProjection.created_by_user_id,
        ).where(
            ReadAccountAdjustmentProjection.ledger_id == ledger_id,
            ReadAccountAdjustmentProjection.sync_id == sync_id,
        )
    ).first()
    existing = existing_row[0] if existing_row else None
    existing_creator = existing_row[1] if existing_row else None

    # 建议-13②:第二处内联 `_opt_float` 同样缺 isfinite 守卫 → 统一收敛到
    # 模块级 `_as_finite_or_none`(balance_before / balance_after 是可选审计
    # 快照,非法值归 NULL 比落 inf 更安全)。
    account_sync_id = _as_str(payload.get("accountId")) or ""

    # 批次4(审计快照校验):balance_before 是客户端自报的本地余额,离线多日
    # 后补记时往往已过期,事后对账会误导。首次插入时按服务端投影现算一遍,
    # 与自报差异 > 1 元则以服务端值为准(balanceAfter 同步平移差额),
    # 让审计记录始终可与「服务端视角」对上。
    amount_val = _as_float(payload.get("amount"))
    balance_before_val = _as_finite_or_none(payload.get("balanceBefore"))
    balance_after_val = _as_finite_or_none(payload.get("balanceAfter"))
    if existing is None and balance_before_val is not None:
        try:
            server_before = _server_side_account_balance(
                db, ledger_id=ledger_id, account_sync_id=account_sync_id,
            )
        except Exception:  # noqa: BLE001 — 审计校验失败不阻断调整写入
            server_before = None
        if server_before is not None and abs(server_before - balance_before_val) > 1.0:
            delta = (
                balance_after_val - balance_before_val
                if balance_after_val is not None
                else amount_val
            )
            balance_before_val = server_before
            balance_after_val = (
                round(server_before + delta, 2)
                if balance_after_val is not None
                else balance_after_val
            )

    values = {
        "ledger_id": ledger_id,
        "sync_id": sync_id,
        "user_id": user_id,
        "account_sync_id": account_sync_id,
        "account_name": _as_str(payload.get("accountName")),
        "amount": amount_val,
        "balance_before": balance_before_val,
        "balance_after": balance_after_val,
        "happened_at": _parse_happened_at(payload.get("happenedAt")),
        "created_at": existing or utcnow(),
        "note": _as_str(payload.get("note")),
        "created_by_user_id": existing_creator
        or _as_str(payload.get("createdByUserId"))
        or _as_str(payload.get("updatedByUserId")),
        "last_edited_by_user_id": _as_str(payload.get("updatedByUserId"))
        or _as_str(payload.get("createdByUserId")),
        "source_change_id": source_change_id,
    }
    _upsert(db, ReadAccountAdjustmentProjection, ("ledger_id", "sync_id"), values)


def delete_account_adjustment(
    db: Session, *, ledger_id: str, sync_id: str
) -> None:
    delete_entity(
        db, ReadAccountAdjustmentProjection, ledger_id=ledger_id, sync_id=sync_id
    )


# --------------------------------------------------------------------------- #
# Rename cascade                                                               #
# --------------------------------------------------------------------------- #
# 当 account / category / tag 的 name 改了,tx projection 里引用它的 denorm
# 列也要同步更新。snapshot 里已经有同样 cascade 逻辑(见
# sync.py._materialize_individual_changes),这里做对应 SQL。

def rename_cascade_account(
    db: Session,
    *,
    user_id: str,
    account_sync_id: str,
    new_name: str | None,
) -> None:
    """account 是 user-global,rename 时刷遍引用该账户的所有
    read_tx_projection / read_account_adjustment_projection 行。

    P0-1 契约(2026-09):匹配谓词按稳定 FK 列(account_sync_id /
    from_account_sync_id / to_account_sync_id),**不按 user_id** —— 共享账本
    里 tx 投影行的 user_id 是 ledger owner,操作者可能是 Editor,按
    `user_id == 操作者` 过滤会漏掉 owner 名下的行(denorm 永久旧名)。
    sync_id 是 UUID,跨用户碰撞可忽略;禁止用「ledger ∈ 该用户可访问集合」
    收窄匹配。user_id 参数仅为签名兼容保留,不参与过滤。
    """
    db.execute(
        update(ReadTxProjection)
        .where(
            ReadTxProjection.account_sync_id == account_sync_id,
        )
        .values(account_name=new_name)
    )
    db.execute(
        update(ReadTxProjection)
        .where(
            ReadTxProjection.from_account_sync_id == account_sync_id,
        )
        .values(from_account_name=new_name)
    )
    db.execute(
        update(ReadTxProjection)
        .where(
            ReadTxProjection.to_account_sync_id == account_sync_id,
        )
        .values(to_account_name=new_name)
    )
    # 余额调整记录(0028)的 account_name 冗余列一起刷。同样按 account_sync_id
    # 稳定 FK 匹配(调整行 user_id = ledger owner,操作者可能是 Editor)。
    db.execute(
        update(ReadAccountAdjustmentProjection)
        .where(
            ReadAccountAdjustmentProjection.account_sync_id == account_sync_id,
        )
        .values(account_name=new_name)
    )


def rename_cascade_category(
    db: Session,
    *,
    user_id: str,
    category_sync_id: str,
    new_name: str | None,
    new_kind: str | None = None,
) -> None:
    """category 是 user-global,rename 时刷遍引用该分类的所有
    read_tx_projection 行。谓词同 rename_cascade_account:按
    category_sync_id 稳定 FK 匹配,不按 user_id(P0-1 契约,详见其 docstring)。
    user_id 参数仅为签名兼容保留。"""
    values: dict[str, Any] = {"category_name": new_name}
    if new_kind is not None:
        values["category_kind"] = new_kind
    db.execute(
        update(ReadTxProjection)
        .where(
            ReadTxProjection.category_sync_id == category_sync_id,
        )
        .values(**values)
    )


def rename_cascade_tag(
    db: Session,
    *,
    user_id: str,
    tag_sync_id: str,
    old_name: str,
    new_name: str,
) -> None:
    """Tag rename 走 tags_csv 字符串替换。tag 是 user-global,刷所有引用该
    tag 的 tx 行。用 Python 做字符串替换比纯 SQL 的 REPLACE 更安全(避免
    name 是别的 tag 的 substring 时误伤)。

    P0-1 契约:by-id 分支(tag_sync_ids_json 精确引用,稳定 FK)不按
    user_id 过滤 —— 共享账本 tx 投影行 user_id=owner,操作者可能是
    Editor;by-name legacy 分支(无 id 老数据)仍按 user_id 收窄,名字不是
    稳定 FK,跨用户同名会误伤。

    F13:只取 (ledger_id, sync_id, tags_csv) 三列(旧版水化整行 ORM 实体,
    2 万行 = 2 万个全列对象),更新走轻量 Core UPDATE(逐行,SQLite 单连接
    下无批收益,省的是 ORM 脏跟踪开销)。
    """
    from sqlalchemy import select as sql_select
    from sqlalchemy import update as sql_update

    if not old_name or not new_name or old_name == new_name:
        return
    # 两条查询取并集:
    #   1) tag_sync_ids_json 精确引用了该 tag sync_id (mobile/web 完整数据)
    #   2) tags_csv 包含旧名称但没有 tag_sync_ids_json (legacy/不完整数据)
    like_pat = f'%"{tag_sync_id}"%'
    rows_by_id = db.execute(
        sql_select(ReadTxProjection.ledger_id, ReadTxProjection.sync_id, ReadTxProjection.tags_csv)
        .where(
            ReadTxProjection.tag_sync_ids_json.like(like_pat),
        )
    ).all()
    # tags_csv 可能是 "旧标签" 或 "A,旧标签,B" 等逗号分隔形式;
    # 用 LIKE 做粗筛,Python 侧按逗号拆分精确匹配防 substring 误伤。
    # legacy 分支按 user_id 收窄(见 docstring)。
    like_name = f"%{old_name}%"
    rows_by_name = db.execute(
        sql_select(ReadTxProjection.ledger_id, ReadTxProjection.sync_id, ReadTxProjection.tags_csv)
        .where(
            ReadTxProjection.user_id == user_id,
            ReadTxProjection.tags_csv.like(like_name),
            ReadTxProjection.tag_sync_ids_json.is_(None),
        )
    ).all()
    # 去重 (理论上不会重叠,但防御性合并)
    seen: set[tuple[str, str]] = set()
    for ledger_id_v, sync_id_v, tags_csv in (*rows_by_id, *rows_by_name):
        key = (ledger_id_v, sync_id_v)
        if key in seen or not tags_csv:
            continue
        seen.add(key)
        parts = [p.strip() for p in tags_csv.split(",") if p.strip()]
        replaced = [new_name if p == old_name else p for p in parts]
        if replaced != parts:
            db.execute(
                sql_update(ReadTxProjection)
                .where(
                    ReadTxProjection.ledger_id == ledger_id_v,
                    ReadTxProjection.sync_id == sync_id_v,
                )
                .values(tags_csv=",".join(replaced))
            )


def detach_cascade_tag(
    db: Session,
    *,
    user_id: str,
    tag_sync_id: str,
    tag_name: str,
) -> None:
    """Tag 删除后从所有 tx 投影行剥离引用:tag_sync_ids_json 移除该 sync_id、
    tags_csv 移除该名(两维度独立,与 snapshot_mutator._strip_tag_from_tx 同构,
    容忍名字/id 不同步的脏数据)。

    谓词与 rename_cascade_tag / web 写路径 cascade 点查同源(P0-1 契约):
      1) tag_sync_ids_json 精确引用该 sync_id (mobile/web 完整数据,不按
         user_id 过滤 —— 共享账本 tx 投影行 user_id=owner)
      2) tags_csv 包含旧名但没有 tag_sync_ids_json (legacy/不完整数据,
         仍按 user_id 收窄 —— 名字不是稳定 FK,跨用户同名会误伤)
    只做投影 UPDATE,不发 SyncChange —— cascade 事件由调用方定向补发
    (web 快路径)或由 tag:delete 事件在客户端级联(mobile push 路径)。
    """
    from sqlalchemy import and_
    from sqlalchemy import select as sql_select
    from sqlalchemy import update as sql_update

    like_pat = f'%"{tag_sync_id}"%'
    predicates = [ReadTxProjection.tag_sync_ids_json.like(like_pat)]
    if tag_name:
        predicates.append(
            and_(
                ReadTxProjection.user_id == user_id,
                ReadTxProjection.tags_csv.like(f"%{tag_name}%"),
                ReadTxProjection.tag_sync_ids_json.is_(None),
            )
        )
    rows = db.execute(
        sql_select(
            ReadTxProjection.ledger_id,
            ReadTxProjection.sync_id,
            ReadTxProjection.tags_csv,
            ReadTxProjection.tag_sync_ids_json,
        ).where(
            or_(*predicates),
        )
    ).all()
    for ledger_id_v, sync_id_v, tags_csv, tag_ids_json in rows:
        new_csv = tags_csv
        if tags_csv and tag_name:
            parts = [p.strip() for p in tags_csv.split(",") if p.strip()]
            stripped = [p for p in parts if p != tag_name]
            if stripped != parts:
                new_csv = ",".join(stripped) if stripped else None
        new_ids_json = tag_ids_json
        if tag_ids_json:
            try:
                ids = json.loads(tag_ids_json)
            except json.JSONDecodeError:
                ids = None
            if isinstance(ids, list) and tag_sync_id in ids:
                remaining = [i for i in ids if i != tag_sync_id]
                new_ids_json = json.dumps(remaining) if remaining else None
        if new_csv != tags_csv or new_ids_json != tag_ids_json:
            db.execute(
                sql_update(ReadTxProjection)
                .where(
                    ReadTxProjection.ledger_id == ledger_id_v,
                    ReadTxProjection.sync_id == sync_id_v,
                )
                .values(tags_csv=new_csv, tag_sync_ids_json=new_ids_json)
            )


# --------------------------------------------------------------------------- #
# Cascade 点查:user-global 实体改名/删除时受影响的活跃 tx 行                    #
# --------------------------------------------------------------------------- #
# P0-1 契约(2026-09):谓词按稳定 FK 列(sync_id)匹配,**不按 user_id** ——
# 共享账本 tx 投影行的 user_id 是 ledger owner,操作者可能是 Editor,按
# `user_id == 操作者` 过滤会漏掉 owner 名下的行。web 快路径的点查
# (write/_shared._cascade_tx_rows_for_*)与 sync push 的 cascade 事件补发
# 共用这三个函数,保证谓词单点收敛。软删(回收站)行一律不返回 —— 对其
# 补发 cascade upsert 会让 mobile 端按 INSERT 重建已删交易。

def cascade_tx_rows_for_account(
    db: Session, *, account_sync_id: str,
) -> list[ReadTxProjection]:
    """引用该账户的活跃 tx 行(account/from/to 三个 FK 列任一命中)。"""
    return list(db.scalars(
        select(ReadTxProjection).where(
            ReadTxProjection.deleted_at.is_(None),
            or_(
                ReadTxProjection.account_sync_id == account_sync_id,
                ReadTxProjection.from_account_sync_id == account_sync_id,
                ReadTxProjection.to_account_sync_id == account_sync_id,
            ),
        )
    ))


def cascade_tx_rows_for_category(
    db: Session, *, category_sync_id: str,
) -> list[ReadTxProjection]:
    """引用该分类的活跃 tx 行(按 category_sync_id 精确匹配)。"""
    return list(db.scalars(
        select(ReadTxProjection).where(
            ReadTxProjection.deleted_at.is_(None),
            ReadTxProjection.category_sync_id == category_sync_id,
        )
    ))


def cascade_tx_rows_for_tag(
    db: Session, *, tag_sync_id: str,
) -> list[ReadTxProjection]:
    """引用该标签的活跃 tx 行:tag_sync_ids_json 含该 sync_id(与
    rename_cascade_tag / detach_cascade_tag 的 by-id 集合一致)。legacy
    by-name 老数据不在本点查范围(名字非稳定 FK,由全量路径兜底)。"""
    like_pat = f'%"{tag_sync_id}"%'
    return list(db.scalars(
        select(ReadTxProjection).where(
            ReadTxProjection.deleted_at.is_(None),
            ReadTxProjection.tag_sync_ids_json.like(like_pat),
        )
    ))


# --------------------------------------------------------------------------- #
# 整表重建:回填 / 恢复备份                                                     #
# --------------------------------------------------------------------------- #

def _truncate_ledger(db: Session, ledger_id: str) -> None:
    """清掉该 ledger 的 ledger-scoped projection。user-global(account/
    category/tag)是 per-user 表,不按 ledger 清,**不在此处处理**。"""
    for model in (
        ReadTxProjection,
        ReadBudgetProjection,
        ReadAccountAdjustmentProjection,
    ):
        db.execute(delete(model).where(model.ledger_id == ledger_id))


def rebuild_from_snapshot(
    db: Session,
    *,
    ledger_id: str,
    user_id: str,
    snapshot: dict[str, Any],
    source_change_id: int,
) -> None:
    """按 snapshot 权威源,把该 ledger 的 ledger-scoped projection 清零再填。
    user-global(account/category/tag)是 per-user 表,**upsert 不清空** —— 同
    user 跨 ledger rebuild 多次也是幂等的(同 sync_id 的 row 被相同值覆盖)。

    用于:alembic 回填、admin restore_backup、脏数据救急脚本。
    """
    _truncate_ledger(db, ledger_id)

    for item in snapshot.get("items") or []:
        if isinstance(item, dict):
            upsert_tx(
                db,
                ledger_id=ledger_id,
                user_id=user_id,
                source_change_id=source_change_id,
                payload=item,
            )
    for item in snapshot.get("accounts") or []:
        if isinstance(item, dict):
            upsert_account(
                db,
                user_id=user_id,
                source_change_id=source_change_id,
                payload=item,
            )
    for item in snapshot.get("categories") or []:
        if isinstance(item, dict):
            upsert_category(
                db,
                user_id=user_id,
                source_change_id=source_change_id,
                payload=item,
            )
    for item in snapshot.get("tags") or []:
        if isinstance(item, dict):
            upsert_tag(
                db,
                user_id=user_id,
                source_change_id=source_change_id,
                payload=item,
            )
    for item in snapshot.get("budgets") or []:
        if isinstance(item, dict):
            upsert_budget(
                db,
                ledger_id=ledger_id,
                user_id=user_id,
                source_change_id=source_change_id,
                payload=item,
            )
    for item in snapshot.get("accountAdjustments") or []:
        if isinstance(item, dict):
            upsert_account_adjustment(
                db,
                ledger_id=ledger_id,
                user_id=user_id,
                source_change_id=source_change_id,
                payload=item,
            )


def rebuild_all(db: Session) -> int:
    """遍历所有 ledger,按各自 latest snapshot 重建 projection。
    返回处理的 ledger 个数。救急脚本 `scripts/rebuild_all_projections.py` 用。
    """
    from sqlalchemy import func

    from .models import Ledger, SyncChange

    count = 0
    ledger_rows = db.execute(
        select(Ledger.id, Ledger.user_id)
    ).all()
    for ledger_id, user_id in ledger_rows:
        latest = db.scalar(
            select(SyncChange)
            .where(
                SyncChange.ledger_id == ledger_id,
                SyncChange.entity_type == "ledger_snapshot",
            )
            .order_by(SyncChange.change_id.desc())
            .limit(1)
        )
        if latest is None:
            continue
        payload = latest.payload_json
        if isinstance(payload, str):
            payload = json.loads(payload)
        if not isinstance(payload, dict):
            continue
        content = payload.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        try:
            snapshot = json.loads(content)
        except json.JSONDecodeError:
            continue
        if not isinstance(snapshot, dict):
            continue
        rebuild_from_snapshot(
            db,
            ledger_id=ledger_id,
            user_id=user_id,
            snapshot=snapshot,
            source_change_id=int(latest.change_id),
        )
        count += 1
    db.commit()
    return count


# --------------------------------------------------------------------------- #
# AttachmentFile 垃圾回收                                                       #
# --------------------------------------------------------------------------- #
# AttachmentFile 表跟 tx / category 没有 FK —— 共享池 + sha256 去重,允许一个
# blob 被多个 tx(截图上传同图)或 category 图标同时引用。所以删 tx/category
# 时不能盲目删 AttachmentFile,必须查"还有没有其他实体引用同 fileId"。
#
# 反向引用只存在于:
#   - read_tx_projection.attachments_json  (JSON list,每项含 cloudFileId)
#   - read_category_projection.icon_cloud_file_id  (单列)
# 0 引用就 DELETE 行 + unlink 物理文件(best-effort,磁盘 IO 失败只 warn)。


def _extract_tx_cloud_file_ids(attachments_json: str | None) -> set[str]:
    """从 tx projection 的 attachments_json 里抽出所有 cloudFileId。

    mobile 序列化(`lib/cloud/sync/sync_engine.dart:802-812`) + web 写路径都用
    `cloudFileId` 这个 camelCase key。JSON 缺失 / 解析失败 / 非 list → 空 set。
    """
    if not attachments_json:
        return set()
    try:
        arr = json.loads(attachments_json)
    except json.JSONDecodeError:
        return set()
    if not isinstance(arr, list):
        return set()
    out: set[str] = set()
    for item in arr:
        if isinstance(item, dict):
            fid = item.get("cloudFileId")
            if isinstance(fid, str) and fid.strip():
                out.add(fid.strip())
    return out


def _batch_referenced_file_ids(
    db: Session, *, ledger_id: str | None = None,
    candidates: set[str],
) -> set[str]:
    """F14:一次拉取所有 attachments_json 提到 candidates 的 tx 行,Python 侧
    一次性精确匹配仍被引用的 fileId;categories 表的 icon 引用一并查。

    P0-1(2026-09):引用匹配按 **fileId 全局精确匹配**,不再按 user_id 收窄
    —— fileId 是全局唯一稳定键,精确匹配没有跨用户误报;而按操作者 user_id
    收窄会漏扫共享账本场景下 owner 名下的投影行(Editor 触发 GC 时误判孤儿
    → 删掉 owner 行仍在引用的活附件)。单人场景结果不变(本就只有自己的行)。

    ledger_id 仅用于 ledger 变体([gc_orphan_attachments_for_ledger]),按
    ledger 隔离是那份契约(test_ledger_gc_does_not_cross_ledger_boundary),
    与 user 域路径互不影响。

    tx 扫描带 candidates 子串 LIKE 粗筛(引用必须包含 id 字符串才是真子集),
    避免全局化后整列水化;Python 侧 [_extract_tx_cloud_file_ids] 复核。
    """
    if not candidates:
        return set()
    stmt = select(ReadTxProjection.attachments_json).where(
        ReadTxProjection.attachments_json.isnot(None),
        or_(*[
            ReadTxProjection.attachments_json.like(f"%{fid}%")
            for fid in candidates
        ]),
    )
    if ledger_id is not None:
        stmt = stmt.where(ReadTxProjection.ledger_id == ledger_id)
    referenced: set[str] = set()
    for (raw,) in db.execute(stmt):
        referenced |= _extract_tx_cloud_file_ids(raw)
    hit = referenced & candidates
    # category icon 引用(等值列,IN 点查)。必须对全量 candidates 查 —— 只被
    # category 引用、不被任何 tx 引用的 fileId 也算"仍被引用"(GC 保留)。
    # 同样不按 user_id 收窄(P0-1):Editor 镜像 category 可能引用 owner 上传
    # 的图标 fileId,反之亦然。
    cat_stmt = select(UserCategoryProjection.icon_cloud_file_id).where(
        UserCategoryProjection.icon_cloud_file_id.in_(list(candidates)),
    )
    for (fid,) in db.execute(cat_stmt):
        if fid:
            hit.add(fid.strip())
    return hit


def _fileid_still_referenced(db: Session, *, user_id: str, file_id: str) -> bool:
    """某个 AttachmentFile 还有任何 projection 行引用吗?

    扫:
      - read_tx_projection.attachments_json 里 cloudFileId == file_id 的行
        (JSON 字段名是 cloudFileId;Python 精确匹配容忍序列化空格差异)
      - user_category_projection.icon_cloud_file_id = file_id

    P0-1:匹配按 fileId 全局精确匹配,**不按 user_id 收窄** —— 共享账本里
    Editor 触发的 GC / 孤儿扫描不能漏掉 owner 名下的引用行(user_id 参数仅为
    调用方签名兼容保留,scanner 等外部调用方不改)。单人场景行为不变。
    """
    _ = user_id  # 不参与匹配,见 docstring
    return file_id in _batch_referenced_file_ids(
        db, candidates={file_id},
    )


def _fileid_still_referenced_in_ledger(
    db: Session, *, ledger_id: str, file_id: str,
) -> bool:
    """某个 AttachmentFile 在该 ledger 下任何 user 的 tx projection 还有引用吗?

    跟 [_fileid_still_referenced] 不同之处:**按 ledger_id 过滤,不按 user_id**。

    共享账本场景下 tx 创建人(Editor)上传的 attachment 在 `attachment_files` 表里
    user_id = Editor,但 `read_tx_projection` 里行可能挂在 ledger owner 的 user_id 下。
    `_delete_tx` 的 GC 路径如果用 user_id 过滤就会漏 — 这里改按 ledger_id 扫,任何
    user 的 projection 行只要还引用这个 fileId,都算"被引用",不能 GC。

    category icon 不是 ledger-scope,继续走原 [_fileid_still_referenced]。
    """
    return file_id in _batch_referenced_file_ids(
        db, ledger_id=ledger_id, candidates={file_id},
    )


def gc_orphan_attachments_for_ledger(
    db: Session,
    *,
    ledger_id: str,
    file_ids: Iterable[str | None],
) -> int:
    """对给定 fileId 集合,若该 ledger 下任何 user 的 tx projection 都无引用 →
    删 AttachmentFile 行 + unlink 物理文件。返回实际清掉的条数。

    跟 [gc_orphan_attachments] 同款契约(调用前 projection 必须先删),区别是
    **scope 是 ledger 而不是 user**:

    - **引用检查**走 [_fileid_still_referenced_in_ledger](扫所有 user 在本 ledger
      的 projection,不限 user_id)
    - **DELETE 时按 ledger_id 过滤**,不按 user_id,所以 Editor 上传的附件(user_id
      = Editor)也能被 Owner-发起的 delete 路径正确清理。

    使用场景:**ledger-scope 实体的 delete handler**(tx)。
    category icon / 其它 user-scope 路径继续用 [gc_orphan_attachments]。
    """
    cleaned = 0
    seen: set[str] = set()
    for fid in file_ids:
        if fid:
            t = fid.strip()
            if t:
                seen.add(t)
    # F14:一次批查引用集(替代逐 fileId 全表扫)。
    referenced = _batch_referenced_file_ids(
        db, ledger_id=ledger_id, candidates=seen,
    )

    for file_id in seen:
        if file_id in referenced:
            continue

        att = db.scalar(
            select(AttachmentFile).where(
                AttachmentFile.id == file_id,
                AttachmentFile.ledger_id == ledger_id,
            )
        )
        if att is None:
            continue

        storage_path = att.storage_path
        db.delete(att)

        try:
            p = Path(storage_path)
            if p.exists():
                p.unlink()
        except OSError as exc:
            logger.warning(
                "attachment gc unlink failed ledger=%s file=%s path=%s err=%s",
                ledger_id, file_id, storage_path, exc,
            )

        cleaned += 1

    if cleaned:
        logger.info(
            "attachment gc ledger=%s cleaned=%d", ledger_id, cleaned,
        )
    return cleaned


def gc_orphan_attachments(
    db: Session,
    *,
    user_id: str,
    file_ids: Iterable[str | None],
) -> int:
    """对给定 fileId 集合,若**任何** projection 行都无引用 → 删该用户名下的
    AttachmentFile 行 + unlink 物理文件。返回实际清掉的条数(日志/测试用)。

    **调用契约**:必须在目标 tx/category 的 projection 行**已经删掉**之后调用。
    否则会把正在用的 blob 误删。事务边界由调用方管(两个修改应在同一事务 commit)。

    两层 scope(P0-1 后):
      - **引用检查全局**:按 fileId 精确匹配扫所有用户的 tx attachments_json
        + category icon(id 全局唯一,精确匹配无跨用户误报)。旧版本按
        `user_id == 操作者` 收窄,共享账本场景 Editor 触发 GC 时漏扫 owner
        名下的投影行 → 误删活附件;单人场景结果不变。
      - **DELETE 仍限到该 user 的 AttachmentFile 行**(AttachmentFile 自身带
        user_id;跨 ledger 的行都看)。别人的孤儿行由其自己的写路径 / cleaner
        清,避免越权删除。

    物理文件 unlink 失败只 warn 不抛 —— DB 行已删是事实,磁盘残留可后续清理
    脚本补扫。
    """
    cleaned = 0
    seen: set[str] = set()
    for fid in file_ids:
        if fid:
            t = fid.strip()
            if t:
                seen.add(t)
    # F14:一次批查引用集(替代逐 fileId 全表扫),循环里只做点查 + 删除。
    referenced = _batch_referenced_file_ids(db, candidates=seen)

    for file_id in seen:
        if file_id in referenced:
            continue

        att = db.scalar(
            select(AttachmentFile).where(
                AttachmentFile.id == file_id,
                AttachmentFile.user_id == user_id,
            )
        )
        if att is None:
            # AttachmentFile 已经不存在(手动清过 / 历史脏数据)—— 不算失败
            continue

        storage_path = att.storage_path
        db.delete(att)

        # Best-effort unlink。DB 提交失败时这里改不回来,但事务 rollback 后
        # AttachmentFile 行还在,下次 GC 再来。
        try:
            p = Path(storage_path)
            if p.exists():
                p.unlink()
        except OSError as exc:
            logger.warning(
                "attachment gc unlink failed user=%s file=%s path=%s err=%s",
                user_id, file_id, storage_path, exc,
            )

        cleaned += 1

    if cleaned:
        logger.info(
            "attachment gc user=%s cleaned=%d", user_id, cleaned,
        )
    return cleaned


def collect_tx_attachment_fileids(
    db: Session, *, ledger_id: str, sync_id: str,
) -> set[str]:
    """在 tx projection 删之前取 attachments_json 里的 fileId 列表,供删后 GC 用。
    行不存在(已删 / 从未有过)→ 空 set。"""
    row = db.scalar(
        select(ReadTxProjection.attachments_json).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
        )
    )
    return _extract_tx_cloud_file_ids(row)


def collect_category_icon_fileids(
    db: Session, *, user_id: str, sync_id: str,
) -> set[str]:
    """在 user_category_projection 删之前取 icon_cloud_file_id + 所有
    parent=sync_id 子分类的 icon_cloud_file_id。级联删父分类时会同步带走子分类。
    category 是 user-global,scope 改成 user_id。"""
    out: set[str] = set()
    # 自身
    self_icon = db.scalar(
        select(UserCategoryProjection.icon_cloud_file_id).where(
            UserCategoryProjection.user_id == user_id,
            UserCategoryProjection.sync_id == sync_id,
        )
    )
    if isinstance(self_icon, str) and self_icon.strip():
        out.add(self_icon.strip())
    # 子分类(parent_name 匹配本分类的 name —— projection 里 parent 关系由 name
    # 串起来,见 upsert_category 的 parent_name 字段)。这里不走级联删,仅提取
    # icon。调用方如果要真级联删子分类,另外安排。
    own_name = db.scalar(
        select(UserCategoryProjection.name).where(
            UserCategoryProjection.user_id == user_id,
            UserCategoryProjection.sync_id == sync_id,
        )
    )
    if isinstance(own_name, str) and own_name:
        child_icons = db.scalars(
            select(UserCategoryProjection.icon_cloud_file_id).where(
                UserCategoryProjection.user_id == user_id,
                UserCategoryProjection.parent_name == own_name,
            )
        ).all()
        for icon in child_icons:
            if isinstance(icon, str) and icon.strip():
                out.add(icon.strip())
    return out


# --------------------------------------------------------------------------- #
# 手动汇率 override:user_exchange_rate_projection                               #
# --------------------------------------------------------------------------- #

def upsert_exchange_rate_override(
    db: Session,
    *,
    user_id: str,
    source_change_id: int,
    payload: dict,
) -> None:
    """手动汇率 override → user_exchange_rate_projection。方向:1 quote = rate base。

    `rate` 是**字符串列**(String(32),不落 float)—— 因此 `'inf'` 不会污染
    `/sync/full`(它是 JSON 字符串,不是非法 token),H-10 的读端 `float(...) > 0`
    判定问题属独立项,`tests/adversarial/test_sync_numeric_boundary_adversarial.py`
    的 HARDENING 用例锁定了「原样落库」这一现状(§五「保留测试锁行为」),
    本批**不改变**该行为,只补上列宽截断(超长在 PG 会 `value too long`)。
    """
    sync_id = str(payload.get("syncId") or "")
    base = str(payload.get("baseCurrency") or "").upper()[:16]
    quote = str(payload.get("quoteCurrency") or "").upper()[:16]
    rate = str(payload.get("rate") or "")
    if not sync_id or not base or not quote or not rate:
        return
    # F-11:rate 列声明 String(32)(models.py UserExchangeRateProjection.rate),
    # 超长在 SQLite 静默、PG 报 value too long。按列宽截断。
    rate = rate[:32]
    updated_at = _parse_happened_at(payload.get("updatedAt"))
    values = {
        "user_id": user_id,
        "sync_id": sync_id,
        "base_currency": base,
        "quote_currency": quote,
        "rate": rate,
        "updated_at": updated_at,
        "source_change_id": source_change_id,
    }
    _upsert(db, UserExchangeRateProjection, ("user_id", "sync_id"), values)


def delete_exchange_rate_override(db: Session, *, user_id: str, sync_id: str) -> None:
    """user-global exchange_rate_override delete。PK=(user_id, sync_id)。"""
    db.execute(
        delete(UserExchangeRateProjection).where(
            UserExchangeRateProjection.user_id == user_id,
            UserExchangeRateProjection.sync_id == sync_id,
        )
    )
