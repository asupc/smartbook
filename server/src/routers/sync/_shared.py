"""sync.py 的共享层。

原 src/routers/sync.py 按 endpoint 拆成 4 个子模块后,各 endpoint 都依赖的
import + 轻量 helper(_to_utc / _max_cursor_for_ledgers)+ router 实例本身
集中在这里。

真正的业务重头 —— "一条 SyncChange 怎么落到 projection 表" —— 在独立的
src/sync_applier.py 里(push.py 从那里 import apply_change_to_projection +
INDIVIDUAL_ENTITY_TYPES)。本模块只管 HTTP / LWW / 事务 / 游标推进这些
跨 endpoint 共用的样板。
"""

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, cast

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ...concurrency import lock_ledger_for_materialize
from ...database import get_db
from ...deps import get_current_user, require_any_scopes, require_scopes
from ...ledger_access import (
    get_accessible_ledger_by_external_id,
    list_accessible_ledgers,
)
from ...metrics import metrics
from ...models import (
    AuditLog,
    Device,
    Ledger,
    LedgerMember,
    ReadTxProjection,  # list_ledgers 端点做 tx 计数估算用
    SyncChange,
    SyncCursor,
    User,
)
from ...schemas import (
    SyncChangeIn,
    SyncChangeOut,
    SyncFullResponse,
    SyncLedgerOut,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
)
from ...security import SCOPE_APP_WRITE, SCOPE_WEB_READ
from ...sync_applier import (
    apply_change_to_projection,
    apply_user_change_to_projection,
    INDIVIDUAL_ENTITY_TYPES,
    USER_GLOBAL_ENTITY_TYPES,
)
from ... import snapshot_builder, snapshot_cache

logger = logging.getLogger(__name__)

# Router 在这里创建一次,各 endpoint 子模块 `from ._shared import *` 拉到
# 同一个实例,装饰器挂在同一个 router 上。__init__.py re-export。
router = APIRouter()


def _to_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


# --------------------------------------------------------------------------- #
# 服务端内部 payload 键(``__`` 前缀)的边界规则
# --------------------------------------------------------------------------- #
# ``__`` 前缀的键属于**服务端实现细节**(如 push 的 clamp 原始 ts 标记),
# 客户端既不能注入也不能看到:
#   - 入站(/sync/push):一律 strip —— 内部状态只能由服务端自己写。
#     否则客户端可伪造 ``__rawUpdatedAt`` 之类的键冒充服务端状态(伪造 LWW 键
#     → 永久锁死实体),且会随 SyncChange 持久化。
#   - 出站(/sync/pull):一律过滤 —— 内部键不下发(泄漏实现细节,且客户端
#     回推会把攻击面带回来)。
# **递归覆盖嵌套容器**(2026-10-11 缺陷 4):旧实现只剔顶层键,客户端发
# ``{"nested": {"__rawUpdatedAt": …}}`` 会被 /sync/pull 原样回显 —— 对 LWW 惰性,
# 但把客户端脏数据 round-trip 成了服务端持久化内容(且出站时又原样还给客户端)。
# 现在两侧都覆盖整棵 JSON 树(dict 与 list 内的 dict 都算)。
# 幂等 hash(_normalized_payload_hash)同口径剔除,保证「同一逻辑变更体」
# 在入站(strip 后)与库内(可能含服务端写入的内部键)两侧 hash 相同 ——
# 入站递归 strip 后库内不会再有嵌套 ``__`` 键,顶层剔除即足以对齐。
INTERNAL_PAYLOAD_KEY_PREFIX = "__"


def _is_internal_payload_key(key: object) -> bool:
    return isinstance(key, str) and key.startswith(INTERNAL_PAYLOAD_KEY_PREFIX)


