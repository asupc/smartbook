"""Sync change → projection 应用层。

这个模块负责"把一条 SyncChange 怎么落到 read_*_projection 表里"的全部业务
逻辑。从 HTTP 层(``src.routers.sync`` 的 /sync/push 端点)分出来,目的:

1. **关注点分离**:HTTP 层只管路由 / auth / LWW / 事务提交,业务逻辑在这里。
   push_changes 的批量循环里一行 ``apply_change_to_projection(...)`` 即可。
2. **review 粒度**:未来修 projection 写入的逻辑(rename cascade / 字段合并
   / 图标兜底 / 附件 GC),改动集中在本文件,reviewer 不用翻 router 找线索。
3. **复现 + 测试**:业务逻辑脱离 FastAPI 之后,单元测试可以直接构造
   ``SyncChange`` 对象 + 手造 session 跑,不用再过 TestClient。

## 架构概览(user-global 重构后)

Push 路径跟 projection 的交互按 scope 分两条:

    /sync/push (router)
        ├─ scope='ledger' → apply_change_to_projection(change)      → projection.upsert_tx/budget
        └─ scope='user'   → apply_user_change_to_projection(change) → projection.upsert_account/category/tag

每条路径都有自己的三张"表"驱动 dispatch:

- ledger-scope:``_LEDGER_MERGE_SPECS`` / ``_LEDGER_UPSERT_DISPATCH`` / ``_LEDGER_DELETE_DISPATCH``
- user-scope: ``_USER_MERGE_SPECS`` / ``_USER_UPSERT_DISPATCH`` / ``_USER_DELETE_DISPATCH``

新加 entity 只登记其中两张会在测试 / assert 时爆出 KeyError(2026-04 踩过
的 copy-paste bug 在表驱动后已复现不了)。

## Rename cascade 的位置

account / category / tag 是 user-global 实体,name 变了之后 ReadTxProjection
里的冗余列(account_name / category_name / tags_csv)要一起刷。detect 写在
``apply_user_change_to_projection`` 里(不在 merge 里),因为它必须在 upsert
当前实体 *之前* 跑 —— cascade 用的是 SQL 单条 UPDATE 匹配**旧名**,upsert
之后旧名就丢了。范围是该用户的所有 ledger(单条 SQL WHERE user_id=X,不再
循环 ledger)。
"""

from __future__ import annotations

import json
import logging
from typing import Any, Callable, Optional

from sqlalchemy import and_, delete as sa_delete, or_, select
from sqlalchemy.orm import Session

from . import projection
from .models import (
    Ledger,
    ReadAccountAdjustmentProjection,
    ReadBudgetProjection,
    ReadTxProjection,
    SyncChange,
    UserAccountProjection,
    UserCategoryProjection,
    UserExchangeRateProjection,
    UserTagProjection,
)
from .services.category_icon import resolve_icon_by_name

logger = logging.getLogger(__name__)


# 哪些 entity_type 可以走单条 change 的 projection 应用(其它 entity
# 比如 ``ledger_snapshot`` 是 sync_changes 里的元数据行,不走这条路径)。
INDIVIDUAL_ENTITY_TYPES = {"transaction", "account", "category", "tag", "budget", "ledger", "exchange_rate_override", "account_adjustment"}

# user-global entity 类型白名单 —— 跟 mobile lib/cloud/sync/change_tracker.dart
# 的 userGlobalEntityTypes 保持一致。push 路径按这个集合分流到 user-scope 应用。
USER_GLOBAL_ENTITY_TYPES = {"account", "category", "tag", "exchange_rate_override"}


# --------------------------------------------------------------------------- #
# Merge with existing projection row                                           #
# --------------------------------------------------------------------------- #
# Mobile 增量 push 只带部分字段(比如只改 name),不带的字段要保留现有值,
# 不能被默认值(0 / None / 空字符串)覆盖。所以写 projection 前先拉已有
# 行,payload 值为 None 的 key 用旧值补齐,再 upsert。
#
# spec 的 fields 是 [(payload_key, projection 列名)] 或
# [(payload_key, projection 列名, transform_fn)]。transform 处理 tx 的
# json 文本列 / datetime isoformat 这种需要格式转换的情况。


