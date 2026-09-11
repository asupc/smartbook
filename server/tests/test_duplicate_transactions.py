"""重复交易检测 / 清理单测。

构造同账本内 (tx_type + 金额 + 时间) 相同的多笔交易 → scan 分组 → clean 删除
→ 重扫为空,验证保留 keeper 的规则与附件 GC 链路。
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base
from src.models import Ledger, ReadTxProjection, SyncChange, User
from src.schemas import DuplicateDeleteItem
from src.services.data_cleanup import clean_duplicate_transactions, scan_duplicate_transactions


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
    db.add(
        Ledger(
            id="L1",
            user_id="U1",
            external_id="ext-L1",
            name="默认账本",
            currency="CNY",
        )
    )
    db.flush()


def _tx(db, sync_id, *, amount=10.0, happened_at=None, tx_type="expense", source_change_id=0):
    db.add(
        ReadTxProjection(
            ledger_id="L1",
            sync_id=sync_id,
            user_id="U1",
            tx_type=tx_type,
            amount=amount,
            happened_at=happened_at or datetime(2025, 11, 29, 10, 44, 58, tzinfo=timezone.utc),
            source_change_id=source_change_id,
        )
    )


def test_scan_groups_exact_duplicates(session_factory):
    with session_factory() as db:
        _seed(db)
        t = datetime(2025, 11, 29, 10, 44, 58, tzinfo=timezone.utc)
        _tx(db, "tx-a", amount=28.36, happened_at=t, source_change_id=10)
        _tx(db, "tx-b", amount=28.36, happened_at=t, source_change_id=20)
        # 金额不同 → 不算重复
        _tx(db, "tx-c", amount=28.35, happened_at=t, source_change_id=30)
        db.commit()

        groups = scan_duplicate_transactions(db)
        assert len(groups) == 1
        g = groups[0]
        assert g.count == 2
        # keeper = source_change_id 最小的 tx-a
        assert g.keep_sync_id == "tx-a"
        keepers = [i for i in g.items if i.is_keeper]
        assert [i.sync_id for i in keepers] == ["tx-a"]


def test_scan_ignores_tx_type(session_factory):
    """收支类型不同、金额+分钟相同 → 仍判重(类型已从分组键移除)。"""
    with session_factory() as db:
        _seed(db)
        t = datetime(2025, 11, 29, 10, 44, 58, tzinfo=timezone.utc)
        _tx(db, "tx-a", amount=10.0, happened_at=t, tx_type="expense")
        _tx(db, "tx-b", amount=10.0, happened_at=t, tx_type="income")
        db.commit()
        groups = scan_duplicate_transactions(db)
        assert len(groups) == 1
        assert groups[0].count == 2
        assert {i.sync_id for i in groups[0].items} == {"tx-a", "tx-b"}


def test_scan_groups_same_minute_different_seconds(session_factory):
    """秒位不同但同一分钟 → 视为重复(部分入口时间没有秒)。"""
    with session_factory() as db:
        _seed(db)
        t1 = datetime(2025, 11, 29, 10, 44, 2, tzinfo=timezone.utc)
        t2 = datetime(2025, 11, 29, 10, 44, 58, tzinfo=timezone.utc)
        _tx(db, "tx-a", amount=28.36, happened_at=t1, source_change_id=10)
        _tx(db, "tx-b", amount=28.36, happened_at=t2, source_change_id=20)
        # 跨分钟(10:45:00) → 不算重复
        t3 = datetime(2025, 11, 29, 10, 45, 0, tzinfo=timezone.utc)
        _tx(db, "tx-c", amount=28.36, happened_at=t3, source_change_id=30)
        db.commit()

        groups = scan_duplicate_transactions(db)
        assert len(groups) == 1
        assert groups[0].count == 2
        assert {i.sync_id for i in groups[0].items} == {"tx-a", "tx-b"}


def test_clean_deletes_selected_and_keeps_keeper(session_factory):
    with session_factory() as db:
        _seed(db)
        t = datetime(2025, 11, 29, 10, 44, 58, tzinfo=timezone.utc)
        _tx(db, "tx-a", amount=28.36, happened_at=t, source_change_id=10)
        _tx(db, "tx-b", amount=28.36, happened_at=t, source_change_id=20)
        db.commit()

        result = clean_duplicate_transactions(
            db, [DuplicateDeleteItem(ledger_id="L1", sync_id="tx-b")]
        )
        db.commit()
        assert result.success_count == 1
        assert result.failures == []

        # tx-b 被删(0030 软删:行保留+盖章),tx-a 保留;且生成了 delete change。
        row_b = db.get(ReadTxProjection, ("L1", "tx-b"))
        assert row_b is not None and row_b.deleted_at is not None
        assert db.get(ReadTxProjection, ("L1", "tx-a")) is not None
        deletes = db.scalars(
            select(SyncChange).where(
                SyncChange.ledger_id == "L1",
                SyncChange.entity_type == "transaction",
                SyncChange.action == "delete",
            )
        ).all()
        assert [d.entity_sync_id for d in deletes] == ["tx-b"]

        # 重扫为空
        assert scan_duplicate_transactions(db) == []
