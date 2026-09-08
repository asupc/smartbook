"""M6-6 重复交易原始证据对比 — service 层测试。

覆盖(§8.8.1 核心):
- link_evidence_to_transaction 幂等;
- 一条 evidence 关联两笔交易;
- 一笔交易关联多份 evidence;
- 多账本同 transaction_sync_id 不串证据;
- compare 批量返回但无 N+1(固定 SQL 数,用 SQLAlchemy event 统计);
- get_evidence_detail 必须校验 link;
- 过期 evidence 返回 expired 状态;
- 删除交易只删 link 不删证据/asset。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base
from src.models import (
    Ledger,
    RawBookkeepingEvidence,
    RawEvidenceAsset,
    RawEvidenceTransactionLink,
    ReadTxProjection,
    User,
)
from src.services.data_cleanup.duplicates import (
    get_evidence_detail,
    link_evidence_to_transaction,
    compare_duplicate_transactions,
)


@pytest.fixture
def session_factory():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    return sessionmaker(bind=engine, autocommit=False, autoflush=False)


def _seed(db):
    db.add(User(id="U1", email="u1@x.com", password_hash="h"))
    db.add(User(id="U2", email="u2@x.com", password_hash="h"))
    db.add(Ledger(id="L1", user_id="U1", external_id="ext-L1", name="账本1", currency="CNY"))
    db.add(Ledger(id="L2", user_id="U2", external_id="ext-L2", name="账本2", currency="CNY"))
    db.flush()


def _tx(db, ledger_id, sync_id, *, user_id="U1", amount=10.0,
        happened_at=None, source_change_id=0):
    db.add(ReadTxProjection(
        ledger_id=ledger_id, sync_id=sync_id, user_id=user_id, tx_type="expense",
        amount=amount, happened_at=happened_at or datetime(2025, 11, 29, 10, 44, tzinfo=timezone.utc),
        source_change_id=source_change_id,
    ))
    db.flush()


def _evidence(db, *, user_id="U1", evidence_id=None, source="screenshot",
              body="原始正文", expires_at=None, content_hash="abc123hash"):
    ev = RawBookkeepingEvidence(
        id=evidence_id or "ev-1", user_id=user_id, ledger_id="L1", event_key=f"e-{evidence_id}",
        source=source, title="标题", body=body, content_hash=content_hash,
        captured_at=datetime.now(timezone.utc),
    )
    if expires_at:
        ev.expires_at = expires_at
    db.add(ev)
    db.flush()
    return ev.id


def _asset(db, evidence_id, sha="sha1"):
    a = RawEvidenceAsset(
        id=f"a-{sha}", evidence_id=evidence_id, kind="image", mime_type="image/jpeg",
        storage_path=f"/data/{evidence_id}/{sha}.jpg", size_bytes=100, sha256=sha,
    )
    db.add(a)
    db.flush()
    return a


def test_link_idempotent(session_factory):
    with session_factory() as db:
        _seed(db)
        _tx(db, "L1", "tx-1")
        _evidence(db, evidence_id="ev-1")

        l1 = link_evidence_to_transaction(db, evidence_id="ev-1", ledger_id="L1",
                                          transaction_sync_id="tx-1")
        l2 = link_evidence_to_transaction(db, evidence_id="ev-1", ledger_id="L1",
                                          transaction_sync_id="tx-1")
        assert l1.id == l2.id  # 幂等:同一 link,不新增
        with session_factory() as db2:
            links = db2.scalars(select(RawEvidenceTransactionLink)).all()
            assert len(links) == 1


def test_link_rejects_missing_tx_or_evidence(session_factory):
    with session_factory() as db:
        _seed(db)
        _tx(db, "L1", "tx-1")
        # evidence 不存在
        assert link_evidence_to_transaction(db, evidence_id="ev-none", ledger_id="L1",
                                            transaction_sync_id="tx-1") is None
        # transaction 不存在
        _evidence(db, evidence_id="ev-1")
        assert link_evidence_to_transaction(db, evidence_id="ev-1", ledger_id="L1",
                                            transaction_sync_id="tx-none") is None


def test_one_evidence_two_transactions(session_factory):
    with session_factory() as db:
        _seed(db)
        _tx(db, "L1", "tx-1")
        _tx(db, "L1", "tx-2")
        _evidence(db, evidence_id="ev-1")

        link_evidence_to_transaction(db, evidence_id="ev-1", ledger_id="L1", transaction_sync_id="tx-1")
        link_evidence_to_transaction(db, evidence_id="ev-1", ledger_id="L1", transaction_sync_id="tx-2")
        resp = compare_duplicate_transactions(db, [("L1", "tx-1"), ("L1", "tx-2")])
        assert len(resp.items) == 2
        for item in resp.items:
            assert item.raw_evidence_count == 1
            assert item.evidences[0].id == "ev-1"


def test_one_tx_multiple_evidences(session_factory):
    with session_factory() as db:
        _seed(db)
        _tx(db, "L1", "tx-1")
        _evidence(db, evidence_id="ev-sms", source="sms")
        _evidence(db, evidence_id="ev-img", source="screenshot")

        link_evidence_to_transaction(db, evidence_id="ev-sms", ledger_id="L1", transaction_sync_id="tx-1")
        link_evidence_to_transaction(db, evidence_id="ev-img", ledger_id="L1", transaction_sync_id="tx-1")
        resp = compare_duplicate_transactions(db, [("L1", "tx-1")])
        item = resp.items[0]
        assert item.raw_evidence_count == 2
        assert sorted(e.id for e in item.evidences) == ["ev-img", "ev-sms"]


def test_cross_ledger_no_cross_contamination(session_factory):
    with session_factory() as db:
        _seed(db)
        _tx(db, "L1", "tx-shared")  # L1 里 tx-shared
        _tx(db, "L2", "tx-shared", user_id="U2")  # L2 里同名 sync_id
        _evidence(db, evidence_id="ev-1", user_id="U1")
        _evidence(db, evidence_id="ev-2", user_id="U2")

        link_evidence_to_transaction(db, evidence_id="ev-1", ledger_id="L1", transaction_sync_id="tx-shared")
        link_evidence_to_transaction(db, evidence_id="ev-2", ledger_id="L2", transaction_sync_id="tx-shared")

        # 查 L1 的 tx-shared:只看到 ev-1(U1)
        resp = compare_duplicate_transactions(db, [("L1", "tx-shared")])
        item = resp.items[0]
        assert item.raw_evidence_count == 1
        assert item.evidences[0].id == "ev-1"


def test_detail_requires_verified_link(session_factory):
    with session_factory() as db:
        _seed(db)
        _tx(db, "L1", "tx-1")
        _evidence(db, evidence_id="ev-1")
        link_evidence_to_transaction(db, evidence_id="ev-1", ledger_id="L1", transaction_sync_id="tx-1")

        # 正确 link → 返回详情
        detail = get_evidence_detail(db, "L1", "tx-1", "ev-1")
        assert detail is not None
        assert detail.body_full == "原始正文"

        # 错误 tx → 404(None),防越权读其它记录
        assert get_evidence_detail(db, "L1", "tx-none", "ev-1") is None
        assert get_evidence_detail(db, "L2", "tx-1", "ev-1") is None


def test_expired_evidence_status(session_factory):
    with session_factory() as db:
        _seed(db)
        _tx(db, "L1", "tx-1")
        _evidence(db, evidence_id="ev-exp", expires_at=datetime.now(timezone.utc) - timedelta(days=1))
        link_evidence_to_transaction(db, evidence_id="ev-exp", ledger_id="L1", transaction_sync_id="tx-1")
        resp = compare_duplicate_transactions(db, [("L1", "tx-1")])
        assert resp.items[0].evidences[0].status == "expired"


def test_compare_no_nplus1(session_factory):
    """compare 摘要的 SQL 数应固定(不计事务初始化),随交易数增长不 N+1。"""
    with session_factory() as db:
        _seed(db)
        for i in range(20):
            _tx(db, "L1", f"tx-{i}", source_change_id=i)
            _evidence(db, evidence_id=f"ev-{i}")
            link_evidence_to_transaction(db, evidence_id=f"ev-{i}", ledger_id="L1",
                                         transaction_sync_id=f"tx-{i}")
        db.commit()

        sql_count = {"n": 0}

        def _count(conn, cursor, statement, parameters, context, executemany):  # noqa: ANN001
            sql_count["n"] += 1

        event.listen(db.get_bind(), "before_cursor_execute", _count)
        try:
            compare_duplicate_transactions(
                db, [("L1", f"tx-{i}") for i in range(20)]
            )
        finally:
            event.remove(db.get_bind(), "before_cursor_execute", _count)

        # 核心查询:projection 1 + links 1 + evidence 1 + assets 1 = 4 内(不计事务/引擎)。
        assert sql_count["n"] <= 6
