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
from ...models import (
    Ledger,
    RawBookkeepingEvidence,
    RawEvidenceAsset,
    RawEvidenceTransactionLink,
    ReadTxProjection,
    SyncChange,
)
from ...schemas import (
    DuplicateCleanFailure,
    DuplicateCleanResult,
    DuplicateCompareItemOut,
    DuplicateCompareResponse,
    DuplicateDeleteItem,
    DuplicateEvidenceAssetOut,
    DuplicateEvidenceDetailResponse,
    DuplicateEvidenceOut,
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
                created_at=m.created_at,
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


# ==========================================================================
# M6-6 原始证据对比 / 关联
# ==========================================================================

def link_evidence_to_transaction(
    db: Session,
    *,
    evidence_id: str,
    ledger_id: str,
    transaction_sync_id: str,
    event_item_index: int | None = None,
    link_source: str = "client",
) -> RawEvidenceTransactionLink | None:
    """为一条证据补确定性关联(幂等)。重复提交同一 (evidence, ledger, tx) 不产生重复行。

    服务端必须重新验证:evidence 存在、transaction 属于指定 ledger。
    """
    evidence = db.get(RawBookkeepingEvidence, evidence_id)
    if evidence is None:
        return None
    tx = db.scalar(
        select(ReadTxProjection).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == transaction_sync_id,
        )
    )
    if tx is None:
        return None
    existing = db.scalar(
        select(RawEvidenceTransactionLink).where(
            RawEvidenceTransactionLink.evidence_id == evidence_id,
            RawEvidenceTransactionLink.ledger_id == ledger_id,
            RawEvidenceTransactionLink.transaction_sync_id == transaction_sync_id,
        )
    )
    if existing is not None:
        return existing
    link = RawEvidenceTransactionLink(
        evidence_id=evidence_id,
        user_id=evidence.user_id,  # 用证据归属,不信任客户端传的 user_id
        ledger_id=ledger_id,
        transaction_sync_id=transaction_sync_id,
        event_item_index=event_item_index,
        link_source=link_source,
    )
    db.add(link)
    db.commit()
    return link


def _evidence_status(
    evidence: RawBookkeepingEvidence | None,
    assets: list[RawEvidenceAsset],
    linked: bool,
) -> str:
    """按文档 §8.2.4 区分的证据状态。

    SQLite 读回的 tz-aware 列可能是 naive datetime,统一转 aware 再比较。
    """
    if evidence is None:
        return "none"
    if not linked:
        return "not_linked"
    if evidence.expires_at is not None:
        exp = evidence.expires_at
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=timezone.utc)
        if exp < _utcnow():
            return "expired"
    if assets and any(a.mime_type.startswith("image/") for a in assets):
        return "available"
    # 有文字证据但无图,仍 available(图片缺失不影响文字可读)。
    return "available"


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _asset_out(a: RawEvidenceAsset) -> DuplicateEvidenceAssetOut:
    return DuplicateEvidenceAssetOut(
        id=a.id,
        kind=a.kind,
        mime_type=a.mime_type,
        size_bytes=a.size_bytes,
        sha256=a.sha256,
        width=a.width,
        height=a.height,
    )


def _body_preview(body: str | None) -> str | None:
    if not body:
        return None
    return body[:160]


def evidence_out(
    evidence: RawBookkeepingEvidence,
    assets: list[RawEvidenceAsset],
    linked: bool,
) -> DuplicateEvidenceOut:
    return DuplicateEvidenceOut(
        id=evidence.id,
        source=evidence.source,
        source_channel=evidence.source_channel,
        external_id=evidence.external_id,
        title=evidence.title,
        body_preview=_body_preview(evidence.body),
        content_hash_short=(evidence.content_hash[:16] if evidence.content_hash else None),
        captured_at=evidence.captured_at,
        occurred_at=evidence.occurred_at,
        expires_at=evidence.expires_at,
        status=_evidence_status(evidence, assets, linked),
        assets=[_asset_out(a) for a in assets],
    )