def _json_loads_safe(value: Any) -> Any:
    """把 DB 里存的 JSON 字符串列反序列化回 Python 对象。解析失败返回 None。

    projection 里 ``tag_sync_ids_json`` / ``attachments_json`` 是存成文本的
    JSON array。返回给 mobile 做 merge 时要是原生 list,不能直接塞字符串。
    """
    if not value:
        return None
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return None


def _isoformat_or_none(value: Any) -> Optional[str]:
    """datetime → ISO8601 字符串。None 直接返回。"""
    return value.isoformat() if value else None


# _FieldSpec 的形态二选一:
#   (payload_key, projection_column_name)                       — 直接 getattr
#   (payload_key, projection_column_name, transform_callable)   — 经 transform
_FieldSpec = tuple  # 运行时就是元组,类型系统上表达不了两种 arity


class _MergeSpec:
    """每个 entity_type 的 projection 字段映射 + 对应的 SQLAlchemy model。"""

    __slots__ = ("model", "fields")

    def __init__(self, model: type, fields: list[_FieldSpec]):
        self.model = model
        self.fields = fields


# user-scope merge specs:用 (user_id, sync_id) 当主键检 existing row。
_USER_MERGE_SPECS: dict[str, _MergeSpec] = {
    "account": _MergeSpec(UserAccountProjection, [
        ("syncId", "sync_id"),
        ("name", "name"),
        ("type", "account_type"),
        ("currency", "currency"),
        ("initialBalance", "initial_balance"),
        # 扩展字段:跟 mobile lib/data/db.dart Account 表对齐,sync_engine 已经
        # 在 push 这些字段(driftCamel),server 现在落库 + round-trip。
        ("note", "note"),
        ("creditLimit", "credit_limit"),
        ("billingDay", "billing_day"),
        ("paymentDueDay", "payment_due_day"),
        ("bankName", "bank_name"),
        ("cardLastFour", "card_last_four"),
        # 账户隐藏(issue #240):payload 键 hidden(camelCase 同名,跟 App
        # serializeAccount 对齐)。缺键时 _merge_from_spec 从 existing 行补齐,
        # 不被 partial-update 冲成 False(merge 契约测试见
        # tests/test_account_hidden_sync.py::test_mobile_push_account_partial_update_keeps_hidden)。
        ("hidden", "hidden"),
    ]),
    "exchange_rate_override": _MergeSpec(UserExchangeRateProjection, [
        ("syncId", "sync_id"),
        ("baseCurrency", "base_currency"),
        ("quoteCurrency", "quote_currency"),
        ("rate", "rate"),
        ("updatedAt", "updated_at", _isoformat_or_none),
    ]),
    "category": _MergeSpec(UserCategoryProjection, [
        ("syncId", "sync_id"),
        ("name", "name"),
        ("kind", "kind"),
        ("level", "level"),
        ("sortOrder", "sort_order"),
        ("icon", "icon"),
        ("iconType", "icon_type"),
        ("customIconPath", "custom_icon_path"),
        ("iconCloudFileId", "icon_cloud_file_id"),
        ("iconCloudSha256", "icon_cloud_sha256"),
        ("parentName", "parent_name"),
    ]),
    "tag": _MergeSpec(UserTagProjection, [
        ("syncId", "sync_id"),
        ("name", "name"),
        ("color", "color"),
    ]),
}


