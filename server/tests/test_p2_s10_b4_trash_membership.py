"""S10:回收站按「可访问账本集合」过滤 + PK 消歧;B4:恢复保留标签/附件。

S10:
- Editor 删除共享账本交易 → 自己的回收站可见、可恢复(旧行为按
  user_id==caller 过滤,Editor 永远看不到);
- 跨账本同 sync_id:列表两条都带 ledger_id;restore 不带 ledger_id → 409
  (不再静默操作错账本);带 ledger_id → 按 PK 收敛;
- 被移除成员:列表与操作均不可见。

B4:
- 删除 → 恢复:重发的 upsert SyncChange payload 完整携带 tags/tagIds/
  attachments(投影行软删期间保留),移动端拉到后可重建完整交易。
"""
from __future__ import annotations

import json

from fastapi.testclient import TestClient
from sqlalchemy import select

from src.database import get_db
from src.main import app
from src.models import Ledger, LedgerMember, ReadTxProjection, SyncChange, User
from tests.test_tx_batch_delete import (
    _create_ledger,
    _make_client,
    _register_and_login,
    _seed_txs,
)


def _auth(token: str, device: str = "d-web") -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": device}


def _delete_tx(client: TestClient, token: str, ledger_ext: str, sync_id: str):
    return client.request(
        "DELETE",
        f"/api/v1/write/ledgers/{ledger_ext}/transactions/{sync_id}",
        json={"base_change_id": 0},
        headers=_auth(token),
    )


def _session():
    return next(app.dependency_overrides[get_db]())


def _add_editor(db, email: str, ledger: Ledger, owner: User) -> User:
    editor = db.scalar(select(User).where(User.email == email))
    db.add(LedgerMember(
        ledger_id=ledger.id, user_id=editor.id, role="editor", invited_by=owner.id,
    ))
    db.commit()
    return editor


def test_s10_editor_sees_and_restores_shared_trash():
    client = _make_client()
    try:
        owner_token = _register_and_login(client, "s10-owner@test.com")
        editor_token = _register_and_login(client, "s10-editor@test.com")
        ledger_ext = _create_ledger(client, owner_token, name="fam")
        tx = _seed_txs(client, owner_token, ledger_ext, n=1)[0]

        db = _session()
        owner = db.scalar(select(User).where(User.email == "s10-owner@test.com"))
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        _add_editor(db, "s10-editor@test.com", ledger, owner)

        # Editor 删除共享账本交易(投影行 user_id 是 owner)
        r = _delete_tx(client, editor_token, ledger_ext, tx)
        assert r.status_code == 200, r.text

        # Editor 的回收站列表可见(S10 核心:旧实现查不到)
        r = client.get("/api/v1/read/workspace/trash", headers=_auth(editor_token))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["total"] == 1
        assert body["items"][0]["sync_id"] == tx
        assert body["items"][0]["ledger_id"] == ledger_ext

        # Editor 可恢复
        r = client.post(
            f"/api/v1/read/workspace/trash/{tx}/restore", headers=_auth(editor_token)
        )
        assert r.status_code == 200, r.text
        assert r.json()["ok"] is True
        assert r.json()["ledger_id"] == ledger_ext

        row = db.get(ReadTxProjection, (ledger.id, tx))
        assert row.deleted_at is None
    finally:
        app.dependency_overrides.clear()


def test_s10_cross_ledger_same_sync_id_ambiguous():
    client = _make_client()
    try:
        token = _register_and_login(client, "s10b@test.com")
        lg1 = _create_ledger(client, token, name="one")
        lg2 = _create_ledger(client, token, name="two")
        tx1 = _seed_txs(client, token, lg1, n=1)[0]
        _ = _seed_txs(client, token, lg2, n=1)[0]

        # 强制两账本同 sync_id(模拟 PK 语义:同 id 不同账本)
        db = _session()
        l2 = db.scalar(select(Ledger).where(Ledger.external_id == lg2))
        db.execute(
            ReadTxProjection.__table__.update()
            .where(ReadTxProjection.ledger_id == l2.id)
            .values(sync_id=tx1)
        )
        db.commit()

        _delete_tx(client, token, lg1, tx1)
        _delete_tx(client, token, lg2, tx1)

        # 列表两条,各带 ledger_id
        r = client.get("/api/v1/read/workspace/trash", headers=_auth(token))
        assert r.status_code == 200
        items = r.json()["items"]
        assert {i["ledger_id"] for i in items} == {lg1, lg2}

        # restore 不带 ledger_id → 409(旧行为会静默恢复不确定的一行)。
        # 全局异常 handler 会把 dict detail 摊平到顶层(error_code/ledger_ids)。
        r = client.post(f"/api/v1/read/workspace/trash/{tx1}/restore", headers=_auth(token))
        assert r.status_code == 409, r.text
        assert r.json()["error_code"] == "TRASH_TX_AMBIGUOUS"
        assert set(r.json()["ledger_ids"]) == {lg1, lg2}

        # 带 ledger_id → 按 PK 收敛恢复
        r = client.post(
            f"/api/v1/read/workspace/trash/{tx1}/restore",
            params={"ledger_id": lg2},
            headers=_auth(token),
        )
        assert r.status_code == 200, r.text
        assert r.json()["ledger_id"] == lg2

        db2 = _session()
        l1 = db2.scalar(select(Ledger).where(Ledger.external_id == lg1))
        row1 = db2.get(ReadTxProjection, (l1.id, tx1))
        row2 = db2.get(ReadTxProjection, (l2.id, tx1))
        assert row1.deleted_at is not None  # lg1 的还在回收站
        assert row2.deleted_at is None      # lg2 的被恢复
    finally:
        app.dependency_overrides.clear()


