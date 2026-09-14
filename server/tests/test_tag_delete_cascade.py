"""删除标签的自动剥离(2026-09 行为变更):

旧:tag 有关联交易 → web 删 tag 直接 400 "tag has N linked transactions"。
新:与 app 端行为对齐 —— 确认删除后自动把 tag 从所有关联交易的
tags/tagIds 里抽走(交易本身保留),投影走 detach_cascade_tag,受影响
tx 以 cascade-only SyncChange 定向补发给 mobile。

覆盖:
  - web DELETE 快路径:现代数据(tagIds)+ 多 tag 行 + legacy 行(仅名字)
  - mobile push tag:delete:投影同样剥离(push 不带 tx 变更,靠这里兜住)
  - 删不存在的 tag → 404(回归)
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import ReadTxProjection, SyncChange, UserTagProjection


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


def _register(client: TestClient, email: str, client_type: str = "app") -> dict:
    res = client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "123456",
            "client_type": client_type,
            "device_name": f"pytest-{client_type}",
            "platform": client_type,
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


def _seed_ledger(client: TestClient, token: str, device_id: str, ledger_id: str) -> None:
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


def _latest_change_id(client: TestClient, token: str, ledger_id: str) -> int:
    res = client.get(
        f"/api/v1/read/ledgers/{ledger_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200
    return int(res.json()["source_change_id"])


def _create_tag(
    client: TestClient, token: str, ledger_id: str, *, name: str
) -> str:
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


def _push_tx(
    client: TestClient,
    app_token: str,
    device: str,
    ledger_id: str,
    *,
    sync_id: str,
    tags_csv: str | None = None,
    tag_ids: list[str] | None = None,
) -> None:
    """mobile 风格 push 一笔交易;tags(逗号名串)/tagIds(sync id 列表)可选。"""
    now = (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat()
    payload: dict = {
        "syncId": sync_id,
        "type": "expense",
        "amount": 10.0,
        "happenedAt": now,
    }
    if tags_csv is not None:
        payload["tags"] = tags_csv
    if tag_ids is not None:
        payload["tagIds"] = tag_ids
    res = client.post(
        "/api/v1/sync/push",
        headers={"Authorization": f"Bearer {app_token}"},
        json={
            "device_id": device,
            "changes": [
                {
                    "ledger_id": ledger_id,
                    "entity_type": "transaction",
                    "entity_sync_id": sync_id,
                    "action": "upsert",
                    "payload": payload,
                    "updated_at": now,
                }
            ],
        },
    )
    assert res.status_code == 200, res.text


def _delete_tag(
    client: TestClient, token: str, ledger_id: str, tag_id: str
) -> tuple[int, str]:
    base = _latest_change_id(client, token, ledger_id)
    res = client.request(
        "DELETE",
        f"/api/v1/write/ledgers/{ledger_id}/tags/{tag_id}",
        headers={"Authorization": f"Bearer {token}"},
        json={"base_change_id": base},
    )
    return res.status_code, res.text


def _tx_row(TS: sessionmaker, sync_id: str) -> ReadTxProjection:
    with TS() as db:
        row = db.scalar(
            select(ReadTxProjection).where(ReadTxProjection.sync_id == sync_id)
        )
        assert row is not None, f"tx row missing: {sync_id}"
        return row


def test_web_delete_tag_with_linked_tx_auto_detaches() -> None:
    """web 删有关联交易的 tag:200 + 投影剥离 + cascade-only tx 事件补发"""
    client, TS = _make_client()
    try:
        owner = _register(client, "tag-del-web@example.com")
        app_token, device = owner["access_token"], owner["device_id"]
        ledger_id = "L_TAG_WEB"
        _seed_ledger(client, app_token, device, ledger_id)

        web = _login_web(client, "tag-del-web@example.com")
        token = web["access_token"]

        tag_a = _create_tag(client, token, ledger_id, name="标签A")
        tag_b = _create_tag(client, token, ledger_id, name="标签B")

        # tx1: 只有标签A;tx2: A+B;tx3: legacy 仅名字无 id;tx4: 只有 B(对照)
        _push_tx(
            client, app_token, device, ledger_id,
            sync_id="tx1", tags_csv="标签A", tag_ids=[tag_a],
        )
        _push_tx(
            client, app_token, device, ledger_id,
            sync_id="tx2", tags_csv="标签A,标签B", tag_ids=[tag_a, tag_b],
        )
        _push_tx(client, app_token, device, ledger_id, sync_id="tx3", tags_csv="标签A")
        _push_tx(
            client, app_token, device, ledger_id,
            sync_id="tx4", tags_csv="标签B", tag_ids=[tag_b],
        )

        status, text = _delete_tag(client, token, ledger_id, tag_a)
        assert status == 200, f"expected delete success, got {status}: {text}"

        # 投影剥离:两维度(tags_csv + tag_sync_ids_json)都抽干净
        tx1 = _tx_row(TS, "tx1")
        assert tx1.tags_csv is None and tx1.tag_sync_ids_json is None
        tx2 = _tx_row(TS, "tx2")
        assert tx2.tags_csv == "标签B"
        assert json.loads(tx2.tag_sync_ids_json or "[]") == [tag_b]
        tx3 = _tx_row(TS, "tx3")
        assert tx3.tags_csv is None and tx3.tag_sync_ids_json is None
        tx4 = _tx_row(TS, "tx4")
        assert tx4.tags_csv == "标签B" and tx4.tag_sync_ids_json

        # tag 投影行删除
        with TS() as db:
            remaining = db.scalars(
                select(UserTagProjection.sync_id).where(
                    UserTagProjection.user_id == owner["user"]["id"]
                )
            ).all()
            assert tag_a not in remaining
            assert tag_b in remaining

        # cascade-only tx SyncChange 补发:tx1/tx2/tx3 有(剥离后状态),tx4 无。
        # web DELETE 不带 X-Device-ID 时 device 固定为 web-console,以此与
        # mobile push 原始入账的 transaction change 区分开。
        with TS() as db:
            tx_changes = db.scalars(
                select(SyncChange).where(
                    SyncChange.entity_type == "transaction",
                    SyncChange.action == "upsert",
                    SyncChange.updated_by_device_id == "web-console",
                    SyncChange.entity_sync_id.in_(["tx1", "tx2", "tx3", "tx4"]),
                )
            ).all()
            by_sync = {c.entity_sync_id: c for c in tx_changes}
            for sid in ("tx1", "tx2", "tx3"):
                assert sid in by_sync, f"missing cascade change for {sid}"
                payload = by_sync[sid].payload_json
                if sid == "tx2":
                    assert payload.get("tags") == "标签B"
                    assert payload.get("tagIds") == [tag_b]
                else:
                    assert not payload.get("tags"), payload
                    assert not payload.get("tagIds"), payload
            assert "tx4" not in by_sync, "untouched tx must not get a cascade change"

            # tag 自身的 user-global delete 事件也在
            tag_deletes = db.scalars(
                select(SyncChange).where(
                    SyncChange.scope == "user",
                    SyncChange.entity_type == "tag",
                    SyncChange.entity_sync_id == tag_a,
                    SyncChange.action == "delete",
                )
            ).all()
            assert len(tag_deletes) == 1
    finally:
        app.dependency_overrides.clear()


def test_mobile_push_tag_delete_detaches_projection() -> None:
    """App push tag:delete(不带 tx 变更)→ 服务端投影同样剥离引用"""
    client, TS = _make_client()
    try:
        owner = _register(client, "tag-del-push@example.com")
        app_token, device = owner["access_token"], owner["device_id"]
        ledger_id = "L_TAG_PUSH"
        _seed_ledger(client, app_token, device, ledger_id)

        web = _login_web(client, "tag-del-push@example.com")
        token = web["access_token"]
        tag_a = _create_tag(client, token, ledger_id, name="咖啡")

        _push_tx(
            client, app_token, device, ledger_id,
            sync_id="mtx1", tags_csv="咖啡", tag_ids=[tag_a],
        )

        now = (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat()
        res = client.post(
            "/api/v1/sync/push",
            headers={"Authorization": f"Bearer {app_token}"},
            json={
                "device_id": device,
                "changes": [
                    {
                        "entity_type": "tag",
                        "entity_sync_id": tag_a,
                        "action": "delete",
                        "payload": {},
                        "updated_at": now,
                    }
                ],
            },
        )
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 1, res.text

        tx = _tx_row(TS, "mtx1")
        assert tx.tags_csv is None and tx.tag_sync_ids_json is None
        with TS() as db:
            remaining = db.scalars(
                select(UserTagProjection.sync_id).where(
                    UserTagProjection.user_id == owner["user"]["id"]
                )
            ).all()
            assert tag_a not in remaining
    finally:
        app.dependency_overrides.clear()


def test_web_delete_missing_tag_404() -> None:
    """删不存在的 tag → 404(全量路径兜底回归)"""
    client, _TS = _make_client()
    try:
        owner = _register(client, "tag-del-404@example.com")
        app_token, device = owner["access_token"], owner["device_id"]
        ledger_id = "L_TAG_404"
        _seed_ledger(client, app_token, device, ledger_id)

        web = _login_web(client, "tag-del-404@example.com")
        token = web["access_token"]

        status, _text = _delete_tag(client, token, ledger_id, "tag-nonexistent")
        assert status == 404, f"expected 404, got {status}: {_text}"
    finally:
        app.dependency_overrides.clear()