# ledger-scope merge specs:用 (ledger_id, sync_id) 当主键检 existing row。
_LEDGER_MERGE_SPECS: dict[str, _MergeSpec] = {
    "budget": _MergeSpec(ReadBudgetProjection, [
        ("syncId", "sync_id"),
        ("type", "budget_type"),
        ("categoryId", "category_sync_id"),
        ("amount", "amount"),
        ("period", "period"),
        ("startDay", "start_day"),
        ("enabled", "enabled"),
    ]),
    "transaction": _MergeSpec(ReadTxProjection, [
        ("syncId", "sync_id"),
        ("type", "tx_type"),
        ("amount", "amount"),
        ("happenedAt", "happened_at", _isoformat_or_none),
        ("note", "note"),
        ("categoryId", "category_sync_id"),
        ("categoryName", "category_name"),
        ("categoryKind", "category_kind"),
        ("accountId", "account_sync_id"),
        ("accountName", "account_name"),
        ("fromAccountId", "from_account_sync_id"),
        ("fromAccountName", "from_account_name"),
        ("toAccountId", "to_account_sync_id"),
        ("toAccountName", "to_account_name"),
        ("tags", "tags_csv"),
        ("tagIds", "tag_sync_ids_json", _json_loads_safe),
        ("attachments", "attachments_json", _json_loads_safe),
        ("txIndex", "tx_index"),
        ("createdByUserId", "created_by_user_id"),
        # 共享账本 Phase 1:updatedByUserId 也回写到 projection,作为
        # last_edited_by。snapshot_mutator._mark_entity_actor 写入。
        ("updatedByUserId", "last_edited_by_user_id"),
        # 账单标记(.docs/transaction-flags)。merge 时缺键保留既有行值,
        # 布尔强转在 projection.upsert_tx(default=False)做。
        ("excludeFromStats", "exclude_from_stats"),
        ("excludeFromBudget", "exclude_from_budget"),
        # 交易级多币种(0018):缺键保留既有折算快照(旧 App 改备注不丢折算);
        # payload 带 amount 不带 nativeAmount 时的联动缩放见
        # _sync_native_amount_after_merge。
        ("currencyCode", "currency_code"),
        ("nativeAmount", "native_amount"),
    ]),
    # 余额调整记录(0028):「调整余额」不再落交易,独立 ledger-scope 实体。
    # amount 带符号;balance_before/after 是审计快照;actor 字段语义同 tx。
    "account_adjustment": _MergeSpec(ReadAccountAdjustmentProjection, [
        ("syncId", "sync_id"),
        ("accountId", "account_sync_id"),
        ("accountName", "account_name"),
        ("amount", "amount"),
        ("balanceBefore", "balance_before"),
        ("balanceAfter", "balance_after"),
        ("happenedAt", "happened_at", _isoformat_or_none),
        ("note", "note"),
        ("createdByUserId", "created_by_user_id"),
        ("updatedByUserId", "last_edited_by_user_id"),
    ]),
}


# user-scope upsert dispatch:apply_user_change_to_projection 用。
_USER_UPSERT_DISPATCH: dict[str, Callable] = {
    "account": projection.upsert_account,
    "category": projection.upsert_category,
    "tag": projection.upsert_tag,
    "exchange_rate_override": projection.upsert_exchange_rate_override,
}


# ledger-scope upsert dispatch:apply_change_to_projection 用。
_LEDGER_UPSERT_DISPATCH: dict[str, Callable] = {
    "budget": projection.upsert_budget,
    "transaction": projection.upsert_tx,
    "account_adjustment": projection.upsert_account_adjustment,
}


# Delete 路径分两组。
#
# ledger-scope:tx / budget,handler 签名 ``(db, ledger_id, sync_id, user_id)``。
# user-scope:account / category / tag,handler 签名 ``(db, user_id, sync_id)``。
#
# tx 删除时附带 GC tx 附件(走 user_id scope —— attachment GC 已重构);
# category 删除时附带 GC icon 附件(同样 user_id scope)。


def _compact_entity_upsert_events(
    db: Session,
    *,
    user_id: str,
    entity_type: str,
    entity_sync_id: str,
) -> int:
    """实体被删除后,清掉该 (user_id, entity_type, entity_sync_id) 的全部 **upsert**
    sync_changes 历史,**保留 delete 事件本身**。

    背景:sync_changes 一般是 append-only event log,不裸 DELETE(防止 projection
    跟 log 漂移,见 21136 案例)。但**实体彻底下线**的场景下,所有 upsert 事件都已
    没有价值:
      - projection 已经把该实体的行删了 → 没人会再引用任何 source_change_id
      - 其它设备 cursor 落后时,只看到 delete event 也能正确处理(apply 路径
        `if (existingId == null) return;` 是 idempotent no-op,见
        sync_engine_apply.dart::_applyTransactionChange)
      - delete event 本身**保留**,确保 cursor 落后的设备能 apply delete 把本地
        副本删干净

    所以"删 entity 时连带清掉它的 upsert 历史"是契约的**合理例外**,跟"projection
    漂移"那种裸 DELETE 不一样。

    返回清掉的 row 数。
    """
    result = db.execute(
        sa_delete(SyncChange).where(
            SyncChange.user_id == user_id,
            SyncChange.entity_type == entity_type,
            SyncChange.entity_sync_id == entity_sync_id,
            SyncChange.action != "delete",
        )
    )
    return result.rowcount or 0


