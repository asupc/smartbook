"""P1-A3 —— 交易物理 purge 时 compact 其 upsert 事件历史。

覆盖两个物理 purge 入口:
- data_cleanup cleaner(每日 retention / admin 手动批量清理):purge N 笔
  过期回收站交易后,各自的 upsert 事件被 compact、delete 墓碑保留、
  非涉及实体(其它交易 / user-global 实体)的事件不受影响;
- read/trash.py 的 purge 端点(手动「彻底删除」)同款 compact。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base
from src.main import app
from src.models import Ledger, ReadTxProjection, SyncChange, User
from src.services.data_cleanup.cleaner import clean
from src.services.data_cleanup.scanner import scan_all
from tests.test_tx_batch_delete import (
    _create_ledger,
    _make_client,
    _register_and_login,
    _seed_txs,
)


def _mk_session_factory():
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)
    return sessionmaker(bind=engine, autocommit=False, autoflush=False)


def _add_change(
    db,
    *,
    user_id: str,
    ledger_id: str | None,
    entity_type: str,
    sync_id: str,
    action: str,
) -> None:
    db.add(
        SyncChange(
            user_id=user_id,
            ledger_id=ledger_id,
            scope="ledger" if ledger_id else "user",
            entity_type=entity_type,
            entity_sync_id=sync_id,
            action=action,
            payload_json={},
            updated_at=datetime.now(timezone.utc),
        )
    )


def test_cleaner_purge_compacts_tx_upsert_events_keeps_tombstone():
    """purge 过期回收站交易 → 该 tx 的 upsert 事件消失、delete 墓碑保留,
    其它交易 / 其它实体的事件原样。"""
    Session = _mk_session_factory()
    with Session() as db:
        db.add(User(id="u1", email="t@t.com", password_hash="x",
                    created_at=datetime.now(timezone.utc)))
        db.add(Ledger(id="L1", external_id="lg1", name="T", currency="CNY",
                      user_id="u1", created_at=datetime.now(timezone.utc)))
        now = datetime.now(timezone.utc)
        db.add(ReadTxProjection(
            ledger_id="L1", sync_id="tx-old", user_id="u1", tx_type="expense",
            amount=5.0, happened_at=now, deleted_at=now - timedelta(days=31),
        ))
        db.add(ReadTxProjection(
            ledger_id="L1", sync_id="tx-fresh", user_id="u1", tx_type="expense",
            amount=6.0, happened_at=now, deleted_at=now - timedelta(days=2),
        ))
        db.add(ReadTxProjection(
            ledger_id="L1", sync_id="tx-live", user_id="u1", tx_type="expense",
            amount=7.0, happened_at=now,
        ))
        # tx-old:2 条 upsert + 1 条 delete(墓碑);其余实体各留事件
        _add_change(db, user_id="u1", ledger_id="L1", entity_type="transaction",
                    sync_id="tx-old", action="upsert")
        _add_change(db, user_id="u1", ledger_id="L1", entity_type="transaction",
                    sync_id="tx-old", action="upsert")
        _add_change(db, user_id="u1", ledger_id="L1", entity_type="transaction",
                    sync_id="tx-old", action="delete")
        _add_change(db, user_id="u1", ledger_id="L1", entity_type="transaction",
                    sync_id="tx-fresh", action="upsert")
        _add_change(db, user_id="u1", ledger_id="L1", entity_type="transaction",
                    sync_id="tx-live", action="upsert")
        _add_change(db, user_id="u1", ledger_id=None, entity_type="category",
                    sync_id="cat-1", action="upsert")
        db.commit()

        report = scan_all(db)
        assert [r.sync_id for r in report.expired_trash] == ["tx-old"]

        result = clean(db, report.expired_trash)
        assert result.success_count == 1
        assert db.get(ReadTxProjection, ("L1", "tx-old")) is None

        def _actions(sync_id: str) -> list[str]:
            return [
                row.action
                for row in db.execute(
                    select(SyncChange.action).where(
                        SyncChange.user_id == "u1",
                        SyncChange.entity_type == "transaction",
                        SyncChange.entity_sync_id == sync_id,
                    )
                ).all()
            ]

        # 被 purge 的 tx:upsert 全部 compact,delete 墓碑保留
        assert _actions("tx-old") == ["delete"]
        # 未涉及实体不受影响
        assert _actions("tx-fresh") == ["upsert"]
        assert _actions("tx-live") == ["upsert"]
        cat_rows = db.execute(
            select(SyncChange).where(SyncChange.entity_type == "category")
        ).all()
        assert len(cat_rows) == 1


def test_trash_purge_endpoint_compacts_upsert_events():
    """手动「彻底删除」端点:purge 后该 tx 只剩 delete 墓碑事件。"""
    client = _make_client()
    try:
        token = _register_and_login(client, "purge-compact@test.com")
        ledger_id = _create_ledger(client, token)
        victim, keeper = _seed_txs(client, token, ledger_id, n=2)

        # 软删(产生 upsert 历史 + delete 墓碑)
        r = client.request(
            "DELETE",
            f"/api/v1/write/ledgers/{ledger_id}/transactions/{victim}",
            json={"base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text

        # 彻底删除
        r = client.post(
            f"/api/v1/read/workspace/trash/{victim}/purge",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        assert r.json()["ok"] is True

        # _make_client 的 engine 在闭包里拿不到,经 API 断言:purge 后 restore
        # 应 404(行已物理删),事件面走 /sync/pull 检查。
        r = client.post(
            f"/api/v1/read/workspace/trash/{victim}/restore",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 404

        r = client.get(
            "/api/v1/sync/pull?since=0&limit=500",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        by_entity: dict[str, list[str]] = {}
        for c in r.json()["changes"]:
            if c.get("entity_type") == "transaction":
                by_entity.setdefault(c["entity_sync_id"], []).append(c["action"])
        # victim 只剩 delete 墓碑;keeper 的 upsert 完好
        assert by_entity.get(victim) == ["delete"], by_entity.get(victim)
        assert by_entity.get(keeper) == ["upsert"]
    finally:
        app.dependency_overrides.clear()
