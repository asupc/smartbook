"""重复交易检测 / 清理 — admin scope,跨所有用户。

同一账本内,「金额 + 交易时间(同一分钟)」相同的多笔交易视为重复,不区分
收支类型(客户端自动记账最常见的重复来源:同一笔账单被屏幕 OCR 和图片 OCR
各记一次,或截图 / 短信 / 通知多渠道重复入账)。

scan 阶段只做只读分组,不动数据;clean 阶段按 (ledger_id, sync_id) 逐条
删除,复用 projection.delete_tx + 附件 GC + SyncChange delete 行的完整链路,
与 write 删除路径语义一致,保证 mobile pull 时能同步删掉。
"""
from __future__ import annotations

import logging
from collections import defaultdict
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from ... import projection
from ...models import Ledger, ReadTxProjection, SyncChange
from ...schemas import (
    DuplicateCleanFailure,
    DuplicateCleanResult,
    DuplicateDeleteItem,
    DuplicateGroup,
    DuplicateRecord,
)

logger = logging.getLogger("smartbook.duplicates")


def _truncate_to_minute(dt: datetime | None) -> datetime | None:
    """把时间截到分钟(秒/微秒归零),作为分组键。

    部分入口记录的时间没有秒(秒位为 0),同一笔账单不同渠道记录的时刻可能
    相差几十秒,精确到秒会把它们判成两笔。同分钟归并正好吸收这种抖动。
    """
    if dt is None:
        return None
    return dt.replace(second=0, microsecond=0)


def scan_duplicate_transactions(db: Session) -> list[DuplicateGroup]:
    """扫描全库,把重复交易按 (ledger_id, 金额, 分钟) 分组返回。

    金额按两位小数归一化(round)消除 Float 精度抖动;时间按「同一分钟」归并
    (部分记账入口记录的消费时间没有秒,秒位被截成 0,精确到秒会漏判同一笔)。
    不区分收支类型。每组 >= 2 笔才上报。
    """
    rows = db.scalars(
        select(ReadTxProjection).order_by(
            ReadTxProjection.ledger_id,
            ReadTxProjection.happened_at,
            ReadTxProjection.sync_id,
        )
    ).all()

    ledger_names = {
        lid: name
        for lid, name in db.execute(select(Ledger.id, Ledger.name)).all()
    }

    groups: dict[tuple, list[ReadTxProjection]] = defaultdict(list)
    for r in rows:
        key = (
            r.ledger_id,
            round(r.amount or 0.0, 2),
            _truncate_to_minute(r.happened_at),
        )
        groups[key].append(r)

    out: list[DuplicateGroup] = []
    for (ledger_id, amount, happened_at), members in groups.items():
        if len(members) < 2:
            continue
        # 建议保留 change_id 最小(最早落库)的那笔,其余默认作为可清理项。
        keeper = min(members, key=lambda m: (m.source_change_id or 0, m.sync_id))
        items = [
            DuplicateRecord(
                ledger_id=m.ledger_id,
                ledger_name=ledger_names.get(m.ledger_id),
                sync_id=m.sync_id,
                amount=m.amount or 0.0,
                happened_at=m.happened_at,
                tx_type=m.tx_type,
                note=m.note,
                account_name=m.account_name,
                category_name=m.category_name,
                tags_csv=m.tags_csv,
                source_change_id=m.source_change_id or 0,
                is_keeper=m.sync_id == keeper.sync_id,
            )
            for m in members
        ]
        out.append(
            DuplicateGroup(
                ledger_id=ledger_id,
                ledger_name=ledger_names.get(ledger_id),
                amount=amount,
                happened_at=happened_at,
                count=len(members),
                keep_sync_id=keeper.sync_id,
                items=items,
            )
        )

    # 时间倒序:最近的重复组排前面。
    out.sort(key=lambda g: g.happened_at, reverse=True)
    return out


def clean_duplicate_transactions(
    db: Session, items: list[DuplicateDeleteItem]
) -> DuplicateCleanResult:
    """按 (ledger_id, sync_id) 逐条删除。逐条 commit / rollback,避免长事务持锁。

    删除走与 write 路径一致的完整链路:SyncChange delete 行 + projection 行删除
    + 孤立附件 GC,保证 mobile 下次 pull 同步删除。
    """
    success = 0
    failures: list[DuplicateCleanFailure] = []
    for item in items:
        key = f"{item.ledger_id}:{item.sync_id}"
        try:
            _delete_one(db, item.ledger_id, item.sync_id)
            db.commit()
            success += 1
        except Exception as exc:  # noqa: BLE001
            db.rollback()
            logger.warning("dedup clean tx %s failed: %s", key, exc)
            failures.append(DuplicateCleanFailure(record_key=key, error=str(exc)))
    return DuplicateCleanResult(success_count=success, failures=failures)


def _delete_one(db: Session, ledger_id: str, sync_id: str) -> None:
    """删除单笔交易。行不存在(已被删 / 脏数据)视为成功,不抛。"""
    tx = db.scalar(
        select(ReadTxProjection).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
        )
    )
    if tx is None:
        return

    file_ids = projection.collect_tx_attachment_fileids(
        db, ledger_id=ledger_id, sync_id=sync_id
    )

    db.add(
        SyncChange(
            user_id=tx.user_id,
            ledger_id=ledger_id,
            scope="ledger",
            entity_type="transaction",
            entity_sync_id=sync_id,
            action="delete",
            payload_json={},
            updated_at=datetime.now(timezone.utc),
        )
    )
    db.flush()

    # 先删 projection 行,再 GC 孤立附件(GC 契约要求行已删)。
    projection.delete_tx(db, ledger_id=ledger_id, sync_id=sync_id)
    if file_ids:
        projection.gc_orphan_attachments(db, user_id=tx.user_id, file_ids=file_ids)