def _delete_tx(db: Session, ledger_id: str, sync_id: str, user_id: str) -> None:
    # 0030 软删(回收站):只写 deleted_at,不删行/不 GC 附件 —— 附件物理删除
    # 延后到「彻底删除/30 天过期清理」(read/trash.py + data_cleanup cleaner)。
    # upsert 历史也不清:恢复(restore)靠重放最新 upsert payload 重建。
    # 幂等:已软删的行 update 条件不命中,无副作用。
    projection.delete_tx(db, ledger_id=ledger_id, sync_id=sync_id)


def _delete_user_category(db: Session, user_id: str, sync_id: str) -> None:
    # 删 user_category_projection 行,再 GC 自身 + 子分类的图标附件。
    cat_file_ids = projection.collect_category_icon_fileids(
        db, user_id=user_id, sync_id=sync_id,
    )
    projection.delete_category(db, user_id=user_id, sync_id=sync_id)
    # category icon 是 user-scope,继续走 gc_orphan_attachments(user_id)
    projection.gc_orphan_attachments(
        db, user_id=user_id, file_ids=cat_file_ids,
    )
    _compact_entity_upsert_events(
        db, user_id=user_id, entity_type="category", entity_sync_id=sync_id,
    )


def _delete_user_category_cascade(
    db: Session, *, user_id: str, change: SyncChange,
) -> list[dict[str, Any]]:
    """删分类 + 级联删子分类,返回需要 fan-out 给共享账本成员的额外事件。

    mobile 端删父分类时本地已把子分类行一并删掉(LocalCategoryRepository
    .deleteCategory / sync pull apply 都级联),但 push 上来的只有父分类
    一条 delete change —— server 不级联的话,子分类 projection 行会留下
    parent 悬空的僵尸行:web 端按 parent_name 分组所以不可见,但会进
    /sync/full 全量重建、污染 workspace 数据。级联时给每个子分类补一条
    delete SyncChange(事件日志完整,落后设备 pull 到后 apply 是 no-op),
    并作为 shared_resource 事件 fan-out 给成员(成员镜像端只按单条删,
    不自己级联)。
    """
    sync_id = change.entity_sync_id
    row = db.scalar(
        select(UserCategoryProjection).where(
            UserCategoryProjection.user_id == user_id,
            UserCategoryProjection.sync_id == sync_id,
        )
    )
    _delete_user_category(db, user_id, sync_id)
    if row is None:
        return []
    name = (row.name or "").strip()
    kind = (row.kind or "").strip()
    if not name:
        return []
    # 子分类识别:parent_sync_id(新数据,稳定 FK)优先,parent_name + kind
    # 兜底(老数据只维护了 name 引用)。(name, kind) 在 upsert 侧有查重,
    # 不会误伤同名兄弟。
    children = db.scalars(
        select(UserCategoryProjection).where(
            UserCategoryProjection.user_id == user_id,
            UserCategoryProjection.sync_id != sync_id,
            or_(
                UserCategoryProjection.parent_sync_id == sync_id,
                and_(
                    UserCategoryProjection.parent_name == name,
                    UserCategoryProjection.kind == kind,
                ),
            ),
        )
    ).all()
    extra_fanout: list[dict[str, Any]] = []
    for child in children:
        child_file_ids = projection.collect_category_icon_fileids(
            db, user_id=user_id, sync_id=child.sync_id,
        )
        projection.delete_category(db, user_id=user_id, sync_id=child.sync_id)
        projection.gc_orphan_attachments(
            db, user_id=user_id, file_ids=child_file_ids,
        )
        _compact_entity_upsert_events(
            db, user_id=user_id, entity_type="category",
            entity_sync_id=child.sync_id,
        )
        db.add(
            SyncChange(
                user_id=user_id,
                ledger_id=None,
                scope="user",
                entity_type="category",
                entity_sync_id=child.sync_id,
                action="delete",
                payload_json={"syncId": child.sync_id},
                updated_at=change.updated_at,
                updated_by_device_id=change.updated_by_device_id,
                updated_by_user_id=change.updated_by_user_id,
            )
        )
        extra_fanout.append({
            "resource_type": "category",
            "action": "delete",
            "sync_id": child.sync_id,
            "payload": {"syncId": child.sync_id},
        })
    if children:
        logger.info(
            "sync.apply.category_delete_cascade user=%s parent=%s children=%d",
            user_id, sync_id, len(children),
        )
    return extra_fanout


