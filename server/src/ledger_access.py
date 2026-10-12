"""Ledger access helpers — Phase 1 shared-ledger 之后从 LedgerMember 表读权限。

每个 ledger 通过 ``LedgerMember`` 行授权,role ∈ {owner, editor}。原 ``Ledger.user_id``
保留为冗余字段(标识原始 Owner / 兜底),但实际权限判定全部走 ``LedgerMember``。

API 兼容性:历史 caller 形如 ``ledger, _ = get_accessible_ledger_by_external_id(...)``
现在 ``_`` 收到的是 ``role`` 字符串(原本是 None)。caller 普遍 ignore,无破坏。
"""

import logging
import time
from collections.abc import Iterable
from typing import TypeAlias

from fastapi import HTTPException
from sqlalchemy import Select, case, select
from sqlalchemy.orm import Session

from .metrics import metrics
from .models import AuditLog, Ledger, LedgerMember

logger = logging.getLogger(__name__)

# 角色 enum-like 字符串(application 层校验,无 server enum)
ROLE_OWNER = "owner"
ROLE_EDITOR = "editor"
ROLE_VIEWER = "viewer"  # Phase 1 不实现,占位以备远期

READABLE_ROLES = {ROLE_OWNER, ROLE_EDITOR, ROLE_VIEWER}
WRITABLE_ROLES = {ROLE_OWNER, ROLE_EDITOR}
ACTIVE_MEMBER_STATUS = "active"  # 历史 alias,LedgerMember 表不存 status

# external_id 只在 (user_id, external_id) 上唯一(models.py:uq_ledgers_user_external),
# 因此**跨用户同名**是合法状态("default" 是 mobile 默认账本名)。当 caller 同时
# 属于两个同名账本(自己一个 + 被邀请进别人的一个)时,原 `.one_or_none()` 命中
# 2 行 → sqlalchemy.MultipleResultsFound 未捕获 → 全端点 500(对抗测试 F-01)。
# 消歧规则:**自己 owner 优先 → 创建时间(最早)→ id**(全部落到 SQL ORDER BY,
# 读写路径共用同一规则,保证同一 caller 读到与写到的永远是同一个账本)。
_AMBIGUOUS_FETCH_LIMIT = 20  # 消歧只需前几行;审计样本取前 5
_AMBIGUOUS_AUDIT_SAMPLE = 5
# 同 (caller, external_id) 的歧义审计在 TTL 内只落一条 —— 歧义是**稳定状态**
# (账本归属不会每请求变化),而写路径可能高频(批量 push),不节流会把
# audit_logs 撑爆(先例:sync/push 的 _should_write_conflict_audit)。
_AMBIGUOUS_AUDIT_TTL_SECONDS = 3600.0
_AMBIGUOUS_AUDIT_MAX_KEYS = 4096
_ambiguous_audit_last: dict[tuple[str, str], float] = {}


def _should_write_ambiguous_audit(*, user_id: str, ledger_external_id: str) -> bool:
    key = (user_id, ledger_external_id)
    now_ts = time.monotonic()
    last = _ambiguous_audit_last.get(key)
    if last is not None and (now_ts - last) < _AMBIGUOUS_AUDIT_TTL_SECONDS:
        return False
    if len(_ambiguous_audit_last) >= _AMBIGUOUS_AUDIT_MAX_KEYS:
        cutoff = now_ts - _AMBIGUOUS_AUDIT_TTL_SECONDS
        for stale in [k for k, v in _ambiguous_audit_last.items() if v < cutoff]:
            del _ambiguous_audit_last[stale]
        if len(_ambiguous_audit_last) >= _AMBIGUOUS_AUDIT_MAX_KEYS:
            _ambiguous_audit_last.clear()
    _ambiguous_audit_last[key] = now_ts
    return True


LedgerRow: TypeAlias = tuple[Ledger, str]
"""``(ledger, role)``。role 是当前 caller 在该账本的角色。"""


def _ordered_accessible_ledger_query(
    *, user_id: str, ledger_external_id: str, roles: set[str] | None
) -> Select:
    """按消歧规则排序的 (Ledger, role) 查询 —— owner 优先、再按创建时间。"""
    q = (
        select(Ledger, LedgerMember.role)
        .join(LedgerMember, LedgerMember.ledger_id == Ledger.id)
        .where(
            Ledger.external_id == ledger_external_id,
            LedgerMember.user_id == user_id,
        )
    )
    if roles:
        q = q.where(LedgerMember.role.in_(roles))
    # 主排序:自己 owner 的账本优先(0),被邀请进的次之(1);
    # 次序:created_at 升序(最早创建/最早加入的先);id 兜底保证完全确定。
    return q.order_by(
        case((LedgerMember.role == ROLE_OWNER, 0), else_=1),
        Ledger.created_at.asc(),
        Ledger.id.asc(),
    ).limit(_AMBIGUOUS_FETCH_LIMIT)