def test_s10_removed_member_cannot_see_trash():
    client = _make_client()
    try:
        owner_token = _register_and_login(client, "s10c-owner@test.com")
        editor_token = _register_and_login(client, "s10c-editor@test.com")
        ledger_ext = _create_ledger(client, owner_token, name="fam")
        tx = _seed_txs(client, owner_token, ledger_ext, n=1)[0]

        db = _session()
        owner = db.scalar(select(User).where(User.email == "s10c-owner@test.com"))
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        _add_editor(db, "s10c-editor@test.com", ledger, owner)

        _delete_tx(client, editor_token, ledger_ext, tx)

        # 移除 editor
        db.execute(
            LedgerMember.__table__.delete().where(
                LedgerMember.ledger_id == ledger.id,
                LedgerMember.user_id != owner.id,
            )
        )
        db.commit()

        r = client.get("/api/v1/read/workspace/trash", headers=_auth(editor_token))
        assert r.status_code == 200
        assert r.json()["total"] == 0

        r = client.post(
            f"/api/v1/read/workspace/trash/{tx}/restore", headers=_auth(editor_token)
        )
        assert r.status_code == 404
    finally:
        app.dependency_overrides.clear()


# ───────────────────────── B4 ─────────────────────────


def test_b4_restore_preserves_tags_and_attachments():
    """删除→恢复:重发 upsert payload 携带 tags/tagIds/attachments。"""
    client = _make_client()
    try:
        token = _register_and_login(client, "b4@test.com")
        ledger_ext = _create_ledger(client, token, name="b4")

        # 带 tags 的批量建 tx(batch 会补建 tag 实体并回填 tagIds)
        r = client.post(
            f"/api/v1/write/ledgers/{ledger_ext}/transactions/batch",
            json={
                "base_change_id": 0,
                "transactions": [{
                    "tx_type": "expense",
                    "amount": 42.0,
                    "happened_at": "2026-05-06T12:30:00Z",
                    "note": "b4",
                    "tags": ["咖啡", "工作"],
                }],
                "auto_ai_tag": False,
                "locale": "zh",
            },
            headers=_auth(token),
        )
        assert r.status_code == 200, r.text
        tx = r.json()["created_sync_ids"][0]

        # 投影行直接补 attachments(等价 web 贴图记账落库后的形态)
        db = _session()
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        row = db.get(ReadTxProjection, (ledger.id, tx))
        assert row is not None
        assert row.tags_csv and "咖啡" in row.tags_csv
        assert row.tag_sync_ids_json
        row.attachments_json = json.dumps([{
            "cloudFileId": "att-b4", "fileName": "shot.jpg",
            "mimeType": "image/jpeg", "sha256": "0" * 64, "sizeBytes": 5,
        }])
        db.commit()

        # 删除(软删,行与 tags/attachments 保留)
        r = _delete_tx(client, token, ledger_ext, tx)
        assert r.status_code == 200, r.text

        # 恢复
        r = client.post(f"/api/v1/read/workspace/trash/{tx}/restore", headers=_auth(token))
        assert r.status_code == 200, r.text
        assert r.json()["ok"] is True
        new_change_id = r.json()["new_change_id"]

        # B4 核心:重发的 upsert payload 完整携带标签与附件
        change = db.get(SyncChange, new_change_id)
        assert change is not None
        payload = change.payload_json
        assert change.action == "upsert"
        assert payload.get("tags") and "咖啡" in payload["tags"]
        assert isinstance(payload.get("tagIds"), list) and len(payload["tagIds"]) == 2
        atts = payload.get("attachments")
        assert isinstance(atts, list) and atts[0]["cloudFileId"] == "att-b4"

        # 投影行恢复后字段完整
        db2 = _session()
        row2 = db2.get(ReadTxProjection, (ledger.id, tx))
        assert row2.deleted_at is None
        assert "咖啡" in (row2.tags_csv or "")
        assert "att-b4" in (row2.attachments_json or "")
    finally:
        app.dependency_overrides.clear()