def _delete_budget(db: Session, ledger_id: str, sync_id: str, user_id: str) -> None:
    projection.delete_budget(db, ledger_id=ledger_id, sync_id=sync_id)
    _compact_entity_upsert_events(
        db, user_id=user_id, entity_type="budget", entity_sync_id=sync_id,
    )


def _delete_account_adjustment(
    db: Session, ledger_id: str, sync_id: str, user_id: str
) -> None:
    projection.delete_account_adjustment(db, ledger_id=ledger_id, sync_id=sync_id)
    _compact_entity_upsert_events(
        db, user_id=user_id, entity_type="account_adjustment", entity_sync_id=sync_id,
    )


def _delete_user_account(db: Session, user_id: str, sync_id: str) -> None:
    """user-global account delete(mobile push 路径)。

    批次3 guard(与 web snapshot_mutator.delete_account 口径对齐):该账户
    仍被任何活跃交易引用时**拒绝删除**。旧行为只删 UserAccountProjection 行,
    留下悬挂的 account_sync_id —— 净资产回放按 `acc in bal` 静默跳过这些
    交易,与 /summary 口径分裂,且账户列表分桶里这些交易随桶一起消失。

    拒绝 = 抛 ValueError → push 端 savepoint 隔离记 failed_samples,App 端
    提示「该账户仍有交易」;用户先迁/删交易后重推即成功。
    """
    linked = db.scalar(
        select(ReadTxProjection.sync_id).where(
            ReadTxProjection.user_id == user_id,
            ReadTxProjection.deleted_at.is_(None),
            or_(
                ReadTxProjection.account_sync_id == sync_id,
                ReadTxProjection.from_account_sync_id == sync_id,
                ReadTxProjection.to_account_sync_id == sync_id,
            ),
        ).limit(1)
    )
    if linked is not None:
        raise ValueError(
            "account has linked transactions: "
            f"account_sync_id={sync_id} linked_tx={linked}"
        )
    projection.delete_account(db, user_id=user_id, sync_id=sync_id)
    _compact_entity_upsert_events(
        db, user_id=user_id, entity_type="account", entity_sync_id=sync_id,
    )


def _delete_user_tag(db: Session, user_id: str, sync_id: str) -> None:
    projection.delete_tag(db, user_id=user_id, sync_id=sync_id)
    _compact_entity_upsert_events(
        db, user_id=user_id, entity_type="tag", entity_sync_id=sync_id,
    )


def _delete_user_exchange_rate_override(db: Session, user_id: str, sync_id: str) -> None:
    projection.delete_exchange_rate_override(db, user_id=user_id, sync_id=sync_id)
    _compact_entity_upsert_events(
        db, user_id=user_id, entity_type="exchange_rate_override", entity_sync_id=sync_id,
    )


_LEDGER_DELETE_DISPATCH: dict[str, Callable[[Session, str, str, str], None]] = {
    "transaction": _delete_tx,
    "budget": _delete_budget,
    "account_adjustment": _delete_account_adjustment,
}


_USER_DELETE_DISPATCH: dict[str, Callable[[Session, str, str], None]] = {
    "account": _delete_user_account,
    "category": _delete_user_category,
    "tag": _delete_user_tag,
    "exchange_rate_override": _delete_user_exchange_rate_override,
}


# --------------------------------------------------------------------------- #
# Rename cascade                                                               #
# --------------------------------------------------------------------------- #
# account / category / tag 的 name 变了之后,ReadTxProjection 里用作 denorm
# 列的 account_name / category_name / tags_csv 也要一起刷。必须在 upsert
# 当前实体 **之前** 跑 —— cascade 按 *旧名* 找 tx 行 UPDATE,upsert 之后
# 旧名就丢了。


