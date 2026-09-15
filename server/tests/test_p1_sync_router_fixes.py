"""P1 波同步路由修复回归测试(2026-09-15 design-flaw-fix-plan):

  - **B2** 共享账本 owner 的 user-global(账户/分类/标签)变更派生 ledger-scope
    镜像 SyncChange —— Editor 常规 /sync/pull 拉得到(WS 掉线不再永久分叉);
    单人账本不产生镜像;镜像不重复发 tx cascade 事件。
  - **C1** /sync/push 批处理核心经 run_in_threadpool,大批推送不阻塞
    event loop(asyncio 探针验证)。
  - **E1** 首绑判据 = SyncChange 存在性(不可变事实);被移除成员 / 已删
    共享账本的再推 → 显式拒绝(membership_revoked),不静默重建私有账本。
  - **E2** /sync/ledgers 返回真实 role(Editor 端不再是恒 owner)。

契约参考 SYNC_ARCHITECTURE §4.9(B2 镜像)/ §4.2(LWW)。
"""
from __future__ import annotations

import asyncio
import time
from datetime import datetime, timedelta, timezone

import httpx
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import Ledger, SyncChange


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


def _login_app_device(client, email, device):
    """同一用户加一个 app 设备(拿 app token + 独立 device_id)。"""
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


def _setup_shared_ledger(client, *, tag="b2"):
    """owner(web)+ editor(app)双用户 + 已接受的共享账本。"""
    owner_token, owner_id = _register(client, f"{tag}-owner@t.com", "web", "d-owner")
    editor_token, editor_id = _register(client, f"{tag}-editor@t.com", "app", "d-editor")

    r = client.post(
        "/api/v1/write/ledgers",
        json={"ledger_id": f"shared-{tag}", "ledger_name": "Family", "currency": "CNY"},
        headers={"Authorization": f"Bearer {owner_token}", "X-Device-ID": "d-owner"},
    )
    assert r.status_code == 200, r.text

    r = client.post(
        f"/api/v1/ledgers/shared-{tag}/invites",
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
    return owner_token, owner_id, editor_token, editor_id, f"shared-{tag}"


def _ledger_internal_id(TS, external_id, owner_id=None):
    with TS() as db:
        q = select(Ledger).where(Ledger.external_id == external_id)
        if owner_id is not None:
            q = q.where(Ledger.user_id == owner_id)
        row = db.scalar(q)
        assert row is not None, external_id
        return row.id


# ===========================================================================
# P1-B2 —— owner user-global 变更的 ledger-scope 镜像
# ===========================================================================


def test_b2_owner_web_account_change_derives_ledger_mirror_visible_to_editor_pull():
    """Owner 在 web 写路径创建 + 改名账户(账本有 Editor 成员)→ 产生
    ledger-scope 镜像 SyncChange(payload = cascade 后投影状态),Editor 的
    常规 /sync/pull 拉得到 —— 不依赖 WS。"""
    client, TS = _make_client()
    try:
        owner_token, _owner_id, editor_token, _editor_id, ledger_x = _setup_shared_ledger(client, tag="b2w")
        owner_hdr = {"Authorization": f"Bearer {owner_token}", "X-Device-ID": "d-owner"}
        lid = _ledger_internal_id(TS, ledger_x)

        # Owner 在 web 建账户 → fast-entity 路径
        r = client.post(
            f"/api/v1/write/ledgers/{ledger_x}/accounts",
            json={"base_change_id": 0, "name": "OldName",
                  "account_type": "cash", "currency": "CNY",
                  "initial_balance": 100},
            headers=owner_hdr,
        )
        assert r.status_code == 200, r.text
        acc_sync_id = r.json()["entity_id"]

        def _mirrors():
            with TS() as db:
                return db.scalars(select(SyncChange).where(
                    SyncChange.scope == "ledger",
                    SyncChange.entity_type == "account",
                    SyncChange.entity_sync_id == acc_sync_id,
                    SyncChange.ledger_id == lid,
                )).all()

        # create 已产生镜像
        assert len(_mirrors()) == 1, "create 未派生镜像"

        # Owner web 改名
        r = client.patch(
            f"/api/v1/write/ledgers/{ledger_x}/accounts/{acc_sync_id}",
            json={"base_change_id": 0, "name": "NewName"},
            headers=owner_hdr,
        )
        assert r.status_code == 200, r.text

        mirrors = _mirrors()
        assert len(mirrors) == 2, f"rename 未派生镜像: {len(mirrors)}"
        latest = max(mirrors, key=lambda c: c.change_id)
        # 镜像内容 = cascade 后投影状态(全量字段,不是 partial payload)
        assert latest.payload_json["name"] == "NewName"
        assert latest.payload_json["type"] == "cash"
        assert latest.payload_json["currency"] == "CNY"
        assert latest.payload_json["initialBalance"] == 100
        assert latest.payload_json["syncId"] == acc_sync_id
        # ledger-scope 行归属 ledger owner,操作者身份在 updated_by_user_id
        assert latest.user_id == _owner_id
        assert latest.updated_by_user_id == _owner_id
        assert latest.updated_by_device_id == "d-owner"

        # Editor 常规 pull 拉得到(不依赖 WS;device 过滤不影响 —— 推送方是 owner)
        r = client.get(
            "/api/v1/sync/pull?since=0&device_id=d-editor",
            headers={"Authorization": f"Bearer {editor_token}"},
        )
        assert r.status_code == 200, r.text
        pulled = [
            c for c in r.json()["changes"]
            if c["entity_type"] == "account" and c["entity_sync_id"] == acc_sync_id
        ]
        assert any(c.get("payload", {}).get("name") == "NewName" for c in pulled), pulled
        assert all(c["ledger_id"] == ledger_x for c in pulled), pulled
    finally:
        app.dependency_overrides.clear()


def test_b2_solo_ledger_owner_change_derives_no_mirror():
    """单人账本(无成员)的 owner user-global 变更不产生 ledger-scope 镜像。"""
    client, TS = _make_client()
    try:
        owner_token, owner_id = _register(client, "b2solo@t.com", "web", "d-solo")
        owner_hdr = {"Authorization": f"Bearer {owner_token}", "X-Device-ID": "d-solo"}
        r = client.post(
            "/api/v1/write/ledgers",
            json={"ledger_name": "Solo", "currency": "CNY"},
            headers=owner_hdr,
        )
        assert r.status_code == 200, r.text
        ledger_x = r.json()["entity_id"]
        lid = _ledger_internal_id(TS, ledger_x, owner_id)

        r = client.post(
            f"/api/v1/write/ledgers/{ledger_x}/accounts",
            json={"base_change_id": 0, "name": "A", "account_type": "cash",
                  "currency": "CNY"},
            headers=owner_hdr,
        )
        assert r.status_code == 200, r.text
        acc_sync_id = r.json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{ledger_x}/accounts/{acc_sync_id}",
            json={"base_change_id": 0, "name": "B"},
            headers=owner_hdr,
        )
        assert r.status_code == 200, r.text

        with TS() as db:
            cnt = db.scalar(
                select(func.count()).select_from(SyncChange).where(
                    SyncChange.scope == "ledger",
                    SyncChange.entity_type == "account",
                    SyncChange.ledger_id == lid,
                )
            )
            assert cnt == 0, f"单人账本不应产生镜像: {cnt}"
    finally:
        app.dependency_overrides.clear()


