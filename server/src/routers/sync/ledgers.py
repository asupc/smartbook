"""GET /sync/ledgers —— 列出 caller 可访问的账本元信息。

每条返回 ledger_id / path / updated_at / size(粗略估算,按 tx 数量乘
固定系数)。mobile 启动时用来做账本差异比对。

P1-E2(2026-09):role 不再硬编码 "owner" —— `list_accessible_ledgers` 只返回
Ledger 对象丢了 role,Editor 端拿到全 owner 会被客户端 UI 门控误导;改用
`list_accessible_memberships` 取 (ledger, role)。N+1 同步治理:tombstone 复用
read/_shared 的批量 `_deleted_ledger_ids`,latest change_id/updated_at 合并成
一条 window-function 聚合,tx_count 合并成一条 GROUP BY —— 每请求 4 条查询,
与账本数无关。响应字段与取值口径保持不变(只有 role 从"恒 owner"变成真实值)。
"""
from __future__ import annotations

from ._shared import *  # noqa: F401,F403 — 拉取所有 imports / helpers / router / constants


@router.get("/ledgers", response_model=list[SyncLedgerOut])
def list_ledgers(
    _scopes: set[str] = Depends(require_any_scopes(SCOPE_APP_WRITE, SCOPE_WEB_READ)),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[SyncLedgerOut]:
    """方案 B 后:用户可见账本元数据。size 估算从 tx 行数外推(不再 byte 精确)。"""
    # late import 防循环(与 write/_shared._load_ledger_for_write 同款)。
    from ...ledger_access import list_accessible_memberships
    from ..read._shared import _deleted_ledger_ids

    memberships = list_accessible_memberships(db, user_id=current_user.id)
    ledger_ids = [lg.id for lg, _role in memberships]
    if not ledger_ids:
        return []

    # 软删除检测(批量):每个账本最新一条 ledger_snapshot 变更是否 tombstone。
    deleted = _deleted_ledger_ids(db, ledger_ids=ledger_ids)

    # latest change_id + 该行的 updated_at(批量):每账本按 change_id 倒序取第 1
    # 条 —— 与旧实现「snapshot_builder.latest_change_id(=max change_id)+ 单查
    # 最新行的 updated_at」语义完全一致,只是 N 次并成 1 次 window-function。
    rn = func.row_number().over(
        partition_by=SyncChange.ledger_id,
        order_by=SyncChange.change_id.desc(),
    ).label("rn")
    subq = (
        select(
            SyncChange.ledger_id.label("lg"),
            SyncChange.change_id.label("cid"),
            SyncChange.updated_at.label("uat"),
            rn,
        )
        .where(SyncChange.ledger_id.in_(ledger_ids))
        .subquery()
    )
    latest_rows = db.execute(
        select(subq.c.lg, subq.c.cid, subq.c.uat).where(subq.c.rn == 1)
    ).all()
    latest_by_ledger = {lg: (int(cid or 0), uat) for lg, cid, uat in latest_rows}

    # size 估算的 tx 计数(批量 GROUP BY;不过滤软删行,与旧口径一致)。
    tx_counts = dict(
        db.execute(
            select(ReadTxProjection.ledger_id, func.count())
            .where(ReadTxProjection.ledger_id.in_(ledger_ids))
            .group_by(ReadTxProjection.ledger_id)
        ).all()
    )

    out: list[SyncLedgerOut] = []
    for ledger, role in memberships:
        if ledger.id in deleted:
            continue

        latest_change_id, latest_updated = latest_by_ledger.get(ledger.id, (0, None))
        if latest_change_id == 0:
            continue

        # size 估算:每条 tx 按 ~300 字节算,配合基础元数据
        tx_count = tx_counts.get(ledger.id, 0)
        size = 512 + tx_count * 300  # 足够粗略的估算

        out.append(
            SyncLedgerOut(
                ledger_id=ledger.external_id,
                path=ledger.external_id,
                updated_at=latest_updated or datetime.now(timezone.utc),
                size=size,
                metadata={"source": "lazy_rebuild"},
                role=cast("Any", role),
            )
        )
    return out