def _strip_internal_payload_keys(payload: Any) -> int:
    """就地从入站 payload **递归**删除服务端内部键(``__`` 前缀),返回删除个数。

    覆盖嵌套 dict 与 list 内的 dict(客户端 payload 的 ``attachments[]`` 之类
    天然是「list 套 dict」)。返回 >0 说明客户端试图注入服务端内部状态
    (或客户端自身脏数据),调用方应打 warning 日志留痕。

    用显式栈而不是递归:payload 是外部输入,病态深嵌套(JSON 解析器允许的
    最深层级)下递归会 RecursionError;栈版本同时用 ``id()`` 去重防环
    (pydantic 解出的结构无环,纯属防御)。
    """
    if not isinstance(payload, dict):
        return 0
    removed = 0
    seen: set[int] = set()
    stack: list[Any] = [payload]
    while stack:
        node = stack.pop()
        if id(node) in seen:
            continue
        seen.add(id(node))
        if isinstance(node, dict):
            for key in [k for k in node if _is_internal_payload_key(k)]:
                del node[key]
                removed += 1
            children: Any = node.values()
        elif isinstance(node, list):
            children = node
        else:
            continue
        for child in children:
            if isinstance(child, (dict, list)):
                stack.append(child)
    return removed


def _public_payload(payload: Any) -> Any:
    """出站用副本:递归剔除内部键;非容器原样返回(**不修改入参对象**)。

    迭代式「拷贝 + 过滤」(显式栈):不做 ``copy.deepcopy`` 再原地 strip ——
    那会为整棵树的标量也分配新对象(pull 批量 5000 条时的无谓开销),也不
    用递归(深结构 RecursionError)。标量按引用共享(不可变,安全)。
    """
    if not isinstance(payload, (dict, list)):
        return payload

    def _empty_like(node: Any) -> Any:
        return {} if isinstance(node, dict) else []

    root = _empty_like(payload)
    stack: list[tuple[Any, Any]] = [(payload, root)]
    while stack:
        src, dst = stack.pop()
        if isinstance(src, dict):
            for key, value in src.items():
                if _is_internal_payload_key(key):
                    continue
                if isinstance(value, (dict, list)):
                    child = _empty_like(value)
                    dst[key] = child
                    stack.append((value, child))
                else:
                    dst[key] = value
        else:  # list
            for value in src:
                if isinstance(value, (dict, list)):
                    child = _empty_like(value)
                    dst.append(child)
                    stack.append((value, child))
                else:
                    dst.append(value)
    return root


def _max_cursor_for_ledgers(db: Session, ledger_ids: list[str]) -> int:
    if not ledger_ids:
        return 0
    max_cursor = db.scalar(select(func.max(SyncChange.change_id)).where(SyncChange.ledger_id.in_(ledger_ids)))
    return int(max_cursor or 0)


__all__ = [
    'json',
    'logging',
    'datetime',
    'timedelta',
    'timezone',
    'Any',
    'cast',
    'APIRouter',
    'Depends',
    'HTTPException',
    'Query',
    'Request',
    'status',
    'func',
    'select',
    'Session',
    'lock_ledger_for_materialize',
    'get_db',
    'get_current_user',
    'require_any_scopes',
    'require_scopes',
    'get_accessible_ledger_by_external_id',
    'list_accessible_ledgers',
    'metrics',
    'AuditLog',
    'Device',
    'Ledger',
    'LedgerMember',
    'ReadTxProjection',
    'SyncChange',
    'SyncCursor',
    'User',
    'SyncChangeOut',
    'SyncFullResponse',
    'SyncLedgerOut',
    'SyncPullResponse',
    'SyncPushRequest',
    'SyncPushResponse',
    'SyncChangeIn',
    'SCOPE_APP_WRITE',
    'SCOPE_WEB_READ',
    'apply_change_to_projection',
    'apply_user_change_to_projection',
    'INDIVIDUAL_ENTITY_TYPES',
    'USER_GLOBAL_ENTITY_TYPES',
    'snapshot_builder',
    'snapshot_cache',
    'logger',
    'router',
    '_to_utc',
    '_max_cursor_for_ledgers',
    'INTERNAL_PAYLOAD_KEY_PREFIX',
    '_is_internal_payload_key',
    '_strip_internal_payload_keys',
    '_public_payload',
]
