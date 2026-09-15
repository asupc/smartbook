"""S7:Idempotency-Key 过期回放 + S8:create_ledger 并发 IntegrityError → 409。"""
from __future__ import annotations

from datetime import timedelta

from sqlalchemy import create_engine, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import SyncPushIdempotency
from tests.test_tx_batch_delete import (
    _create_ledger,
    _make_client,
    _register_and_login,
)


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"}


def _create_one_tx(client, token: str, ledger_id: str, amount: float, idem: str):
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        json={
            "base_change_id": 0,
            "tx_type": "expense",
            "amount": amount,
            "happened_at": "2026-05-06T12:30:00Z",
            "note": f"tx-{amount}",
        },
        headers={**_auth(token), "Idempotency-Key": idem},
    )


def test_s7_expired_key_treated_as_miss():
    """过期行不回放:重发视为新请求(replayed=False),旧行被顺带删除。"""
    client = _make_client()
    try:
        token = _register_and_login(client, "s7a@test.com")
        ledger_id = _create_ledger(client, token)

        r1 = _create_one_tx(client, token, ledger_id, 10.0, "idem-s7")
        assert r1.status_code == 200, r1.text
        assert r1.json()["idempotency_replayed"] is False

        # 未过期回放:同 key 同 payload → replay
        r2 = _create_one_tx(client, token, ledger_id, 10.0, "idem-s7")
        assert r2.status_code == 200, r2.text
        assert r2.json()["idempotency_replayed"] is True

        # 把行改成已过期 → 按 miss 处理:新 change、replayed=False
        db = next(app.dependency_overrides[get_db]())
        idem_row = db.scalar(
            select(SyncPushIdempotency).where(
                SyncPushIdempotency.idempotency_key == "idem-s7"
            )
        )
        idem_row.expires_at = idem_row.created_at - timedelta(hours=1)
        db.commit()

        r3 = _create_one_tx(client, token, ledger_id, 10.0, "idem-s7")
        assert r3.status_code == 200, r3.text
        assert r3.json()["idempotency_replayed"] is False
        assert r3.json()["new_change_id"] > r1.json()["new_change_id"]

        # 过期旧行被顺带删掉,只剩新行(r3 写的)
        rows = db.scalars(
            select(SyncPushIdempotency).where(
                SyncPushIdempotency.idempotency_key == "idem-s7"
            )
        ).all()
        assert len(rows) == 1
        assert rows[0].response_json["new_change_id"] == r3.json()["new_change_id"]
    finally:
        app.dependency_overrides.clear()


def test_s8_create_ledger_integrity_error_returns_409(monkeypatch):
    """TOCTOU 兜底:exists 预检通过后 flush 抛 IntegrityError → 409 而非 500。

    用自定义 Session 让第一次 flush(ledger 插入)抛 IntegrityError,
    模拟并发同 external_id 已落库。"""
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)

    from src.models import Ledger

    class _RacingSession(sessionmaker(bind=engine, autoflush=False).class_):
        """带 pending Ledger 插入的 flush 抛 IntegrityError(模拟并发同
        external_id 已落库的 TOCTOU 窗口);其余 flush 正常。"""

        def flush(self, *a, **k):
            if any(isinstance(o, Ledger) for o in self.new):
                raise IntegrityError("dup", None, Exception("unique"))
            return super().flush(*a, **k)

    Session = sessionmaker(bind=engine, autoflush=False, class_=_RacingSession)

    def override_get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    from fastapi.testclient import TestClient

    client = TestClient(app)
    try:
        token = _register_and_login(client, "s8a@test.com")
        r = client.post(
            "/api/v1/write/ledgers",
            json={"ledger_id": "race-ledger", "ledger_name": "R", "currency": "CNY"},
            headers=_auth(token),
        )
        assert r.status_code == 409, r.text
        assert "exists" in r.json()["detail"].lower()
    finally:
        app.dependency_overrides.clear()


def test_s8_sequential_duplicate_still_409():
    """顺序重复(非竞态)行为不变。"""
    client = _make_client()
    try:
        token = _register_and_login(client, "s8b@test.com")
        _create_ledger(client, token, name="dup")
        r = client.post(
            "/api/v1/write/ledgers",
            json={"ledger_name": "dup", "currency": "CNY"},
            headers=_auth(token),
        )
        # 不带 ledger_id 时 external_id 随机生成,不会撞;显式同 id 才 409
        assert r.status_code == 200
        same_id = r.json()["entity_id"]
        r2 = client.post(
            "/api/v1/write/ledgers",
            json={"ledger_id": same_id, "ledger_name": "dup2", "currency": "CNY"},
            headers=_auth(token),
        )
        assert r2.status_code == 409
    finally:
        app.dependency_overrides.clear()
