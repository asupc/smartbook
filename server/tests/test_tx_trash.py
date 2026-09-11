"""交易回收站(0030 软删)端到端测试。

覆盖:删除→软删生效(读路径过滤)→回收站列表→恢复(行回归读路径)→
彻底删除(物理删行)。附件 GC 的延后语义由 cleaner 测试域覆盖。
"""
from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import ReadTxProjection

from tests.test_tx_batch_delete import (
    _create_ledger,
    _make_client,
    _register_and_login,
    _seed_txs,
)


def test_trash_lifecycle_soft_delete_restore_purge():
    client = _make_client()
    try:
        token = _register_and_login(client, "trash1@test.com")
        ledger_id = _create_ledger(client, token)
        tx_ids = _seed_txs(client, token, ledger_id, n=2)
        victim, keeper = tx_ids

        # 读路径先可见
        r = client.get(
            f"/api/v1/read/ledgers/{ledger_id}/transactions",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200
        items = r.json()  # 裸数组(上游契约)
        visible = {t["id"] for t in items}
        assert visible == set(tx_ids)

        # 单笔删除 → 软删
        r = client.request(
            "DELETE",
            f"/api/v1/write/ledgers/{ledger_id}/transactions/{victim}",
            json={"base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text

        # 列表不再出现(读路径过滤),summary 也过滤
        r = client.get(
            f"/api/v1/read/ledgers/{ledger_id}/transactions",
            headers={"Authorization": f"Bearer {token}"},
        )
        visible = {t["id"] for t in r.json()}
        assert victim not in visible and keeper in visible

        r = client.get(
            "/api/v1/read/summary",
            params={"ledger_id": ledger_id},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200
        assert r.json()["transaction_count"] == 1

        # 回收站列表可见,含剩余天数
        r = client.get(
            "/api/v1/read/workspace/trash",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["total"] == 1
        item = body["items"][0]
        assert item["sync_id"] == victim
        assert 0 <= item["days_left"] <= 30

        # 恢复 → 读路径回归 + 产生 upsert change
        r = client.post(
            f"/api/v1/read/workspace/trash/{victim}/restore",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        assert r.json()["ok"] is True
        assert r.json()["new_change_id"] is not None

        r = client.get(
            f"/api/v1/read/ledgers/{ledger_id}/transactions",
            headers={"Authorization": f"Bearer {token}"},
        )
        items = r.json()  # 裸数组(上游契约)
        visible = {t["id"] for t in items}
        assert visible == set(tx_ids)

        # 回收站已空
        r = client.get(
            "/api/v1/read/workspace/trash",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.json()["total"] == 0

        # 再删一次 → purge 物理删除(投影行真正消失,经读路径验证)
        client.request(
            "DELETE",
            f"/api/v1/write/ledgers/{ledger_id}/transactions/{victim}",
            json={"base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        r = client.post(
            f"/api/v1/read/workspace/trash/{victim}/purge",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        assert r.json()["ok"] is True

        r = client.get(
            "/api/v1/read/workspace/trash",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.json()["total"] == 0

        # 恢复一个不存在的 → 404
        r = client.post(
            f"/api/v1/read/workspace/trash/{victim}/restore",
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_trash_scanner_and_cleaner_roundtrip():
    """scanner D1 + cleaner D1:软删超 30 天的行被发现并物理清除,未过期不动。"""
    from datetime import datetime, timedelta, timezone

    from src.models import Ledger, User
    from src.services.data_cleanup.cleaner import clean
    from src.services.data_cleanup.scanner import scan_all

    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine)
    db = Session()
    try:
        user = User(
            id="u1", email="t@t.com", password_hash="x", created_at=datetime.now(timezone.utc)
        )
        ledger = Ledger(
            id="L1",
            external_id="lg1",
            name="T",
            currency="CNY",
            user_id="u1",
            created_at=datetime.now(timezone.utc),
        )
        db.add_all([user, ledger])
        db.add(ReadTxProjection(
            ledger_id="L1", sync_id="tx-old", user_id="u1", tx_type="expense",
            amount=5.0, happened_at=datetime.now(timezone.utc),
            deleted_at=datetime.now(timezone.utc) - timedelta(days=31),
        ))
        db.add(ReadTxProjection(
            ledger_id="L1", sync_id="tx-fresh", user_id="u1", tx_type="expense",
            amount=6.0, happened_at=datetime.now(timezone.utc),
            deleted_at=datetime.now(timezone.utc) - timedelta(days=2),
        ))
        db.commit()

        report = scan_all(db)
        assert [r.sync_id for r in report.expired_trash] == ["tx-old"]

        result = clean(db, report.expired_trash)
        assert result.success_count == 1
        assert db.get(ReadTxProjection, ("L1", "tx-old")) is None
        # 未过期行保留
        assert db.get(ReadTxProjection, ("L1", "tx-fresh")) is not None
    finally:
        db.close()
        engine.dispose()