def test_b2_owner_push_account_rename_mirror_no_tx_cascade_duplication():
    """Owner 走 /sync/push 改名账户 → 镜像派生(push 路径);且与 P0 波的
    cascade-only tx 补发机制协调:tx 事件仍只有「初始 upsert + 1 条 cascade」,
    镜像只新增 account 实体行,不重复发 transaction 事件。"""
    client, TS = _make_client()
    try:
        owner_token, owner_id, _editor_token, _editor_id, ledger_x = _setup_shared_ledger(client, tag="b2p")
        # owner 加一台 app 设备走 push 通道
        owner_app_token = _login_app_device(client, "b2p-owner@t.com", "d-owner-app")
        owner_hdr = {"Authorization": f"Bearer {owner_app_token}"}
        base = datetime.now(timezone.utc)

        _push(client, owner_hdr, "d-owner-app", [
            _change("account", "acc-o",
                    {"syncId": "acc-o", "name": "OldName", "type": "bank", "currency": "CNY"},
                    updated_at=_iso(base)),
            _change("transaction", "tx-m", {
                "syncId": "tx-m", "type": "expense", "amount": 8,
                "happenedAt": _iso(base),
                "accountId": "acc-o", "accountName": "OldName",
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])
        # 改名(注意 partial payload:只带 name —— 镜像必须是 merge 后全量)
        _push(client, owner_hdr, "d-owner-app", [
            _change("account", "acc-o", {"syncId": "acc-o", "name": "NewName"},
                    updated_at=_iso(base + timedelta(seconds=5))),
        ])

        lid = _ledger_internal_id(TS, ledger_x)
        with TS() as db:
            # 镜像:create + rename 两条 ledger-scope account 行
            mirrors = db.scalars(select(SyncChange).where(
                SyncChange.scope == "ledger",
                SyncChange.entity_type == "account",
                SyncChange.entity_sync_id == "acc-o",
                SyncChange.ledger_id == lid,
            )).all()
            assert len(mirrors) == 2, [m.change_id for m in mirrors]
            latest = max(mirrors, key=lambda c: c.change_id)
            # payload 是 apply 后投影状态:merge 补齐了 type/currency(partial 只带 name)
            assert latest.payload_json["name"] == "NewName"
            assert latest.payload_json["type"] == "bank"
            assert latest.payload_json["currency"] == "CNY"
            assert latest.updated_by_user_id == owner_id

            # tx 事件不重复:初始 upsert + P0 cascade 补发 = 2,镜像没加第 3 条
            tx_changes = db.scalars(select(SyncChange).where(
                SyncChange.entity_type == "transaction",
                SyncChange.entity_sync_id == "tx-m",
                SyncChange.ledger_id == lid,
            )).all()
            assert len(tx_changes) == 2, [c.change_id for c in tx_changes]
            cascade = max(tx_changes, key=lambda c: c.change_id)
            assert cascade.payload_json["accountName"] == "NewName"
    finally:
        app.dependency_overrides.clear()


# ===========================================================================
# P1-E1 —— 首绑放行 + 被移除成员显式拒绝
# ===========================================================================


def test_e1_first_push_auto_create_allowed():
    """全新 device 首推 tx(未知 external_id,无账本)→ 首绑放行,auto-create。"""
    client, TS = _make_client()
    try:
        token, user_id = _register(client, "e1a@t.com", "app", "d-e1a")
        hdr = {"Authorization": f"Bearer {token}"}
        base = datetime.now(timezone.utc)

        resp = _push(client, hdr, "d-e1a", [
            _change("transaction", "tx-1", {
                "syncId": "tx-1", "type": "expense", "amount": 1,
                "happenedAt": _iso(base),
            }, ledger_id="brand-new-ledger", updated_at=_iso(base)),
        ])
        assert resp["accepted"] == 1, resp
        with TS() as db:
            led = db.scalar(select(Ledger).where(
                Ledger.user_id == user_id,
                Ledger.external_id == "brand-new-ledger",
            ))
            assert led is not None, "首推应 auto-create 账本"
    finally:
        app.dependency_overrides.clear()


def test_e1_first_bind_device_bypasses_owned_count_guard():
    """首绑判据按 SyncChange 存在性:device 从未推送过时,即使用户已有 ≥2
    个账本,推未知 external_id 仍放行(迁移/换机导入场景);同一 device 推过
    之后再推未知 external_id 且已 ≥2 账本 → ghost guard 拒绝。"""
    client, TS = _make_client()
    try:
        token, user_id = _register(client, "e1b@t.com", "web", "d-e1b")
        hdr = {"Authorization": f"Bearer {token}", "X-Device-ID": "d-e1b"}
        for name in ("One", "Two"):
            r = client.post(
                "/api/v1/write/ledgers",
                json={"ledger_name": name, "currency": "CNY"},
                headers=hdr,
            )
            assert r.status_code == 200, r.text
        # app 设备首推(该 device 从未推送过)→ 放行
        app_token = _login_app_device(client, "e1b@t.com", "d-e1b-app")
        base = datetime.now(timezone.utc)
        resp = _push(client, {"Authorization": f"Bearer {app_token}"}, "d-e1b-app", [
            _change("transaction", "tx-mig", {
                "syncId": "tx-mig", "type": "expense", "amount": 2,
                "happenedAt": _iso(base),
            }, ledger_id="migrated-ledger", updated_at=_iso(base)),
        ])
        assert resp["accepted"] == 1, resp

        # 同一 device 已推送过 → 再推又一个未知 external_id(用户已 3 账本)→ 拒
        resp = _push(client, {"Authorization": f"Bearer {app_token}"}, "d-e1b-app", [
            _change("transaction", "tx-ghost", {
                "syncId": "tx-ghost", "type": "expense", "amount": 3,
                "happenedAt": _iso(base + timedelta(seconds=1)),
            }, ledger_id="ghost-ledger", updated_at=_iso(base + timedelta(seconds=1))),
        ])
        assert resp["rejected"] == 1, resp
        assert resp["failed_samples"][0]["reason"] == "unknown_ledger", resp
        with TS() as db:
            assert db.scalar(select(Ledger).where(
                Ledger.user_id == user_id,
                Ledger.external_id == "ghost-ledger",
            )) is None
    finally:
        app.dependency_overrides.clear()


def test_e1_removed_member_push_rejected_no_ghost_rebuild():
    """Editor 被移除后再推该账本 tx → 显式拒绝(membership_revoked),
    不在 Editor 名下重建同 external_id 私有账本。"""
    client, TS = _make_client()
    try:
        owner_token, _o, editor_token, editor_id, ledger_x = _setup_shared_ledger(client, tag="e1r")
        editor_hdr = {"Authorization": f"Bearer {editor_token}"}
        base = datetime.now(timezone.utc)

        # Editor 推一笔 tx(成员期,正常)
        resp = _push(client, editor_hdr, "d-editor", [
            _change("transaction", "tx-ok", {
                "syncId": "tx-ok", "type": "expense", "amount": 5,
                "happenedAt": _iso(base),
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])
        assert resp["accepted"] == 1, resp

        # Owner 移除 Editor
        r = client.delete(
            f"/api/v1/ledgers/{ledger_x}/members/{editor_id}",
            headers={"Authorization": f"Bearer {owner_token}", "X-Device-ID": "d-owner"},
        )
        assert r.status_code == 204, r.text

        # Editor 掉线未收到通知,继续推该账本 → 拒绝 + 明确 reason,不 auto-create
        resp = _push(client, editor_hdr, "d-editor", [
            _change("transaction", "tx-after", {
                "syncId": "tx-after", "type": "expense", "amount": 6,
                "happenedAt": _iso(base + timedelta(seconds=5)),
            }, ledger_id=ledger_x, updated_at=_iso(base + timedelta(seconds=5))),
        ])
        assert resp["rejected"] == 1, resp
        assert resp["failed_samples"][0]["reason"] == "membership_revoked", resp

        with TS() as db:
            # 没有在 Editor 名下重建同 external_id 账本
            assert db.scalar(select(Ledger).where(
                Ledger.external_id == ledger_x,
                Ledger.user_id == editor_id,
            )) is None, "被移除成员触发了幽灵账本重建"
    finally:
        app.dependency_overrides.clear()


def test_e1_deleted_shared_ledger_push_rejected():
    """共享账本被 owner 删除(掉线的 Editor 未收到)→ Editor 后续推该账本
    tx 同样显式拒绝,不重建。"""
    client, TS = _make_client()
    try:
        owner_token, _o, editor_token, _e, ledger_x = _setup_shared_ledger(client, tag="e1d")
        editor_hdr = {"Authorization": f"Bearer {editor_token}"}
        base = datetime.now(timezone.utc)

        resp = _push(client, editor_hdr, "d-editor", [
            _change("transaction", "tx-del", {
                "syncId": "tx-del", "type": "expense", "amount": 7,
                "happenedAt": _iso(base),
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])
        assert resp["accepted"] == 1, resp

        r = client.delete(
            f"/api/v1/write/ledgers/{ledger_x}",
            headers={"Authorization": f"Bearer {owner_token}", "X-Device-ID": "d-owner"},
        )
        assert r.status_code == 200, r.text

        resp = _push(client, editor_hdr, "d-editor", [
            _change("transaction", "tx-zombie", {
                "syncId": "tx-zombie", "type": "expense", "amount": 9,
                "happenedAt": _iso(base + timedelta(seconds=5)),
            }, ledger_id=ledger_x, updated_at=_iso(base + timedelta(seconds=5))),
        ])
        assert resp["rejected"] == 1, resp
        assert resp["failed_samples"][0]["reason"] == "membership_revoked", resp
        with TS() as db:
            ledgers_same_ext = db.scalars(
                select(Ledger).where(Ledger.external_id == ledger_x)
            ).all()
            # 只剩 owner 的软删壳行,Editor 名下没有重建
            assert all(lg.user_id != _e for lg in ledgers_same_ext), ledgers_same_ext
    finally:
        app.dependency_overrides.clear()


# ===========================================================================
# P1-E2 —— /sync/ledgers role 正确化
# ===========================================================================


def test_e2_sync_ledgers_returns_real_role():
    """Editor 视角 /sync/ledgers 返回 role=editor(不再硬编码 owner);
    owner 视角 role=owner。响应字段结构不变。"""
    client, TS = _make_client()
    try:
        owner_token, _o, editor_token, _e, ledger_x = _setup_shared_ledger(client, tag="e2")
        # 账本里放一笔 tx,否则 latest_change_id==0 会被过滤(建账本本身有
        # ledger entity change,已满足 >0;这里仍放一笔保持场景真实)
        owner_app = _login_app_device(client, "e2-owner@t.com", "d-e2-oapp")
        base = datetime.now(timezone.utc)
        _push(client, {"Authorization": f"Bearer {owner_app}"}, "d-e2-oapp", [
            _change("transaction", "tx-r", {
                "syncId": "tx-r", "type": "expense", "amount": 4,
                "happenedAt": _iso(base),
            }, ledger_id=ledger_x, updated_at=_iso(base)),
        ])

        for token, expected_role in (
            (editor_token, "editor"),
            (owner_token, "owner"),
        ):
            r = client.get(
                "/api/v1/sync/ledgers",
                headers={"Authorization": f"Bearer {token}"},
            )
            assert r.status_code == 200, r.text
            rows = r.json()
            target = [lg for lg in rows if lg["ledger_id"] == ledger_x]
            assert len(target) == 1, rows
            entry = target[0]
            assert entry["role"] == expected_role, entry
            # 协议字段兼容:字段名不变
            assert set(entry.keys()) >= {
                "ledger_id", "path", "updated_at", "size", "metadata", "role",
            }, entry
    finally:
        app.dependency_overrides.clear()


# ===========================================================================
# P1-C1 —— push 批处理不阻塞 event loop
# ===========================================================================


def test_c1_large_push_does_not_block_event_loop():
    """300+ 条 change 的 push 期间,event loop 保持响应(asyncio 探针)。

    批处理核心经 run_in_threadpool 跑在 worker 线程(P1-C1);若回退到在
    loop 上同步跑 DB,探针的单次 sleep 漂移会逼近整批耗时(秒级)。
    """
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
    try:
        async def _scenario() -> tuple[dict, float]:
            transport = httpx.ASGITransport(app=app)
            async with httpx.AsyncClient(
                transport=transport, base_url="http://testserver",
            ) as ac:
                reg = await ac.post("/api/v1/auth/register", json={
                    "email": "c1@t.com", "password": "Pa$$word1!",
                    "device_id": "d-c1", "client_type": "app",
                    "device_name": "pytest-c1", "platform": "test",
                })
                assert reg.status_code == 200, reg.text
                token = reg.json()["access_token"]
                hdr = {"Authorization": f"Bearer {token}"}

                base = datetime.now(timezone.utc)
                changes = [
                    _change("transaction", f"tx-bulk-{i}", {
                        "syncId": f"tx-bulk-{i}", "type": "expense",
                        "amount": 1 + (i % 50),
                        "happenedAt": _iso(base),
                        "note": f"bulk-{i}-" + "x" * 40,
                    }, ledger_id="bulk-ledger", updated_at=_iso(base))
                    for i in range(400)
                ]
                body = {"device_id": "d-c1", "changes": changes}

                stalls: list[float] = []
                probe_done = asyncio.Event()

                async def _probe() -> None:
                    while not probe_done.is_set():
                        t0 = time.perf_counter()
                        await asyncio.sleep(0.02)
                        stalls.append(time.perf_counter() - t0 - 0.02)

                probe_task = asyncio.create_task(_probe())
                t0 = time.perf_counter()
                resp = await ac.post(
                    "/api/v1/sync/push", headers=hdr, json=body,
                )
                push_duration = time.perf_counter() - t0
                probe_done.set()
                await probe_task
                assert resp.status_code == 200, resp.text
                payload = resp.json()
                max_stall = max(stalls) if stalls else 0.0
                return payload, push_duration, max_stall

        payload, push_duration, max_stall = asyncio.run(_scenario())
        assert payload["accepted"] == 400, payload
        assert max_stall < 0.5, (
            f"event loop stalled {max_stall:.3f}s during push "
            f"({push_duration:.3f}s total) — 批处理未进线程池?"
        )
    finally:
        app.dependency_overrides.clear()
