"""push 批次3隔离不留孤儿事件行(2026-09 修复)。

回归背景:SyncChange 先 add+flush 到外层事务、再进 savepoint 应用投影,apply
抛错时 savepoint 只回滚投影应用,孤儿事件行随外层 commit 落库 —— 其它设备
pull 会按事件删掉服务端仍有的实体(事件流/投影分裂),且孤儿行成为该实体的
LWW 最新,同 device 同时间戳重推命中幂等回放被跳过,分裂无法自愈。

修复后 add+flush 在 savepoint 内:失败条目连 SyncChange 行一起回滚,解除引用
后重推即成功(与 sync_applier._delete_user_account docstring 的承诺一致)。
触发路径用设计内的 guard:删除仍被活跃交易引用的账户。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import SyncChange, UserAccountProjection


def _make_client() -> tuple[TestClient, sessionmaker]:
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


def _register(client: TestClient, email: str) -> dict:
    res = client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "123456",
            "client_type": "app",
            "device_name": "pytest-app",
            "platform": "app",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()


def _push(
    client: TestClient, token: str, device: str, changes: list[dict]
) -> dict:
    res = client.post(
        "/api/v1/sync/push",
        headers={"Authorization": f"Bearer {token}"},
        json={"device_id": device, "changes": changes},
    )
    assert res.status_code == 200, res.text
    return res.json()


def _seed_ledger(client: TestClient, token: str, device_id: str, ledger_id: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    content = (
        f'{{"ledgerName":"{ledger_id}","currency":"CNY","count":0,'
        '"items":[],"accounts":[],"categories":[],"tags":[]}'
    )
    body = _push(client, token, device_id, [
        {
            "ledger_id": ledger_id,
            "entity_type": "ledger_snapshot",
            "entity_sync_id": ledger_id,
            "action": "upsert",
            "payload": {"content": content},
            "updated_at": now,
        }
    ])
    assert body["accepted"] == 1, body


def test_failed_apply_leaves_no_orphan_account_delete_event() -> None:
    client, TS = _make_client()
    try:
        owner = _register(client, "push-orphan@example.com")
        token, device = owner["access_token"], owner["device_id"]
        ledger_id = "L_ORPHAN"
        _seed_ledger(client, token, device, ledger_id)

        t0 = datetime.now(timezone.utc)
        # 建账户 + 一笔引用该账户的交易
        body = _push(client, token, device, [
            {
                "entity_type": "account",
                "entity_sync_id": "acc-guard",
                "action": "upsert",
                "payload": {"syncId": "acc-guard", "name": "微信零钱"},
                "updated_at": t0.isoformat(),
            }
        ])
        assert body["accepted"] == 1, body

        body = _push(client, token, device, [
            {
                "ledger_id": ledger_id,
                "entity_type": "transaction",
                "entity_sync_id": "tx-guard",
                "action": "upsert",
                "payload": {
                    "syncId": "tx-guard",
                    "type": "expense",
                    "amount": 5.0,
                    "happenedAt": t0.isoformat(),
                    "accountId": "acc-guard",
                },
                "updated_at": t0.isoformat(),
            }
        ])
        assert body["accepted"] == 1, body

        # 删除仍被活跃交易引用的账户 → guard ValueError → 批次3隔离为 failed
        body = _push(client, token, device, [
            {
                "entity_type": "account",
                "entity_sync_id": "acc-guard",
                "action": "delete",
                "payload": {},
                "updated_at": (t0 + timedelta(seconds=5)).isoformat(),
            }
        ])
        assert body["failed_count"] == 1, body
        assert body["accepted"] == 0, body

        # 回归核心:失败条目不得留下孤儿 SyncChange 行(旧行为会随外层 commit 落库)
        with TS() as db:
            orphans = db.scalars(
                select(SyncChange).where(
                    SyncChange.entity_type == "account",
                    SyncChange.entity_sync_id == "acc-guard",
                    SyncChange.action == "delete",
                )
            ).all()
            assert orphans == [], f"orphan account:delete event rows: {orphans}"
            acc = db.scalar(
                select(UserAccountProjection).where(
                    UserAccountProjection.sync_id == "acc-guard"
                )
            )
            assert acc is not None, "account projection must survive failed delete"

        # 软删交易解除引用后,同一 delete 重推成功(自愈路径)
        body = _push(client, token, device, [
            {
                "ledger_id": ledger_id,
                "entity_type": "transaction",
                "entity_sync_id": "tx-guard",
                "action": "delete",
                "payload": {},
                "updated_at": (t0 + timedelta(seconds=10)).isoformat(),
            }
        ])
        assert body["accepted"] == 1, body

        body = _push(client, token, device, [
            {
                "entity_type": "account",
                "entity_sync_id": "acc-guard",
                "action": "delete",
                "payload": {},
                "updated_at": (t0 + timedelta(seconds=15)).isoformat(),
            }
        ])
        assert body["accepted"] == 1, body

        with TS() as db:
            deletes = db.scalars(
                select(SyncChange).where(
                    SyncChange.entity_type == "account",
                    SyncChange.entity_sync_id == "acc-guard",
                    SyncChange.action == "delete",
                )
            ).all()
            assert len(deletes) == 1, "retry must produce exactly one delete event"
            acc = db.scalar(
                select(UserAccountProjection).where(
                    UserAccountProjection.sync_id == "acc-guard"
                )
            )
            assert acc is None, "account projection must be gone after successful retry"
    finally:
        app.dependency_overrides.clear()