def _detect_and_run_rename_cascade_user(
    db: Session,
    *,
    entity_type: str,
    user_id: str,
    sync_id: str,
    payload: dict,
) -> None:
    """user-global rename cascade:探测 name 变化,刷遍该用户所有 ledger 的
    read_tx_projection denorm 列。account / category / tag 三种。"""
    new_name = str(payload.get("name") or "").strip()
    if not new_name:
        return

    if entity_type == "account":
        prev_row = db.scalar(
            select(UserAccountProjection).where(
                UserAccountProjection.user_id == user_id,
                UserAccountProjection.sync_id == sync_id,
            )
        )
        old_name = (prev_row.name or "").strip() if prev_row is not None else ""
        if old_name and old_name != new_name:
            projection.rename_cascade_account(
                db, user_id=user_id, account_sync_id=sync_id, new_name=new_name,
            )
    elif entity_type == "category":
        prev_row = db.scalar(
            select(UserCategoryProjection).where(
                UserCategoryProjection.user_id == user_id,
                UserCategoryProjection.sync_id == sync_id,
            )
        )
        old_name = (prev_row.name or "").strip() if prev_row is not None else ""
        if old_name and old_name != new_name:
            projection.rename_cascade_category(
                db, user_id=user_id, category_sync_id=sync_id,
                new_name=new_name,
                new_kind=str(payload.get("kind") or "").strip() or None,
            )
    elif entity_type == "tag":
        prev_row = db.scalar(
            select(UserTagProjection).where(
                UserTagProjection.user_id == user_id,
                UserTagProjection.sync_id == sync_id,
            )
        )
        old_name = (prev_row.name or "").strip() if prev_row is not None else ""
        if old_name and old_name != new_name:
            projection.rename_cascade_tag(
                db, user_id=user_id, tag_sync_id=sync_id,
                old_name=old_name, new_name=new_name,
            )


# --------------------------------------------------------------------------- #
# Merge                                                                        #
# --------------------------------------------------------------------------- #


def _merge_from_spec(spec: _MergeSpec, existing, payload: dict) -> dict:
    """从 existing row + spec.fields 构造 base dict,再把 payload 里非 None 的
    字段叠加上来。两条 merge 路径(ledger / user)共用这段。"""
    base: dict = {}
    for spec_tuple in spec.fields:
        if len(spec_tuple) == 3:
            payload_key, db_attr, transform = spec_tuple
        else:
            payload_key, db_attr = spec_tuple
            transform = None
        value = getattr(existing, db_attr)
        if transform is not None:
            value = transform(value)
        base[payload_key] = value
    return {**base, **{k: v for k, v in payload.items() if v is not None}}


def _lock_account_initial_balance(
    db: Session, user_id: str, sync_id: str, merged: dict
) -> dict:
    """初始值仅在创建时可设:account 已有 projection 行时,强制用库里旧值
    覆盖 payload(无论 payload 是否携带该字段)。余额变更走「调整余额」
    (exclude_from_stats 调整交易),App / Web 跨端一致。"""
    prev_row = db.scalar(
        select(UserAccountProjection).where(
            UserAccountProjection.user_id == user_id,
            UserAccountProjection.sync_id == sync_id,
        )
    )
    if prev_row is not None:
        merged["initialBalance"] = prev_row.initial_balance
    return merged


def _sync_native_amount_after_merge(existing, payload: dict, merged: dict) -> dict:
    """交易级多币种(0018):payload 带新 amount 但不带 nativeAmount(旧客户端
    只知道原币金额)时,merge 从 existing 补回的旧 native_amount 会与新 amount
    失配(账本统计显示旧折算值)。联动规则(与 snapshot_mutator L14 一致):

    - amount 未变 → 保留旧折算(merge 已补,即快照保护,不动)
    - 同币种 / 未折算(old_native == old_amount,隐含汇率 1)→ 跟随新 amount
    - 外币 → 按该笔隐含汇率等比缩放(保持记账时汇率)
    - old_amount == 0 无法推汇率 → 退化 = 新 amount(1:1,App 端 L11 可捞回)
    """
    if payload.get("amount") is None or payload.get("nativeAmount") is not None:
        return merged
    old_native = getattr(existing, "native_amount", None)
    if old_native is None:
        return merged
    try:
        new_amount = float(payload["amount"])
        old_amount = float(getattr(existing, "amount", 0.0) or 0.0)
    except (TypeError, ValueError):
        return merged
    if new_amount == old_amount:
        return merged
    from .snapshot_mutator import rescale_native_amount

    merged["nativeAmount"] = rescale_native_amount(
        old_amount, old_native, new_amount)
    return merged


