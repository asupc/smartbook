"""初始值仅创建时可设 — Cloud 端契约(web PATCH + mobile push 双路径):

- Web `PATCH /write/ledgers/{id}/accounts/{id}` 带 initial_balance → mutator
  忽略,projection 的 initial_balance 保持创建时值,其余字段照常更新。
- Mobile push 对已有 account 的 upsert(无论 payload 是否携带
  initialBalance)→ projection 的 initial_balance 保持旧值(锁旧值,与
  "partial update keeps existing fields" merge 契约互补)。
- 余额变更走「调整余额」:记一笔 exclude_from_stats 的调整交易(见
  test_web_adjust_balance.py),不修改初始值字段。

补充:创建 POST / push upsert(无已有行)仍设置 initial_balance,不受影响。
"""
from __future__ import annotations

from datetime import datetime, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import User, UserAccountProjection


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


def _iso(dt=None):
    return (dt or datetime.now(timezone.utc)).isoformat()


def _register_app(client: TestClient, email: str, device_id: str = "d1") -> dict:
    """注册 + 以固定设备 id 登录(返回 token; push 按 device_id 校验)。"""
    client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "123456",
            "client_type": "app",
            "device_name": "pytest-app",
            "platform": "app",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "123456",
            "device_id": device_id,
            "client_type": "app",
            "device_name": "pytest-app",
            "platform": "app",
        },
    )
    assert r.status_code == 200, r.text
    return r.json()


def _login_web(client: TestClient, email: str) -> dict:
    res = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "123456",
            "client_type": "web",
            "device_name": "pytest-web",
            "platform": "web",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()


def _seed_snapshot(client: TestClient, token: str, device_id: str, ledger_id: str) -> int:
    now = datetime.now(timezone.utc).isoformat()
    content = (
        f'{{"ledgerName":"{ledger_id}","currency":"CNY","count":0,'
        '"items":[],"accounts":[],"categories":[],"tags":[]}'
    )
    res = client.post(
        "/api/v1/sync/push",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "device_id": device_id,
            "changes": [
                {
                    "ledger_id": ledger_id,
                    "entity_type": "ledger_snapshot",
                    "entity_sync_id": ledger_id,
                    "action": "upsert",
                    "payload": {"content": content},
                    "updated_at": now,
                }
            ],
        },
    )
    assert res.status_code == 200, res.text
    return int(res.json()["server_cursor"])


def _push(client: TestClient, hdr: dict, ledger_id: str, entity_type: str,
          sync_id: str, payload: dict, *, device_id="d1") -> dict:
    body = {
        "ledger_id": ledger_id,
        "entity_type": entity_type,
        "entity_sync_id": sync_id,
        "action": "upsert",
        "updated_at": _iso(),
        "payload": payload,
    }
    r = client.post(
        "/api/v1/sync/push",
        headers=hdr,
        json={"device_id": device_id, "changes": [body]},
    )
    assert r.status_code == 200, r.text
    return r.json()


def _account_row(TS, email: str, sync_id: str) -> UserAccountProjection:
    with TS() as db:
        user_id = db.scalar(select(User.id).where(User.email == email))
        assert user_id is not None
        row = db.scalar(
            select(UserAccountProjection).where(
                UserAccountProjection.user_id == user_id,
                UserAccountProjection.sync_id == sync_id,
            )
        )
        assert row is not None
        db.expunge(row)
        return row


def test_web_patch_cannot_change_initial_balance():
    """Web PATCH 带 initial_balance → 忽略;name 等其余字段照常更新。"""
    client, TS = _make_client()
    try:
        owner = _register_app(client, "owner@example.com")
        app_token = owner["access_token"]
        device_id = "d1"
        cursor = _seed_snapshot(client, app_token, device_id, "L1")

        web_token = _login_web(client, "owner@example.com")["access_token"]
        acc_res = client.post(
            "/api/v1/write/ledgers/L1/accounts",
            headers={"Authorization": f"Bearer {web_token}"},
            json={
                "base_change_id": cursor,
                "name": "WebAcct",
                "account_type": "cash",
                "currency": "CNY",
                "initial_balance": 100,
            },
        )
        assert acc_res.status_code == 200, acc_res.text
        sync_id = acc_res.json()["entity_id"]

        patch_res = client.patch(
            f"/api/v1/write/ledgers/L1/accounts/{sync_id}",
            headers={"Authorization": f"Bearer {web_token}"},
            json={
                "base_change_id": cursor,
                "name": "WebAcct2",
                "initial_balance": 999,
            },
        )
        assert patch_res.status_code == 200, patch_res.text

        row = _account_row(TS, "owner@example.com", sync_id)
        assert row.name == "WebAcct2"
        # 初始值锁旧值:100 而非 999
        assert row.initial_balance == 100
    finally:
        app.dependency_overrides.clear()


def test_mobile_push_update_keeps_initial_balance():
    """对已有 account 的 push upsert(带新 initialBalance)→ projection 锁旧值。"""
    client, TS = _make_client()
    try:
        owner = _register_app(client, "push@example.com")
        token = owner["access_token"]
        device_id = "d1"
        hdr = {"Authorization": f"Bearer {token}"}

        _seed_snapshot(client, token, device_id, "L1")
        _push(client, hdr, "L1", "account", "acc-x", {
            "syncId": "acc-x",
            "name": "Cash",
            "type": "cash",
            "currency": "CNY",
            "initialBalance": 100,
        })
        _push(client, hdr, "L1", "account", "acc-x", {
            "syncId": "acc-x",
            "name": "Cash2",
            "initialBalance": 999,
        })

        row = _account_row(TS, "push@example.com", "acc-x")
        assert row.name == "Cash2"
        # 初始值锁旧值:100 而非 999
        assert row.initial_balance == 100
    finally:
        app.dependency_overrides.clear()


def test_push_create_still_sets_initial_balance():
    """没有已有行的 push upsert(创建)→ initialBalance 正常落库。"""
    client, TS = _make_client()
    try:
        owner = _register_app(client, "create@example.com")
        hdr = {"Authorization": f"Bearer {owner['access_token']}"}
        _seed_snapshot(client, owner["access_token"], "d1", "L1")
        _push(client, hdr, "L1", "account", "acc-new", {
            "syncId": "acc-new",
            "name": "New",
            "type": "cash",
            "initialBalance": 50,
        })
        row = _account_row(TS, "create@example.com", "acc-new")
        assert row.initial_balance == 50
    finally:
        app.dependency_overrides.clear()