def compare_duplicate_transactions(
    db: Session, items: list[tuple[str, str]]
) -> DuplicateCompareResponse:
    """对比一组重复交易:按 (ledger_id, sync_id) 批量取回交易摘要 + 证据摘要。

    固定 SQL 数(不做 N+1):
      1 条 projection 查询取回全部交易;
      1 条 link + evidence 查询取回证据摘要;
      1 条 asset 查询取回图片元数据;
      1 条 attachment 查询取回普通附件计数。
    """
    if not items:
        return DuplicateCompareResponse(items=[])
    ledger_ids = {li for li, _ in items}
    sync_ids = {si for _, si in items}

    # 1. projection
    txs = db.scalars(
        select(ReadTxProjection).where(
            ReadTxProjection.ledger_id.in_(ledger_ids),
            ReadTxProjection.sync_id.in_(sync_ids),
        )
    ).all()
    tx_by_key = {(t.ledger_id, t.sync_id): t for t in txs}

    # keeper:同组内最小 source_change_id(与 scan 一致,取最早落库)。
    keep_keys = set()
    for li in ledger_ids:
        group_txs = [t for t in txs if t.ledger_id == li]
        if not group_txs:
            continue
        keeper = min(group_txs, key=lambda t: (t.source_change_id or 0, t.sync_id))
        keep_keys.add((keeper.ledger_id, keeper.sync_id))

    # 2. links(user-level:按 evidence 归属 user 的 ledger + tx sync id 关联)
    links = db.scalars(
        select(RawEvidenceTransactionLink).where(
            RawEvidenceTransactionLink.ledger_id.in_(ledger_ids),
            RawEvidenceTransactionLink.transaction_sync_id.in_(sync_ids),
        )
    ).all()
    link_map: dict[tuple[str, str], list[RawEvidenceTransactionLink]] = defaultdict(list)
    for lnk in links:
        link_map[(lnk.ledger_id, lnk.transaction_sync_id)].append(lnk)

    evidence_ids = {lnk.evidence_id for lnk in links}
    evidences = (
        db.scalars(select(RawBookkeepingEvidence).where(
            RawBookkeepingEvidence.id.in_(evidence_ids)
        )).all() if evidence_ids else []
    )
    ev_by_id = {e.id: e for e in evidences}

    # 3. assets
    assets = (
        db.scalars(select(RawEvidenceAsset).where(
            RawEvidenceAsset.evidence_id.in_(evidence_ids)
        )).all() if evidence_ids else []
    )
    asset_map: dict[str, list[RawEvidenceAsset]] = defaultdict(list)
    for a in assets:
        asset_map[a.evidence_id].append(a)

    # 4. attachment 计数:从 projection 的 attachments_json 解析(为空=0)。
    #    投影交易附件以 JSON 数组存储,这里只取数量做摘要,不取正文。
    import json as _json
    att_counts: dict[tuple[str, str], int] = {}
    for t in txs:
        if t.attachments_json:
            try:
                arr = _json.loads(t.attachments_json)
                att_counts[(t.ledger_id, t.sync_id)] = len(arr) if isinstance(arr, list) else 0
            except Exception:
                att_counts[(t.ledger_id, t.sync_id)] = 0

    result_items = []
    for (li, si) in items:
        tx = tx_by_key.get((li, si))
        lnks = link_map.get((li, si), [])
        evs = [evidence_out(ev_by_id[l.evidence_id], asset_map.get(l.evidence_id, []), True)
               for l in lnks if l.evidence_id in ev_by_id]
        item = DuplicateCompareItemOut(
            ledger_id=li,
            sync_id=si,
            is_keeper=(li, si) in keep_keys,
            amount=tx.amount if tx else None,
            happened_at=tx.happened_at if tx else None,
            created_at=tx.created_at if tx else None,
            tx_type=tx.tx_type if tx else None,
            note=tx.note if tx else None,
            account_name=tx.account_name if tx else None,
            category_name=tx.category_name if tx else None,
            tags_csv=tx.tags_csv if tx else None,
            attachment_count=att_counts.get((li, si), 0),
            raw_evidence_count=len(evs),
            raw_evidence_status=("available" if evs else "none"),
            evidences=evs,
        )
        result_items.append(item)
    return DuplicateCompareResponse(items=result_items)


def get_evidence_detail(
    db: Session, transaction_ledger_id: str, transaction_sync_id: str, evidence_id: str
) -> DuplicateEvidenceDetailResponse | None:
    """证据详情:必须校验该 evidence 确实关联到指定交易,防越权读取其它记录。

    正文全文(≤ 65,536 字符)仅在此返回;列表/扫描 response 不包含 body 全文。
    """
    link = db.scalar(
        select(RawEvidenceTransactionLink).where(
            RawEvidenceTransactionLink.evidence_id == evidence_id,
            RawEvidenceTransactionLink.ledger_id == transaction_ledger_id,
            RawEvidenceTransactionLink.transaction_sync_id == transaction_sync_id,
        )
    )
    if link is None:
        return None
    evidence = db.get(RawBookkeepingEvidence, evidence_id)
    if evidence is None:
        return None
    assets = db.scalars(select(RawEvidenceAsset).where(
        RawEvidenceAsset.evidence_id == evidence_id
    )).all()
    out = evidence_out(evidence, assets, linked=True)
    return DuplicateEvidenceDetailResponse(
        evidence=out,
        asset_ids=[a.id for a in assets],
        body_full=evidence.body[:65536] if evidence.body else None,
    )