def merge_with_existing(
    db: Session,
    entity_type: str,
    ledger_id: str,
    sync_id: str,
    payload: dict,
) -> dict:
    """**ledger-scope** merge:查 projection 已有行,把 payload 里缺的 / None 的
    字段用旧值补齐。entity_type 未登记在 _LEDGER_MERGE_SPECS 时(比如 'ledger'
    自己),直接返回 payload 不做处理。"""
    spec = _LEDGER_MERGE_SPECS.get(entity_type)
    if spec is None:
        return payload
    existing = db.scalar(
        select(spec.model).where(
            spec.model.ledger_id == ledger_id,
            spec.model.sync_id == sync_id,
        )
    )
    if existing is None:
        return payload
    merged = _merge_from_spec(spec, existing, payload)
    if entity_type == "transaction":
        merged = _sync_native_amount_after_merge(existing, payload, merged)
    return merged


def merge_with_existing_user(
    db: Session,
    entity_type: str,
    user_id: str,
    sync_id: str,
    payload: dict,
) -> dict:
    """**user-scope** merge:查 user_*_projection 已有行,补齐缺失字段。"""
    spec = _USER_MERGE_SPECS.get(entity_type)
    if spec is None:
        return payload
    existing = db.scalar(
        select(spec.model).where(
            spec.model.user_id == user_id,
            spec.model.sync_id == sync_id,
        )
    )
    if existing is None:
        return payload
    return _merge_from_spec(spec, existing, payload)


# --------------------------------------------------------------------------- #
# Top-level entry                                                              #
# --------------------------------------------------------------------------- #


def apply_change_to_projection(
    db: Session,
    *,
    ledger_id: str,
    ledger_owner_id: str,
    change: SyncChange,
) -> None:
    """把一条 **ledger-scope** SyncChange 投到 projection 上。
    (user-global 走 ``apply_user_change_to_projection``。)

    流程:

      1. ledger entity:更新 Ledger 表的 name / currency(snapshot 已废弃)。
      2. delete action:按 entity 类型清理对应 projection 行 + 附加资源。
      3. upsert action:
         a. parse payload → dict,注入 syncId
         b. merge_with_existing 把 payload 缺失 / None 的字段补齐
         c. _LEDGER_UPSERT_DISPATCH 写入对应 projection 表

    ``change.change_id`` 作为 ``source_change_id`` 写进行,诊断用:后续要是
    发现某行数据不对,查这一列能定位是哪次 materialize 落的。

    防御性:若 entity_type 是 user-global(category/account/tag),调用方走错
    路径 — 抛 AssertionError 让 caller 修(应该走 apply_user_change_to_projection)。
    """
    assert change.entity_type not in USER_GLOBAL_ENTITY_TYPES, (
        f"apply_change_to_projection 收到 user-global entity {change.entity_type},"
        f"应该走 apply_user_change_to_projection(change_id={change.change_id})"
    )

    # --- ledger entity(特殊:不是 projection 表,直接改 Ledger) --------- #
    if change.entity_type == "ledger":
        if change.action == "delete":
            return
        payload_raw = _parse_payload(change.payload_json)
        if payload_raw is None:
            return
        new_name = payload_raw.get("ledgerName")
        new_currency = payload_raw.get("currency")
        new_month_start_day = payload_raw.get("monthStartDay")
        ledger_row = db.scalar(select(Ledger).where(Ledger.id == ledger_id))
        if ledger_row is not None:
            if isinstance(new_name, str) and new_name.strip():
                ledger_row.name = new_name.strip()
            if isinstance(new_currency, str) and new_currency.strip():
                ledger_row.currency = new_currency.strip()[:16]
            # bool 是 int 子类,显式排除;key 缺失时不动(partial-update merge 契约)
            if isinstance(new_month_start_day, int) and not isinstance(new_month_start_day, bool):
                ledger_row.month_start_day = max(1, min(28, new_month_start_day))
        return

    sync_id = change.entity_sync_id

    # --- delete --------------------------------------------------------- #
    if change.action == "delete":
        handler = _LEDGER_DELETE_DISPATCH.get(change.entity_type)
        if handler is not None:
            handler(db, ledger_id, sync_id, ledger_owner_id)
        return

    # --- upsert --------------------------------------------------------- #
    payload = _parse_payload(change.payload_json)
    if payload is None:
        return
    payload.setdefault("syncId", sync_id)
    # 共享账本兜底:mobile EntitySerializer.serializeTransaction 当前不把
    # updatedByUserId 写进 payload,直接 push 上来 projection 这字段会是 NULL。
    # 从 SyncChange.updated_by_user_id(推送方真实身份)兜底注入。
    #
    # **不**兜底 createdByUserId — 那会让"B 编辑 A 创建的 tx"路径误把 created
    # 写成 B。createdByUserId 由 projection.upsert_tx 内部 COALESCE 保留旧值
    # (见 upsert_tx 注释)。
    actor = change.updated_by_user_id
    if actor:
        payload.setdefault("updatedByUserId", actor)

    if change.entity_type in _LEDGER_MERGE_SPECS:
        merged = merge_with_existing(db, change.entity_type, ledger_id, sync_id, payload)
        _LEDGER_UPSERT_DISPATCH[change.entity_type](
            db,
            ledger_id=ledger_id,
            user_id=ledger_owner_id,
            source_change_id=change.change_id,
            payload=merged,
        )


