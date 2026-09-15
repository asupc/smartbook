"""共享账本 user-global 作用域错配回归测试(P0-1 + P0-2,2026-09)。

锁定的契约(SYNC_ARCHITECTURE §4.4 / §4.7):
  - user-global 实体(account/category/tag)对 read_tx_projection 的 rename
    cascade / 删除前引用校验 / cascade 事件补发,按 **sync_id 稳定 FK** 匹配,
    不按 `user_id == 操作者` —— 共享账本 tx 投影行的 user_id 是 ledger owner,
    Editor 改名/删除必须命中 owner 名下的行;
  - push 路径 user-global rename 后要补发 cascade-only tx SyncChange,
    owner 端 pull 可见(owner 拉不到 Editor 的 scope=user 事件);
  - 仍被共享账本交易引用的账户,删除必须被拒绝(savepoint 隔离 → failed,
    不留悬挂 account_sync_id)。

SQLite 下 advisory lock 是 no-op,并发语义按顺序模拟交错(契约同
test_sync_concurrency.py 的说明)。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import (
    AttachmentFile,
    Ledger,
    ReadTxProjection,
    SyncChange,
    UserAccountProjection,
    UserCategoryProjection,
    UserTagProjection,
)


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


def _register(client, email, client_type, device):
    r = client.post("/api/v1/auth/register", json={
        "email": email,
        "password": "Pa$$word1!",
        "device_id": device,
        "client_type": client_type,
        "device_name": f"pytest-{device}",
        "platform": "test",
    })
    assert r.status_code == 200, r.text
    return r.json()["access_token"], r.json()["user"]["id"]


def _push(client, hdr, device, changes):
    r = client.post(
        "/api/v1/sync/push",
        headers=hdr,
        json={"device_id": device, "changes": changes},
    )
    assert r.status_code == 200, r.text
    return r.json()


def _change(entity_type, sync_id, payload, *, action="upsert",
            ledger_id=None, updated_at=None):
    body = {
        "entity_type": entity_type,
        "entity_sync_id": sync_id,
        "action": action,
        "updated_at": updated_at or _iso(),
        "payload": payload,
    }
    if ledger_id is not None:
        body["ledger_id"] = ledger_id
    return body


def _setup_shared_ledger(client):
    """owner(web)+ editor(app)双用户 + 已接受的共享账本,返回
    (owner_token, owner_id, editor_token, editor_id, ledger_external_id)。"""
    owner_token, owner_id = _register(client, "p01-owner@t.com", "web", "d-owner")
    editor_token, editor_id = _register(client, "p01-editor@t.com", "app", "d-editor")

    r = client.post(
        "/api/v1/write/ledgers",
        json={"ledger_id": "shared-p01", "ledger_name": "Family", "currency": "CNY"},
        headers={"Authorization": f"Bearer {owner_token}", "X-Device-ID": "d-owner"},
    )
    assert r.status_code == 200, r.text

    r = client.post(
        "/api/v1/ledgers/shared-p01/invites",
        json={"role": "editor", "expires_in_hours": 24},
        headers={"Authorization": f"Bearer {owner_token}", "X-Device-ID": "d-owner"},
    )
    assert r.status_code == 201, r.text
    code = r.json()["code"]
    r = client.post(
        f"/api/v1/invites/{code}/accept",
        headers={"Authorization": f"Bearer {editor_token}", "X-Device-ID": "d-editor"},
    )
    assert r.status_code == 200, r.text
    return owner_token, owner_id, editor_token, editor_id, "shared-p01"


def test_editor_account_rename_cascades_owner_projection_and_emits_cascade_change():
    """① Editor push 引用自己账户的交易 → Editor 改名该账户 →
    共享账本(owner 名下)投影 denorm 已刷新,cascade SyncChange 已补发
    (owner 端 pull 可见)。"""
    client, TS = _make_client()
    try:
        owner_token, owner_id, editor_token, editor_id, ledger_x = _setup_shared_ledger(client)
        editor_hdr = {"Authorization": f"Bearer {editor_token}"}

        base = datetime.now(timezone.utc)
        # Editor 的账户 + 引用该账户的交易(推进共享账本 → 投影行 user_id=owner)
        _push(client, editor_hdr, "d-editor", [
            _change("account", "acc-ed",
                    {"syncId": "acc-ed", "name": "OldName", "type": "cash", "currency": "CNY"},
                    updated_at=_iso(base)),
        ])
        _push(client, editor_hdr, "d-editor", [
            _change("transaction", "tx-1", {
                "syncId": "tx-1", "type": "expense", "amount": 10,
                "happenedAt": _iso(base),
                "accountId": "acc-ed", "accountName": "OldName",
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])

        with TS() as db:
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_x))
            row = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.ledger_id == ledger.id,
                ReadTxProjection.sync_id == "tx-1",
            ))
            # 前置:共享账本 tx 投影行归 owner(Editor push 也一样)
            assert row.user_id == owner_id
            assert row.account_name == "OldName"

        # Editor 改名自己的账户(user-scope push)
        _push(client, editor_hdr, "d-editor", [
            _change("account", "acc-ed",
                    {"syncId": "acc-ed", "name": "NewName", "type": "cash", "currency": "CNY"},
                    updated_at=_iso(base + timedelta(seconds=5))),
        ])

        with TS() as db:
            # 谓词命中:owner 名下投影 denorm 已刷新(旧谓词 user_id=editor 会 miss)
            row = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.ledger_id == ledger.id,
                ReadTxProjection.sync_id == "tx-1",
            ))
            assert row.account_name == "NewName", (
                f"cascade missed owner-owned row: {row.account_name!r}"
            )
            # cascade-only SyncChange 已补发(ledger-scope,owner 可 pull)
            cascade_changes = db.scalars(select(SyncChange).where(
                SyncChange.entity_type == "transaction",
                SyncChange.entity_sync_id == "tx-1",
                SyncChange.scope == "ledger",
                SyncChange.ledger_id == ledger.id,
            )).all()
            assert len(cascade_changes) >= 2, (
                f"cascade SyncChange not supplemented: {len(cascade_changes)}"
            )
            latest = max(cascade_changes, key=lambda c: c.change_id)
            assert latest.payload_json["accountName"] == "NewName"
            assert latest.user_id == owner_id          # ledger-scope 行归 owner
            assert latest.updated_by_user_id == editor_id  # 真实操作者 = Editor

        # owner 端 pull 可见(用 owner 的设备拉,Editor 推的不会被 device 过滤)
        r = client.get(
            "/api/v1/sync/pull?since=0&device_id=d-owner",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
        assert r.status_code == 200, r.text
        pulled_tx_changes = [
            c for c in r.json()["changes"]
            if c["entity_type"] == "transaction" and c["entity_sync_id"] == "tx-1"
        ]
        assert any(c.get("payload", {}).get("accountName") == "NewName"
                   for c in pulled_tx_changes), pulled_tx_changes
    finally:
        app.dependency_overrides.clear()


def test_editor_account_delete_rejected_while_shared_ledger_tx_references_it():
    """② Editor 删除仍被共享账本交易引用的账户 → 拒绝而非放行
    (旧谓词按 user_id=editor 过滤会误判无引用,留下 owner 名下悬挂 FK)。"""
    client, TS = _make_client()
    try:
        _, _, editor_token, _, ledger_x = _setup_shared_ledger(client)
        editor_hdr = {"Authorization": f"Bearer {editor_token}"}
        base = datetime.now(timezone.utc)

        _push(client, editor_hdr, "d-editor", [
            _change("account", "acc-del",
                    {"syncId": "acc-del", "name": "ToDelete", "type": "cash", "currency": "CNY"},
                    updated_at=_iso(base)),
            _change("transaction", "tx-ref", {
                "syncId": "tx-ref", "type": "expense", "amount": 5,
                "happenedAt": _iso(base),
                "accountId": "acc-del", "accountName": "ToDelete",
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])

        resp = _push(client, editor_hdr, "d-editor", [
            _change("account", "acc-del", {}, action="delete",
                    updated_at=_iso(base + timedelta(seconds=5))),
        ])
        # 拒绝 = savepoint 隔离,failed_samples 带 apply_failed,不是 500
        assert resp["failed_count"] == 1, resp
        assert resp["failed_samples"][0]["reason"] == "apply_failed", resp

        with TS() as db:
            # 投影行保留(editor 自己的 user_account_projection 行未被删)
            assert db.scalar(select(UserAccountProjection).where(
                UserAccountProjection.sync_id == "acc-del"
            )) is not None
            # owner 名下的引用交易也原样保留
            tx = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.sync_id == "tx-ref"
            ))
            assert tx is not None and tx.account_sync_id == "acc-del"

        # 对照:删除引用交易后,账户删除成功(tx 软删不再算活跃引用)
        _push(client, editor_hdr, "d-editor", [
            _change("transaction", "tx-ref", {}, action="delete",
                    ledger_id=ledger_x, updated_at=_iso(base + timedelta(seconds=10))),
            _change("account", "acc-del", {}, action="delete",
                    updated_at=_iso(base + timedelta(seconds=11))),
        ])
        with TS() as db:
            assert db.scalar(select(UserAccountProjection).where(
                UserAccountProjection.sync_id == "acc-del"
            )) is None
    finally:
        app.dependency_overrides.clear()


def test_interleaved_user_rename_and_tx_upsert_no_drift():
    """③ 交错场景:user-scope rename 与 ledger-scope tx upsert 交错 push,
    投影无漂移(级联按 sync_id 命中 owner 行;后续 rename 幂等纠正旧名
    残留)。SQLite 下锁为 no-op,按顺序模拟交错,重点断言谓词命中。"""

    client, TS = _make_client()
    try:
        _, owner_id, editor_token, _, ledger_x = _setup_shared_ledger(client)
        editor_hdr = {"Authorization": f"Bearer {editor_token}"}
        base = datetime.now(timezone.utc)

        # 交错第一批:tx-1(upsert,带旧名 denorm)
        _push(client, editor_hdr, "d-editor", [
            _change("account", "acc-x",
                    {"syncId": "acc-x", "name": "A1", "type": "cash", "currency": "CNY"},
                    updated_at=_iso(base)),
            _change("transaction", "tx-1", {
                "syncId": "tx-1", "type": "expense", "amount": 1,
                "happenedAt": _iso(base),
                "accountId": "acc-x", "accountName": "A1",
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])

        # 交错:rename → A2(级联在 tx upsert 之后跑,应命中 tx-1)
        _push(client, editor_hdr, "d-editor", [
            _change("account", "acc-x",
                    {"syncId": "acc-x", "name": "A2", "type": "cash", "currency": "CNY"},
                    updated_at=_iso(base + timedelta(seconds=1))),
        ])

        # 交错:tx-2 携带陈旧 denorm "A1" 落进来(模拟与 rename 并发的写)
        _push(client, editor_hdr, "d-editor", [
            _change("transaction", "tx-2", {
                "syncId": "tx-2", "type": "expense", "amount": 2,
                "happenedAt": _iso(base + timedelta(seconds=2)),
                "accountId": "acc-x", "accountName": "A1",
            }, ledger_id=ledger_x, updated_at=_iso(base + timedelta(seconds=2))),
        ])

        # 再一次 rename → A3:级联是幂等的 sync_id 纠正,把 tx-2 的陈旧名一起拉齐
        _push(client, editor_hdr, "d-editor", [
            _change("account", "acc-x",
                    {"syncId": "acc-x", "name": "A3", "type": "cash", "currency": "CNY"},
                    updated_at=_iso(base + timedelta(seconds=3))),
        ])

        with TS() as db:
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_x))
            for sid in ("tx-1", "tx-2"):
                row = db.scalar(select(ReadTxProjection).where(
                    ReadTxProjection.ledger_id == ledger.id,
                    ReadTxProjection.sync_id == sid,
                ))
                assert row is not None
                assert row.user_id == owner_id
                assert row.account_name == "A3", (
                    f"{sid} drifted: {row.account_name!r}"
                )
            # 两轮 rename 都补发了 cascade-only 事件(owner pull 可追平)
            cascades = db.scalars(select(SyncChange).where(
                SyncChange.entity_type == "transaction",
                SyncChange.entity_sync_id.in_(["tx-1", "tx-2"]),
                SyncChange.scope == "ledger",
            )).all()
            assert len(cascades) >= 3, [c.change_id for c in cascades]
    finally:
        app.dependency_overrides.clear()


def test_editor_category_and_tag_rename_cascade_owner_rows():
    """category / tag 的同款谓词:Editor 改名后 owner 名下投影刷新 +
    cascade-only SyncChange 补发(tag 走 tag_sync_ids_json by-id 分支)。"""

    client, TS = _make_client()
    try:
        _, owner_id, editor_token, _, ledger_x = _setup_shared_ledger(client)
        editor_hdr = {"Authorization": f"Bearer {editor_token}"}
        base = datetime.now(timezone.utc)

        _push(client, editor_hdr, "d-editor", [
            _change("category", "cat-ed",
                    {"syncId": "cat-ed", "name": "OldCat", "kind": "expense"},
                    updated_at=_iso(base)),
            _change("tag", "tag-ed",
                    {"syncId": "tag-ed", "name": "oldtag", "color": "#000"},
                    updated_at=_iso(base)),
            _change("transaction", "tx-ct", {
                "syncId": "tx-ct", "type": "expense", "amount": 3,
                "happenedAt": _iso(base),
                "categoryId": "cat-ed", "categoryName": "OldCat", "categoryKind": "expense",
                "tags": "oldtag", "tagIds": ["tag-ed"],
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])

        _push(client, editor_hdr, "d-editor", [
            _change("category", "cat-ed",
                    {"syncId": "cat-ed", "name": "NewCat", "kind": "expense"},
                    updated_at=_iso(base + timedelta(seconds=1))),
            _change("tag", "tag-ed",
                    {"syncId": "tag-ed", "name": "newtag", "color": "#000"},
                    updated_at=_iso(base + timedelta(seconds=2))),
        ])

        with TS() as db:
            row = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.sync_id == "tx-ct"
            ))
            assert row.user_id == owner_id
            assert row.category_name == "NewCat", row.category_name
            assert row.tags_csv == "newtag", row.tags_csv
            # 编辑者自己的 user-global 投影行也已更新
            editor_uid = db.scalar(select(UserTagProjection.user_id).where(
                UserTagProjection.sync_id == "tag-ed"
            ))
            assert db.scalar(select(UserCategoryProjection.name).where(
                UserCategoryProjection.user_id == editor_uid,
                UserCategoryProjection.sync_id == "cat-ed",
            )) == "NewCat"
            # cascade-only 补发覆盖两种实体
            cascades = db.scalars(select(SyncChange).where(
                SyncChange.entity_type == "transaction",
                SyncChange.entity_sync_id == "tx-ct",
                SyncChange.scope == "ledger",
            )).all()
            payloads = [c.payload_json for c in cascades]
            assert any(p.get("categoryName") == "NewCat" for p in payloads), payloads
            assert any(p.get("tags") == "newtag" for p in payloads), payloads
    finally:
        app.dependency_overrides.clear()


def test_editor_triggered_gc_keeps_file_referenced_by_owner_projection_row(tmp_path):
    """附件 GC 同模式漏扫(P0-1 问题陈述第 3 点):Editor 触发的 GC(user 域)
    不能因 `user_id == 操作者` 的引用扫描漏掉 owner 名下的投影行而误删活附件。
    引用检查按 fileId 全局精确匹配;真孤儿仍照常清理;单人场景不变。"""
    client, TS = _make_client()
    try:
        _, owner_id, editor_token, editor_id, ledger_x = _setup_shared_ledger(client)
        editor_hdr = {"Authorization": f"Bearer {editor_token}"}
        base = datetime.now(timezone.utc)

        # Editor 名下两个附件(共享池:图标 fileId 也可能被 tx 引用)
        def _make_att(file_id):
            p = tmp_path / f"{file_id}.bin"
            p.write_bytes(b"dummy")
            return AttachmentFile(
                id=file_id,
                ledger_id=None,          # category_icon kind,不绑账本
                user_id=editor_id,
                sha256=file_id,
                size_bytes=5,
                mime_type="image/png",
                file_name=f"{file_id}.png",
                storage_path=str(p),
                attachment_kind="category_icon",
            ), p

        with TS() as db:
            att_shared, path_shared = _make_att("f-shared-x")
            att_orphan, path_orphan = _make_att("f-orphan-z")
            db.add_all([att_shared, att_orphan])
            db.commit()

        # 两个分类各挂一个图标;f-shared-x 同时被 Editor push 进共享账本的
        # 交易引用(投影行 user_id = owner)
        _push(client, editor_hdr, "d-editor", [
            _change("category", "cat-ic",
                    {"syncId": "cat-ic", "name": "IconCat", "kind": "expense",
                     "iconCloudFileId": "f-shared-x"},
                    updated_at=_iso(base)),
            _change("category", "cat-z",
                    {"syncId": "cat-z", "name": "ZCat", "kind": "expense",
                     "iconCloudFileId": "f-orphan-z"},
                    updated_at=_iso(base)),
            _change("transaction", "tx-att", {
                "syncId": "tx-att", "type": "expense", "amount": 7,
                "happenedAt": _iso(base),
                "attachments": [{"fileName": "a.png", "cloudFileId": "f-shared-x"}],
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])
        with TS() as db:
            tx = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.sync_id == "tx-att"
            ))
            assert tx.user_id == owner_id  # 前置:引用行确实在 owner 名下

        # Editor 换掉 cat-ic 的图标 → 触发 GC(user=editor,候选 f-shared-x)。
        # 旧谓词(user_id==editor 扫描)看不见 owner 名下的 tx 引用行 → 误删;
        # 全局 fileId 精确匹配 → 保留。
        _push(client, editor_hdr, "d-editor", [
            _change("category", "cat-ic",
                    {"syncId": "cat-ic", "name": "IconCat", "kind": "expense",
                     "iconCloudFileId": "f-other"},
                    updated_at=_iso(base + timedelta(seconds=1))),
        ])
        with TS() as db:
            assert db.get(AttachmentFile, "f-shared-x") is not None, (
                "premature GC: owner-referenced attachment deleted"
            )
        assert path_shared.exists(), "premature GC: physical file unlinked"

        # 对照:cat-z 删除 → f-orphan-z 无任何引用 → 照常 GC(行为不放松)
        _push(client, editor_hdr, "d-editor", [
            _change("category", "cat-z", {}, action="delete",
                    updated_at=_iso(base + timedelta(seconds=2))),
        ])
        with TS() as db:
            assert db.get(AttachmentFile, "f-orphan-z") is None
        assert not path_orphan.exists()
    finally:
        app.dependency_overrides.clear()
