"""软删 × LWW 交叉语义(复活语义)回归测试(P0-5,2026-09)。

锁定契约(SYNC_ARCHITECTURE §4.8):
  - LWW 最新者胜:delete 之后更晚 updated_at 的 upsert 胜出 → 行复活
    (deleted_at 被清 NULL),内容为胜出 upsert 的版本;服务端 /read/*、
    统计、pull 三方一致;
  - delete 胜出(upsert 的 updated_at 更早)→ push 层 LWW 拒绝,行保持
    软删,upsert 不入事件流、不广播 —— 消灭「服务端视其不存在但 pull 端
    重建交易」的幽灵状态。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import ReadTxProjection, SyncChange


def _make_client():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    TS = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override():
        db = TS()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override
    return TestClient(app), TS


def _register(client, email, device):
    r = client.post("/api/v1/auth/register", json={
        "email": email,
        "password": "Pa$$word1!",
        "device_id": device,
        "client_type": "app",
        "device_name": f"pytest-{device}",
        "platform": "test",
    })
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _login(client, email, device):
    r = client.post("/api/v1/auth/login", json={
        "email": email,
        "password": "Pa$$word1!",
        "device_id": device,
        "client_type": "app",
        "device_name": f"pytest-{device}",
        "platform": "test",
    })
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _login_web(client, email, device="d-web"):
    r = client.post("/api/v1/auth/login", json={
        "email": email,
        "password": "Pa$$word1!",
        "device_id": device,
        "client_type": "web",
        "device_name": "pytest-web",
        "platform": "web",
    })
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _push(client, token, device, entity_type, sync_id, payload, *,
          action="upsert", ledger_id="lg1", updated_at):
    r = client.post(
        "/api/v1/sync/push",
        headers={"Authorization": f"Bearer {token}"},
        json={"device_id": device, "changes": [{
            "ledger_id": ledger_id,
            "entity_type": entity_type,
            "entity_sync_id": sync_id,
            "action": action,
            "updated_at": updated_at.isoformat(),
            "payload": payload,
        }]},
    )
    assert r.status_code == 200, r.text
    return r.json()


def _tx_payload(amount, at):
    return {
        "syncId": "tx1",
        "type": "expense",
        "amount": amount,
        "happenedAt": at.isoformat(),
        "note": f"amount={amount}",
    }


def test_upsert_newer_than_delete_revives_transaction():
    """④ A push delete → B push 更晚 updated_at 的 upsert → 行复活
    (deleted_at IS NULL)、统计包含该交易、第三端 pull 可见。"""
    client, TS = _make_client()
    try:
        email = "p05-revive@t.com"
        tok_a = _register(client, email, "dev-a")        # 设备 A(删除方)
        tok_b = _login(client, email, "dev-b")           # 设备 B(离线编辑方)
        tok_c = _login(client, email, "dev-c")           # 设备 C(观察方)
        web_tok = _login_web(client, email)

        base = datetime.now(timezone.utc) - timedelta(minutes=5)
        _push(client, tok_a, "dev-a", "transaction", "tx1",
              _tx_payload(100, base), updated_at=base)
        _push(client, tok_a, "dev-a", "transaction", "tx1",
              {}, action="delete", updated_at=base + timedelta(seconds=10))

        # 前置:软删生效(读路径 + 统计都过滤)
        r = client.get("/api/v1/read/ledgers/lg1/transactions",
                       headers={"Authorization": f"Bearer {web_tok}"})
        assert r.status_code == 200, r.text
        assert all(t["id"] != "tx1" for t in r.json())
        r = client.get("/api/v1/read/summary", params={"ledger_id": "lg1"},
                       headers={"Authorization": f"Bearer {web_tok}"})
        assert r.json()["transaction_count"] == 0

        # B 离线编辑后 push:updated_at 比 delete 更晚 → LWW 胜出 → 复活
        resp = _push(client, tok_b, "dev-b", "transaction", "tx1",
                     _tx_payload(200, base + timedelta(seconds=30)),
                     updated_at=base + timedelta(seconds=30))
        assert resp["accepted"] == 1, resp

        with TS() as db:
            row = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.sync_id == "tx1"
            ))
            assert row is not None
            assert row.deleted_at is None, "LWW-winning upsert must revive"
            assert row.amount == 200.0
            assert row.note == "amount=200"

        # 统计/读路径重新包含该交易
        r = client.get("/api/v1/read/ledgers/lg1/transactions",
                       headers={"Authorization": f"Bearer {web_tok}"})
        ids = [t["id"] for t in r.json()]
        assert "tx1" in ids, ids
        r = client.get("/api/v1/read/summary", params={"ledger_id": "lg1"},
                       headers={"Authorization": f"Bearer {web_tok}"})
        assert r.json()["transaction_count"] == 1

        # 第三端 pull 可见(拿到最新 upsert,B 的版本)
        r = client.get("/api/v1/sync/pull?since=0&device_id=dev-c",
                       headers={"Authorization": f"Bearer {tok_c}"})
        assert r.status_code == 200, r.text
        tx_changes = [c for c in r.json()["changes"]
                      if c["entity_type"] == "transaction" and c["entity_sync_id"] == "tx1"]
        assert any(c.get("payload", {}).get("amount") == 200 for c in tx_changes), tx_changes
    finally:
        app.dependency_overrides.clear()


def test_upsert_older_than_delete_stays_soft_deleted_without_upsert_replay():
    """⑤ B 的 upsert 早于 delete 的 updated_at → 仍软删、无 upsert 广播
    (LWW 拒绝,事件流不增加 upsert 行)。"""
    client, TS = _make_client()
    try:
        email = "p05-tomb@t.com"
        tok_a = _register(client, email, "dev-a")
        tok_b = _login(client, email, "dev-b")
        web_tok = _login_web(client, email)

        base = datetime.now(timezone.utc) - timedelta(minutes=5)
        _push(client, tok_a, "dev-a", "transaction", "tx1",
              _tx_payload(100, base), updated_at=base)
        # delete 在 T+10;B 的离线编辑只到 T+5(LWW 输)
        _push(client, tok_a, "dev-a", "transaction", "tx1",
              {}, action="delete", updated_at=base + timedelta(seconds=10))

        resp = _push(client, tok_b, "dev-b", "transaction", "tx1",
                     _tx_payload(300, base + timedelta(seconds=5)),
                     updated_at=base + timedelta(seconds=5))
        assert resp["rejected"] == 1, resp
        assert resp["conflict_count"] == 1, resp

        with TS() as db:
            row = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.sync_id == "tx1"
            ))
            assert row is not None
            assert row.deleted_at is not None, "older upsert must not revive"
            assert row.amount == 100.0  # A 删除前的内容原样

            # 事件流:原 upsert + delete,恰好 2 条;被拒的 upsert 没有落进去
            changes = db.scalars(select(SyncChange).where(
                SyncChange.entity_type == "transaction",
                SyncChange.entity_sync_id == "tx1",
            )).all()
            assert len(changes) == 2, [c.change_id for c in changes]
            assert {c.action for c in changes} == {"upsert", "delete"}
            # 最新一条是 delete(第三端 pull 重放后交易保持删除)
            latest = max(changes, key=lambda c: c.change_id)
            assert latest.action == "delete"

        # 读路径/统计仍然过滤
        r = client.get("/api/v1/read/ledgers/lg1/transactions",
                       headers={"Authorization": f"Bearer {web_tok}"})
        assert all(t["id"] != "tx1" for t in r.json())
        r = client.get("/api/v1/read/summary", params={"ledger_id": "lg1"},
                       headers={"Authorization": f"Bearer {web_tok}"})
        assert r.json()["transaction_count"] == 0
    finally:
        app.dependency_overrides.clear()