def get_accessible_ledger_by_external_id(
    db: Session,
    *,
    user_id: str,
    ledger_external_id: str,
    roles: set[str] | None = None,
) -> LedgerRow | None:
    """Return ``(ledger, role)`` if caller is a member; honor ``roles`` filter.

    ``roles`` 提供时,caller 角色必须在集合内(用于写路径限定 owner/editor)。
    不在集合内 → 返 None(404),不返 403,避免泄露账本存在性。

    跨用户同名 external_id 命中多行时按「自己 owner 优先 → 创建时间 → id」
    确定性取一条,并落审计日志 + warning:同一 caller 的读 / 写 / 同步路径
    必须解析到同一个账本,否则会出现"读自己的、写别人的"数据分裂。
    """
    q = _ordered_accessible_ledger_query(
        user_id=user_id,
        ledger_external_id=ledger_external_id,
        roles=roles,
    )
    rows = list(db.execute(q).all())
    if not rows:
        return None
    ledger, role = rows[0]
    if len(rows) > 1:
        # 歧义不是错误(跨用户同名合法),但必须可观测:审计 + 结构化日志。
        # AuditLog 走 caller 当前事务(写路径 commit 时一并落库);只读路径
        # session 关闭即丢弃,由 warning 日志兜底可见。
        candidates = [
            {"ledgerId": r[0].id, "role": r[1], "ownerId": r[0].user_id}
            for r in rows[:_AMBIGUOUS_AUDIT_SAMPLE]
        ]
        logger.warning(
            "ledger_access.ambiguous_external_id user=%s external_id=%s "
            "candidates=%d chosen=%s chosen_role=%s",
            user_id, ledger_external_id, len(rows), ledger.id, role,
        )
        metrics.inc("smartbook_ledger_access_ambiguous_total")
        if _should_write_ambiguous_audit(
            user_id=user_id, ledger_external_id=ledger_external_id
        ):
            db.add(
                AuditLog(
                    user_id=user_id,
                    ledger_id=ledger.id,
                    action="ledger_access_ambiguous_external_id",
                    metadata_json={
                        "externalId": ledger_external_id,
                        "candidateCount": len(rows),
                        "chosenLedgerId": ledger.id,
                        "chosenRole": role,
                        "candidates": candidates,
                    },
                )
            )
    return ledger, role


def require_accessible_ledger_by_external_id(
    db: Session,
    *,
    user_id: str,
    ledger_external_id: str,
    roles: set[str] | None = None,
) -> LedgerRow:
    row = get_accessible_ledger_by_external_id(
        db,
        user_id=user_id,
        ledger_external_id=ledger_external_id,
        roles=roles,
    )
    if row is None:
        # Sprint 5.5 metric:区分"账本不存在"vs"非 member / 角色不足"两种情况。
        # 仅当账本存在但 caller 不在 LedgerMember(或 role 不达标)才记 denied —
        # 反映真实的"被拒"事件,纯不存在的 404 不计入。
        exists = db.scalar(
            select(Ledger.id).where(Ledger.external_id == ledger_external_id)
        )
        if exists is not None:
            reason = "role" if roles else "not_member"
            metrics.inc_labeled(
                "smartbook_shared_ledger_access_denied_total",
                {"reason": reason},
            )
        raise HTTPException(status_code=404, detail="Ledger not found")
    return row


def list_accessible_ledgers(
    db: Session,
    *,
    user_id: str,
    roles: Iterable[str] | None = None,
) -> list[Ledger]:
    """List ledgers the user can access (via LedgerMember)."""
    q = (
        select(Ledger)
        .join(LedgerMember, LedgerMember.ledger_id == Ledger.id)
        .where(LedgerMember.user_id == user_id)
        .order_by(Ledger.created_at.desc())
    )
    role_set = set(roles) if roles else None
    if role_set:
        q = q.where(LedgerMember.role.in_(role_set))
    return list(db.scalars(q).all())


def list_accessible_memberships(
    db: Session,
    *,
    user_id: str,
    roles: Iterable[str] | None = None,
) -> list[LedgerRow]:
    """List (ledger, role) tuples for ledgers the user can access."""
    q = (
        select(Ledger, LedgerMember.role)
        .join(LedgerMember, LedgerMember.ledger_id == Ledger.id)
        .where(LedgerMember.user_id == user_id)
        .order_by(Ledger.created_at.desc())
    )
    role_set = set(roles) if roles else None
    if role_set:
        q = q.where(LedgerMember.role.in_(role_set))
    return [(row[0], row[1]) for row in db.execute(q).all()]


def get_accessible_ledger_ids(
    db: Session,
    *,
    user_id: str,
    roles: Iterable[str] | None = None,
) -> Select[tuple[str]]:
    """Return a subquery selecting ledger ids accessible to ``user_id``.

    用于 ``Tx.ledger_id.in_(get_accessible_ledger_ids(db, user_id=...))``,
    避免拼大 IN list。
    """
    q = select(LedgerMember.ledger_id).where(LedgerMember.user_id == user_id)
    role_set = set(roles) if roles else None
    if role_set:
        q = q.where(LedgerMember.role.in_(role_set))
    return q


def get_member_role(
    db: Session, *, user_id: str, ledger_id: str
) -> str | None:
    """单纯查角色。返 ``None`` 表示非成员。"""
    return db.scalar(
        select(LedgerMember.role).where(
            LedgerMember.ledger_id == ledger_id,
            LedgerMember.user_id == user_id,
        )
    )


def list_ledger_members(
    db: Session, *, ledger_id: str
) -> list[tuple[str, str]]:
    """``[(user_id, role), ...]``。用于 WS fan-out / 权限审计。

    ``ledger_id`` 是 ``Ledger.id`` (String(36) UUID 主键),不是 ``external_id``。
    """
    return [
        (row.user_id, row.role)
        for row in db.execute(
            select(LedgerMember.user_id, LedgerMember.role).where(
                LedgerMember.ledger_id == ledger_id
            )
        ).all()
    ]


def count_ledger_members(db: Session, *, ledger_id: str) -> int:
    """成员数(invite accept 时检查上限用)。"""
    from sqlalchemy import func

    return db.scalar(
        select(func.count()).select_from(LedgerMember).where(
            LedgerMember.ledger_id == ledger_id
        )
    ) or 0
