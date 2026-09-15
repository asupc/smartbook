"""删标签级联补发跳过回收站(软删)交易(2026-09 修复)。

回归背景:快路径级联行查询不过滤 deleted_at,软删(回收站)交易被序列化成
cascade-only transaction:upsert 下发,mobile 端 upsert 分支按 INSERT 重建
已删交易 → 回收站交易在所有手机复活、与服务端投影(仍软删)分裂。修复后
级联子集只取活跃行;投影剥离 SQL 仍会清理软删行,restore 后自然干净。
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, update
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import ReadTxProjection, SyncChange


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


def _latest_change_id(client: TestClient, token: str, ledger_id: str) -> int:
    res = client.get(
        f"/api/v1/read/ledgers/{ledger_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200
    return int(res.json()["source_change_id"])


def _create_tag(client: TestClient, token: str, ledger_id: str, *, name: str) -> str:
    base = _latest_change_id(client, token, ledger_id)
    res = client.post(
        f"/api/v1/write/ledgers/{ledger_id}/tags",
        headers={"Authorization": f"Bearer {token}"},
        json={"base_change_id": base, "name": name, "color": None},
    )
    assert res.status_code == 200, res.text
    listing = client.get(
        f"/api/v1/read/ledgers/{ledger_id}/tags",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert listing.status_code == 200, listing.text
    matched = next((t for t in listing.json() if t["name"] == name), None)
    assert matched, f"created tag not found: {name}"
    return matched["id"]


def _push_tx_with_tag(
    client: TestClient,
    app_token: str,
    device: str,
    ledger_id: str,
    *,
    sync_id: str,
    tag_name: str,
    tag_id: str,
) -> None:
    now = (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat()
    body = _push(client, app_token, device, [
        {
            "ledger_id": ledger_id,
            "entity_type": "transaction",
            "entity_sync_id": sync_id,
            "action": "upsert",
            "payload": {
                "syncId": sync_id,
                "type": "expense",
                "amount": 10.0,
                "happenedAt": now,
                "tags": tag_name,
                "tagIds": [tag_id],
            },
            "updated_at": now,
        }
    ])
    assert body["accepted"] == 1, body


def test_tag_delete_cascade_skips_soft_deleted_tx() -> None:
    client, TS = _make_client()
    try:
        owner = _register(client, "tag-trash@example.com")
        app_token, device = owner["access_token"], owner["device_id"]
        ledger_id = "L_TAG_TRASH"
        _seed_ledger(client, app_token, device, ledger_id)

        web = _login_web(client, "tag-trash@example.com")
        token = web["access_token"]
        tag = _create_tag(client, token, ledger_id, name="待删标签")

        _push_tx_with_tag(
            client, app_token, device, ledger_id,
            sync_id="tx-alive", tag_name="待删标签", tag_id=tag,
        )
        _push_tx_with_tag(
            client, app_token, device, ledger_id,
            sync_id="tx-dead", tag_name="待删标签", tag_id=tag,
        )

        # tx-dead 进回收站(web 软删的等价终态:deleted_at 置位)
        with TS() as db:
            db.execute(
                update(ReadTxProjection)
                .where(ReadTxProjection.sync_id == "tx-dead")
                .values(deleted_at=datetime.now(timezone.utc))
            )
            db.commit()

        base = _latest_change_id(client, token, ledger_id)
        res = client.request(
            "DELETE",
            f"/api/v1/write/ledgers/{ledger_id}/tags/{tag}",
            headers={"Authorization": f"Bearer {token}"},
            json={"base_change_id": base},
        )
        assert res.status_code == 200, res.text

        # cascade-only 补发只覆盖活跃交易;软删行不得被补发(否则 mobile 复活)
        with TS() as db:
            cascade = db.scalars(
                select(SyncChange).where(
                    SyncChange.entity_type == "transaction",
                    SyncChange.action == "upsert",
                    SyncChange.updated_by_device_id == "web-console",
                    SyncChange.entity_sync_id.in_(["tx-alive", "tx-dead"]),
                )
            ).all()
            by_sync = {c.entity_sync_id: c for c in cascade}
            assert "tx-alive" in by_sync, "active tx must get cascade change"
            assert "tx-dead" not in by_sync, (
                "soft-deleted tx must NOT be resurrected via cascade upsert"
            )
            assert not by_sync["tx-alive"].payload_json.get("tags")
            assert not by_sync["tx-alive"].payload_json.get("tagIds")

        # 活跃交易的投影剥离正常发生
        with TS() as db:
            row = db.scalar(
                select(ReadTxProjection).where(ReadTxProjection.sync_id == "tx-alive")
            )
            assert row is not None
            assert row.tags_csv is None
            assert row.tag_sync_ids_json is None or (
                json.loads(row.tag_sync_ids_json or "[]") == []
            )
    finally:
        app.dependency_overrides.clear()
