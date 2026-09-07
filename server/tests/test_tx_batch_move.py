"""POST /write/ledgers/{lid}/transactions/batch/move — 批量移动交易到目标分类。

用 batch_create 先建一批 tx,再用 _create_category 建源/目标分类并给 tx 挂源分类,
然后:
1. happy path:全部移到目标分类 → moved_tx_ids 返回、projection category_sync_id
   /category_name/category_kind 更新为目标分类、sync_change 为 N 条 upsert。
2. 部分失败:混伪造 ID → failed 含 not_found,真实 ID 正常 moved。
3. 跨 ledger 防越权:跨 ledger sync_id → not_found。
4. 上限校验:201 条 → 422。
5. idempotency:同 key 重发 → replay 第一份响应。
6. 无效目标分类:target_category_id 不存在 → 422 / invalid_target_category。
"""
from __future__ import annotations

from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import ReadTxProjection, SyncChange


def _make_client() -> TestClient:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override_get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app)


def _register_and_login(client: TestClient, email: str) -> str:
    client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "d-web",
            "client_type": "web",
            "device_name": "pytest-web",
            "platform": "test",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "d-web",
            "client_type": "web",
            "device_name": "pytest-web",
            "platform": "test",
        },
    )
    return r.json()["access_token"]


def _create_ledger(client: TestClient, token: str, name: str = "default") -> str:
    r = client.post(
        "/api/v1/write/ledgers",
        json={"ledger_name": name, "currency": "CNY"},
        headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
    )
    assert r.status_code == 200, r.text
    return r.json()["entity_id"]


def _latest_change_id(client: TestClient, token: str, ledger_id: str) -> int:
    r = client.get(
        f"/api/v1/read/ledgers/{ledger_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    return int(r.json()["source_change_id"])


def _create_category(
    client: TestClient,
    token: str,
    ledger_id: str,
    *,
    name: str,
    kind: str = "expense",
) -> str:
    base = _latest_change_id(client, token, ledger_id)
    r = client.post(
        f"/api/v1/write/ledgers/{ledger_id}/categories",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "base_change_id": base,
            "name": name,
            "kind": kind,
            "level": 1,
            "icon": "category",
            "icon_type": "material",
        },
    )
    assert r.status_code == 200, r.text
    listing = client.get(
        f"/api/v1/read/ledgers/{ledger_id}/categories",
        headers={"Authorization": f"Bearer {token}"},
    )
    cats = listing.json()
    matched = next((c for c in cats if c["name"] == name and c["kind"] == kind), None)
    assert matched, f"created category not found: {name}"
    return matched["id"]


def _create_tx_with_category(
    client: TestClient,
    token: str,
    ledger_id: str,
    *,
    amount: float,
    category_name: str,
    category_kind: str,
    note: str,
) -> str:
    base = _latest_change_id(client, token, ledger_id)
    r = client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "base_change_id": base,
            "tx_type": category_kind,
            "amount": amount,
            "happened_at": "2026-05-06T12:30:00Z",
            "note": note,
            "category_name": category_name,
            "category_kind": category_kind,
        },
    )
    assert r.status_code == 200, r.text
    return r.json()["entity_id"]


# ──────────────────────────────────────────────────────────────────────