def apply_user_change_to_projection(
    db: Session,
    *,
    user_id: str,
    change: SyncChange,
) -> list[dict[str, Any]]:
    """把一条 **user-scope** SyncChange 投到 user_*_projection 上。

    流程跟 ledger-scope 对偶,但:
      - 主键查 / 写都按 (user_id, sync_id),跟账本无关
      - rename cascade 也按 user_id 跨该用户所有 ledger 刷 read_tx_projection

    返回级联产生的额外 fan-out 事件(目前只有 category delete 级联子分类
    会产生),caller(shared_resource fan-out)负责追加广播;普通应用返回 []。

    防御性:entity_type 必须在 USER_GLOBAL_ENTITY_TYPES,否则 caller 错路径。
    """
    assert change.entity_type in USER_GLOBAL_ENTITY_TYPES, (
        f"apply_user_change_to_projection 收到非 user-global entity "
        f"{change.entity_type}(change_id={change.change_id})"
    )

    sync_id = change.entity_sync_id

    # --- delete --------------------------------------------------------- #
    if change.action == "delete":
        if change.entity_type == "category":
            return _delete_user_category_cascade(db, user_id=user_id, change=change)
        handler = _USER_DELETE_DISPATCH.get(change.entity_type)
        if handler is not None:
            handler(db, user_id, sync_id)
        return []

    # --- upsert --------------------------------------------------------- #
    payload = _parse_payload(change.payload_json)
    if payload is None:
        return []
    payload.setdefault("syncId", sync_id)

    # rename cascade 必须先于 upsert 当前实体 —— 用的是"旧名" match tx 行。
    _detect_and_run_rename_cascade_user(
        db,
        entity_type=change.entity_type,
        user_id=user_id,
        sync_id=sync_id,
        payload=payload,
    )

    if change.entity_type in _USER_MERGE_SPECS:
        merged = merge_with_existing_user(
            db, change.entity_type, user_id, sync_id, payload,
        )
        if change.entity_type == "account":
            # 初始值仅创建时可设:已有行的 update 一律锁旧值(见 helper)。
            merged = _lock_account_initial_balance(db, user_id, sync_id, merged)
        # 分类 icon 兜底:老 App(Flutter 3.0 及之前)可能推空 icon 的 category。
        # 写进 projection 前按分类名字 byName 推一次,跟 alembic 0002 backfill
        # 对齐,避免 web 端继续看到兜底图。Flutter 3.0.1 做完 write-time
        # migration 后这段可以退役。
        if change.entity_type == "category":
            icon_val = merged.get("icon") if isinstance(merged, dict) else None
            if icon_val is None or (isinstance(icon_val, str) and not icon_val.strip()):
                merged = {**merged, "icon": resolve_icon_by_name(merged.get("name"))}
        _USER_UPSERT_DISPATCH[change.entity_type](
            db,
            user_id=user_id,
            source_change_id=change.change_id,
            payload=merged,
        )
    return []


def _parse_payload(raw: Any) -> Optional[dict]:
    """把 ``SyncChange.payload_json`` 归一成 dict。非法 JSON / 非 dict 返回 None。

    DB 里这列声明成 JSON,但 SQLAlchemy 对 SQLite 的 JSON 类型存进去是字符串,
    取出来也可能是字符串;Postgres 直接反序列化成 dict。两种都要 handle。
    """
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return None
    if isinstance(raw, dict):
        return raw
    return None