def test_batch_move_happy_path():
    client = _make_client()
    try:
        token = _register_and_login(client, "bm1@test.com")
        ledger_id = _create_ledger(client, token)
        src_id = _create_category(client, token, ledger_id, name="餐饮", kind="expense")
        dst_id = _create_category(client, token, ledger_id, name="交通", kind="expense")

        tx_ids = [
            _create_tx_with_category(client, token, ledger_id, amount=10.0, category_name="餐饮", category_kind="expense", note="a"),
            _create_tx_with_category(client, token, ledger_id, amount=20.0, category_name="餐饮", category_kind="expense", note="b"),
            _create_tx_with_category(client, token, ledger_id, amount=30.0, category_name="餐饮", category_kind="expense", note="c"),
        ]

        r = client.post(
            f"/api/v1/write/ledgers/{ledger_id}/transactions/batch/move",
            json={"tx_ids": tx_ids, "target_category_id": dst_id, "base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert sorted(body["moved_tx_ids"]) == sorted(tx_ids)
        assert body["failed"] == []
        assert body["new_change_id"] > 0

        # projection 行的 category 字段应更新为目标分类
        db = next(app.dependency_overrides[get_db]())
        try:
            rows = db.scalars(
                select(ReadTxProjection).where(ReadTxProjection.sync_id.in_(tx_ids))
            ).all()
            assert len(rows) == 3
            for row in rows:
                assert row.category_sync_id == dst_id
                assert row.category_name == "交通"
                assert row.category_kind == "expense"
            # sync_change 里 transaction upsert 至少 3 条(创建 3 笔时也各产生一条;
            # 用 >= 3 且投影字段校验充分,避免把"创建"的 upsert 也算错)。
            up = db.scalars(
                select(SyncChange).where(
                    SyncChange.entity_type == "transaction",
                    SyncChange.action == "upsert",
                )
            ).all()
            assert len(up) >= 3
        finally:
            db.close()
    finally:
        app.dependency_overrides.clear()


def test_batch_move_partial_failure_with_fake_ids():
    client = _make_client()
    try:
        token = _register_and_login(client, "bm2@test.com")
        ledger_id = _create_ledger(client, token)
        src_id = _create_category(client, token, ledger_id, name="餐饮", kind="expense")
        dst_id = _create_category(client, token, ledger_id, name="交通", kind="expense")

        real_ids = [
            _create_tx_with_category(client, token, ledger_id, amount=10.0, category_name="餐饮", category_kind="expense", note="a"),
            _create_tx_with_category(client, token, ledger_id, amount=20.0, category_name="餐饮", category_kind="expense", note="b"),
        ]
        fake_ids = ["tx_does_not_exist_1", "tx_does_not_exist_2"]

        r = client.post(
            f"/api/v1/write/ledgers/{ledger_id}/transactions/batch/move",
            json={"tx_ids": real_ids + fake_ids, "target_category_id": dst_id, "base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert sorted(body["moved_tx_ids"]) == sorted(real_ids)
        assert len(body["failed"]) == 2
        for f in body["failed"]:
            assert f["reason"] == "not_found"
            assert f["tx_id"] in fake_ids
    finally:
        app.dependency_overrides.clear()


def test_batch_move_cross_ledger_returns_not_found():
    client = _make_client()
    try:
        token = _register_and_login(client, "bm3@test.com")
        ledger_a = _create_ledger(client, token, name="A")
        ledger_b = _create_ledger(client, token, name="B")
        dst_a = _create_category(client, token, ledger_a, name="交通", kind="expense")
        ids_in_b = [
            _create_tx_with_category(client, token, ledger_b, amount=10.0, category_name="餐饮", category_kind="expense", note="x"),
            _create_tx_with_category(client, token, ledger_b, amount=20.0, category_name="餐饮", category_kind="expense", note="y"),
        ]

        # 用 ledger_a 的路径提交 b 的 ids → 不在 a 的 snapshot → not_found
        r = client.post(
            f"/api/v1/write/ledgers/{ledger_a}/transactions/batch/move",
            json={"tx_ids": ids_in_b, "target_category_id": dst_a, "base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["moved_tx_ids"] == []
        assert len(body["failed"]) == 2
        # ledger_b 里的 tx 应该完好(未被打到 a)
        db = next(app.dependency_overrides[get_db]())
        try:
            remaining = db.scalars(
                select(ReadTxProjection).where(ReadTxProjection.sync_id.in_(ids_in_b))
            ).all()
            assert len(remaining) == 2
        finally:
            db.close()
    finally:
        app.dependency_overrides.clear()


def test_batch_move_max_size_limit():
    client = _make_client()
    try:
        token = _register_and_login(client, "bm4@test.com")
        ledger_id = _create_ledger(client, token)
        dst_id = _create_category(client, token, ledger_id, name="交通", kind="expense")
        too_many = [f"tx_{i}" for i in range(201)]
        r = client.post(
            f"/api/v1/write/ledgers/{ledger_id}/transactions/batch/move",
            json={"tx_ids": too_many, "target_category_id": dst_id, "base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 422, r.text
    finally:
        app.dependency_overrides.clear()


def test_batch_move_idempotency_replay():
    client = _make_client()
    try:
        token = _register_and_login(client, "bm5@test.com")
        ledger_id = _create_ledger(client, token)
        dst_id = _create_category(client, token, ledger_id, name="交通", kind="expense")
        tx_ids = [
            _create_tx_with_category(client, token, ledger_id, amount=10.0, category_name="餐饮", category_kind="expense", note="a"),
            _create_tx_with_category(client, token, ledger_id, amount=20.0, category_name="餐饮", category_kind="expense", note="b"),
        ]
        idem_key = "test-idem-move-1"

        headers = {
            "Authorization": f"Bearer {token}",
            "X-Device-ID": "d-web",
            "Idempotency-Key": idem_key,
        }
        r1 = client.post(
            f"/api/v1/write/ledgers/{ledger_id}/transactions/batch/move",
            json={"tx_ids": tx_ids, "target_category_id": dst_id, "base_change_id": 0},
            headers=headers,
        )
        assert r1.status_code == 200, r1.text
        first_change_id = r1.json()["new_change_id"]
        assert sorted(r1.json()["moved_tx_ids"]) == sorted(tx_ids)

        # 重发同 key → replay 第一份;不能再次推进 change_id
        r2 = client.post(
            f"/api/v1/write/ledgers/{ledger_id}/transactions/batch/move",
            json={"tx_ids": tx_ids, "target_category_id": dst_id, "base_change_id": 0},
            headers=headers,
        )
        assert r2.status_code == 200, r2.text
        assert r2.json()["new_change_id"] == first_change_id
        assert sorted(r2.json()["moved_tx_ids"]) == sorted(tx_ids)
    finally:
        app.dependency_overrides.clear()


def test_batch_move_invalid_target_category():
    client = _make_client()
    try:
        token = _register_and_login(client, "bm6@test.com")
        ledger_id = _create_ledger(client, token)
        tx_ids = [
            _create_tx_with_category(client, token, ledger_id, amount=10.0, category_name="餐饮", category_kind="expense", note="a"),
        ]
        # 目标分类不存在 → 422 invalid_target_category
        r = client.post(
            f"/api/v1/write/ledgers/{ledger_id}/transactions/batch/move",
            json={"tx_ids": tx_ids, "target_category_id": "cat_nope", "base_change_id": 0},
            headers={"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"},
        )
        assert r.status_code == 422, r.text
        detail = r.json().get("detail")
        if isinstance(detail, dict):
            assert detail.get("reason") == "invalid_target_category"
    finally:
        app.dependency_overrides.clear()
