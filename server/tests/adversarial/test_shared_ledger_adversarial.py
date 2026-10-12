"""对抗性测试:共享账本 / 成员移除 / 账本删除 / 锁覆盖(同步域)。

契约参照 docs/SYNC_ARCHITECTURE.md §4.7(user→ledger 锁顺序)、§4.9
(user-global 镜像)、§4.10(被移除成员拒绝)。

说明:/sync/push 要求 APP_WRITE scope,web 登录的 owner 拿不到该 scope ——
需要走 push 的用例用 `setup_shared_ledger_full`(额外建一个 app 设备)。
"""
from __future__ import annotations

from datetime import timedelta

from _adv_helpers import (
    Ledger,
    LedgerMember,
    ReadTxProjection,
    UserAccountProjection,
    auth_headers,
    change,
    db_rows,
    iso,
    make_client,
    now_utc,
    push,
    read_txs,
    register_login,
    setup_shared_ledger,
    setup_shared_ledger_full,
    sync_changes,
    teardown,
    tx_change,
    tx_projection,
)
from _adv_helpers import select


# =========================================================================== #
# 1. 被移除成员 / 账本删除后的离线推送(§4.10)                                  #
# =========================================================================== #

def test_removed_member_ledger_scope_push_rejected_not_auto_created():
    """被移除成员的账本内变更 → 显式拒绝(membership_revoked),不静默重建账本。"""
    client, sf = make_client()
    try:
        (owner_web, owner_app, editor, ext) = setup_shared_ledger_full(client, "adv1")
        ed_token, ed_dev, ed_id = editor
        owner_token, owner_dev, owner_id = owner_web
        # editor 先推一笔(建立成员历史证据)
        res = push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        assert res.json()["accepted"] == 1, res.json()

        # owner 移除 editor
        res = client.request("DELETE", f"/api/v1/ledgers/{ext}/members/{ed_id}",
                             headers=auth_headers(owner_token, owner_dev))
        assert res.status_code == 204, res.text

        # editor 的离线变更再 push → 拒绝
        res = push(client, ed_token, ed_dev, [
            tx_change("tx-ed-off", amount=6, ledger_id=ext),
            tx_change("tx-ed", amount=55, ledger_id=ext,
                      ts=iso(now_utc() + timedelta(seconds=60))),
        ])
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["rejected"] == 2, body
        assert body["accepted"] == 0, body
        reasons = {s["reason"] for s in body["failed_samples"]}
        assert reasons == {"membership_revoked"}, body["failed_samples"]

        # 关键:不得出现第二个同名账本(caller 名下静默重建 = 数据分裂)
        with sf() as db:
            ledgers = db.scalars(select(Ledger).where(Ledger.external_id == ext)).all()
        assert len(ledgers) == 1, f"幽灵账本重建: {[l.user_id for l in ledgers]}"
        assert ledgers[0].user_id == owner_id
        # 原交易未被改动
        assert tx_projection(sf, "tx-ed").amount == 5.0
    finally:
        teardown()


def test_removed_member_user_global_push_still_allowed():
    """HARDENING:被移除成员仍可推送**自己的** user-global 资源(account/tag)——
    这些是 user-scope,与账本成员资格无关(设计如此);但会同步到其所有账本。
    owner 的 pull 看不到这些 user-scope 行(按 user_id 过滤),数据不越权。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv2")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        client.request("DELETE", f"/api/v1/ledgers/{ext}/members/{ed_id}",
                       headers=auth_headers(owner_token, owner_dev))
        res = push(client, ed_token, ed_dev, [
            change("account", "acc-after-removal", {"syncId": "acc-after-removal",
                                                    "name": "StillMine"}),
        ])
        assert res.json()["accepted"] == 1, res.json()
        acc = db_rows(sf, UserAccountProjection, sync_id="acc-after-removal")
        assert acc and acc[0].user_id == ed_id

        # owner 的 pull 看不到 editor 的 user-scope 行(按 user_id 过滤)
        body = client.get("/api/v1/sync/pull?since=0&limit=100",
                          headers=auth_headers(owner_token, owner_dev)).json()
        assert all(c["scope"] != "user" for c in body["changes"]), body["changes"]
    finally:
        teardown()


def test_ledger_deleted_editor_push_rejected():
    """owner 删除共享账本后,editor 的离线推送 → membership_revoked,不重建。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv3")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        res = client.request("DELETE", f"/api/v1/write/ledgers/{ext}",
                             headers=auth_headers(owner_token, owner_dev))
        assert res.status_code == 200, res.text

        res = push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        body = res.json()
        assert body["rejected"] == 1 and body["accepted"] == 0, body
        assert body["failed_samples"][0]["reason"] == "membership_revoked", body
        # 不允许以同 external_id 重建(soft-delete 语义)
        res = client.post("/api/v1/write/ledgers",
                          json={"ledger_id": ext, "ledger_name": "S2", "currency": "CNY"},
                          headers=auth_headers(owner_token, owner_dev))
        assert res.status_code == 409, res.text
    finally:
        teardown()


def test_owner_push_to_deleted_ledger_creates_ghost_projection_row():
    """ADVERSE FINDING(中危):owner 自己(仍是 member)在账本软删**之后**推
    ledger-scope 变更 → push 端不检查 `_is_ledger_deleted`,
    `apply_change_to_projection` 照常 upsert 投影行。

    结果:read 路径因 tombstone 全部 404/过滤(用户看不见),但
    `read_tx_projection` 里留下了**幽灵行**。对照:web 写路径有软删检查
    (src/routers/write/_shared.py:447-456 → 404,
    见 test_issue31_phantom_ledger.py::test_b2_write_to_soft_deleted_ledger_404_no_resurrection)。
    """
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv4")
        owner_web_token, owner_web_dev, owner_id = owner_web
        owner_token, owner_dev, _ = owner_app
        # 用 app 设备推一笔(账本内)
        push(client, owner_token, owner_dev, [tx_change("tx-before", amount=1, ledger_id=ext)])
        # web 删账本
        res = client.request("DELETE", f"/api/v1/write/ledgers/{ext}",
                             headers=auth_headers(owner_web_token, owner_web_dev))
        assert res.status_code == 200, res.text

        res = push(client, owner_token, owner_dev, [tx_change("tx-ghost", amount=77,
                                                              ledger_id=ext)])
        body = res.json()
        assert body["accepted"] == 0, (
            "// ADVERSE FINDING: push 到已软删的账本被接受(web 写路径 404 拒绝) —— "
            f"{body};投影里留下幽灵行,账本恢复/快照构建会把它带出来"
        )
        assert tx_projection(sf, "tx-ghost") is None
    finally:
        teardown()


def test_removed_member_can_no_longer_pull_ledger_data():
    """成员被移除后 pull 应立即看不到该账本(可访问账本集合收缩)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv5")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        body_before = client.get("/api/v1/sync/pull?since=0&limit=100",
                                 headers=auth_headers(ed_token, ed_dev)).json()
        assert any(c["ledger_id"] == ext for c in body_before["changes"])

        client.request("DELETE", f"/api/v1/ledgers/{ext}/members/{ed_id}",
                       headers=auth_headers(owner_token, owner_dev))
        body_after = client.get("/api/v1/sync/pull?since=0&limit=100",
                                headers=auth_headers(ed_token, ed_dev)).json()
        leaked = [c for c in body_after["changes"] if c["ledger_id"] == ext]
        assert leaked == [], f"被移除成员仍能拉到账本数据: {leaked}"
        assert client.get("/api/v1/sync/ledgers",
                          headers=auth_headers(ed_token, ed_dev)).json() == []
    finally:
        teardown()


# =========================================================================== #
# 2. user-global 镜像事件(§4.9)                                                 #
# =========================================================================== #

def test_owner_user_global_change_mirrors_to_shared_ledger():
    """owner 的 user-global 变更派生 ledger-scope 镜像 → editor 常规 pull 可见。

    owner 走 web 写路径(account create)产生镜像;editor 的 pull 必须拉到
    带 ledger_id=ext 的镜像事件。
    """
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv6")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        res = client.post(
            f"/api/v1/write/ledgers/{ext}/accounts",
            json={"base_change_id": 0, "name": "OwnerCash",
                  "account_type": "cash", "currency": "CNY", "initial_balance": 0},
            headers=auth_headers(owner_token, owner_dev),
        )
        assert res.status_code == 200, res.text
        acc_id = res.json()["entity_id"]

        body = client.get("/api/v1/sync/pull?since=0&limit=100",
                          headers=auth_headers(ed_token, ed_dev)).json()
        mirrored = [(c["entity_type"], c["entity_sync_id"], c["scope"],
                     c["ledger_id"], c["payload"].get("name"))
                    for c in body["changes"] if c["entity_sync_id"] == acc_id]
        assert ("account", acc_id, "ledger", ext, "OwnerCash") in mirrored, (
            f"owner 的 user-global 变更未镜像到共享账本: {mirrored}"
        )
    finally:
        teardown()


def test_solo_ledger_owner_change_produces_no_mirror():
    """单人账本不产生镜像(成员数 ≤ 1)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "adv7@adv.test", "d-a7")
        push(client, token, device, [
            change("account", "acc-solo", {"syncId": "acc-solo", "name": "Solo"}),
        ])
        rows = sync_changes(sf, entity_type="account", entity_sync_id="acc-solo")
        assert len(rows) == 1, [r.scope for r in rows]
        assert rows[0].scope == "user"
    finally:
        teardown()


def test_editor_push_user_global_change_produces_no_owner_mirror():
    """Editor 的 user-global 变更不产生 owner 可见镜像(镜像只派发给 actor
    作为 owner 的共享账本;editor 不是任何这些账本的 owner)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv8")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        push(client, ed_token, ed_dev, [
            change("account", "acc-ed", {"syncId": "acc-ed", "name": "EdCash"}),
        ])
        rows = sync_changes(sf, entity_type="account", entity_sync_id="acc-ed")
        assert len(rows) == 1 and rows[0].scope == "user", [r.scope for r in rows]

        body = client.get("/api/v1/sync/pull?since=0&limit=100",
                          headers=auth_headers(owner_token, owner_dev)).json()
        assert [c for c in body["changes"] if c["entity_sync_id"] == "acc-ed"] == []
    finally:
        teardown()


def test_owner_category_delete_mirror_payload_carries_syncid_only():
    """镜像的 delete 事件 payload 只带 syncId(不泄露投影内容)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv9")
        owner_token, owner_dev, owner_id = owner_web
        res = client.post(
            f"/api/v1/write/ledgers/{ext}/categories",
            json={"base_change_id": 0, "name": "Food", "kind": "expense"},
            headers=auth_headers(owner_token, owner_dev),
        )
        assert res.status_code == 200, res.text
        cat_id = res.json()["entity_id"]
        res = client.request("DELETE", f"/api/v1/write/ledgers/{ext}/categories/{cat_id}",
                             headers=auth_headers(owner_token, owner_dev),
                             json={"base_change_id": 0})
        assert res.status_code == 200, res.text

        rows = sync_changes(sf, entity_type="category", entity_sync_id=cat_id)
        deletes = [r for r in rows if r.action == "delete"]
        assert deletes, [r.action for r in rows]
        for r in deletes:
            if r.scope == "ledger":
                assert set(r.payload_json.keys()) == {"syncId"}, r.payload_json
    finally:
        teardown()


# =========================================================================== #
# 3. 共享账本内角色 / 数据归属                                                   #
# =========================================================================== #

def test_editor_cannot_push_ledger_meta_or_snapshot():
    """Editor 不能推 ledger / ledger_snapshot(owner-only 元数据)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv10")
        ed_token, ed_dev, ed_id = editor
        res = push(client, ed_token, ed_dev, [
            change("ledger_snapshot", ext, {"content": "{}"}, ledger_id=ext),
            change("ledger", ext, {"ledgerName": "Hacked"}, ledger_id=ext),
            change("budget", "bud-ed", {"syncId": "bud-ed", "type": "total",
                                        "amount": 10, "period": "monthly",
                                        "startDay": 1, "enabled": True},
                   ledger_id=ext),
        ])
        body = res.json()
        assert body["accepted"] == 1 and body["rejected"] == 2, body
        with sf() as db:
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == ext))
        assert ledger.name == "Shared", ledger.name
    finally:
        teardown()


def test_editor_rename_cascades_to_owner_projection_rows():
    """Editor 改名 → owner 名下投影行也被刷(P0-1 谓词按 sync_id,不按 user_id)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv11")
        owner_app_token, owner_app_dev, _ = owner_app
        ed_token, ed_dev, ed_id = editor
        base = now_utc()
        # editor 建账户 + 交易
        push(client, ed_token, ed_dev, [
            change("account", "acc-shared", {"syncId": "acc-shared", "name": "A1",
                                             "type": "cash", "currency": "CNY"},
                   updated_at=iso(base)),
            tx_change("tx-shared", amount=10, ledger_id=ext, ts=iso(base),
                      accountId="acc-shared", accountName="A1"),
        ])
        # owner(app 设备)也建一笔引用同一账户
        push(client, owner_app_token, owner_app_dev, [
            tx_change("tx-own", amount=20, ledger_id=ext,
                      ts=iso(base + timedelta(microseconds=1)),
                      accountId="acc-shared", accountName="A1"),
        ])
        # editor 改名
        push(client, ed_token, ed_dev, [
            change("account", "acc-shared", {"syncId": "acc-shared", "name": "A2",
                                             "type": "cash", "currency": "CNY"},
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        for sid in ("tx-shared", "tx-own"):
            row = tx_projection(sf, sid)
            assert row is not None, f"{sid} 不存在"
            assert row.account_name == "A2", (
                f"{sid} 未被 Editor 改名级联刷新(P0-1 谓词漏行): {row.account_name}"
            )
    finally:
        teardown()


def test_shared_ledger_tx_projection_user_id_is_ledger_owner():
    """共享账本:editor 推的交易投影行 user_id = ledger owner(denorm 契约)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv12")
        ed_token, ed_dev, ed_id = editor
        owner_id = owner_web[2]
        push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        row = tx_projection(sf, "tx-ed")
        assert row.user_id == owner_id, (row.user_id, owner_id)
        assert row.last_edited_by_user_id == ed_id, row.last_edited_by_user_id
    finally:
        teardown()


def test_owner_removing_editor_does_not_delete_editor_created_tx():
    """移除成员不清理其创建的历史数据(账本数据属于账本,不随成员走)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv13")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        client.request("DELETE", f"/api/v1/ledgers/{ext}/members/{ed_id}",
                       headers=auth_headers(owner_token, owner_dev))
        body = read_txs(client, owner_token, ext)
        assert [t["id"] for t in body] == ["tx-ed"], body
    finally:
        teardown()


def test_pull_after_ledger_delete_delivers_tombstone_to_owner():
    """owner 删除账本后 pull 能拿到 tombstone(客户端据此清本地账本)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv14")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        first = client.get("/api/v1/sync/pull?since=0&limit=100",
                           headers=auth_headers(owner_token, owner_dev)).json()
        cursor = first["server_cursor"]

        client.request("DELETE", f"/api/v1/write/ledgers/{ext}",
                       headers=auth_headers(owner_token, owner_dev))
        after = client.get(f"/api/v1/sync/pull?since={cursor}&limit=100",
                           headers=auth_headers(owner_token, owner_dev)).json()
        tombstones = [(c["entity_type"], c["action"]) for c in after["changes"]]
        assert ("ledger_snapshot", "delete") in tombstones, tombstones
    finally:
        teardown()


def test_ledger_delete_prunes_other_members_data_visibility():
    """账本删除后成员(even 用 since=0)pull 不到任何该账本历史事件。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv15")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        client.request("DELETE", f"/api/v1/write/ledgers/{ext}",
                       headers=auth_headers(owner_token, owner_dev))
        body = client.get("/api/v1/sync/pull?since=0&limit=200",
                          headers=auth_headers(ed_token, ed_dev)).json()
        leaked = [c for c in body["changes"]
                  if c["entity_type"] in ("transaction", "budget", "ledger")]
        assert leaked == [], f"已删账本的历史事件仍被下发: {leaked}"
    finally:
        teardown()


def test_ledger_delete_truncates_projection_but_keeps_owner_member():
    """账本删除:投影清零 + 非 owner 成员删除 + owner 成员保留(否则 pull 不到墓碑)。"""
    client, sf = make_client()
    try:
        owner_web, owner_app, editor, ext = setup_shared_ledger_full(client, "adv16")
        owner_token, owner_dev, owner_id = owner_web
        ed_token, ed_dev, ed_id = editor
        push(client, ed_token, ed_dev, [tx_change("tx-ed", amount=5, ledger_id=ext)])
        client.request("DELETE", f"/api/v1/write/ledgers/{ext}",
                       headers=auth_headers(owner_token, owner_dev))

        with sf() as db:
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == ext))
            members = db.scalars(select(LedgerMember).where(
                LedgerMember.ledger_id == ledger.id)).all()
            tx_rows = db.scalars(select(ReadTxProjection).where(
                ReadTxProjection.ledger_id == ledger.id)).all()
        assert len(members) == 1 and members[0].user_id == owner_id, [m.user_id for m in members]
        assert tx_rows == [], "删除账本必须清空投影"
    finally:
        teardown()


# =========================================================================== #
# 4. 锁覆盖静态审计(§4.7)                                                      #
# =========================================================================== #

# 已知且**有意**的例外(不构成缺陷,加入白名单避免误报):
#   - src/routers/write/_shared.py / sync/push.py / import_data/endpoints.py:
#     已取 user+ledger 锁。
_LOCK_AUDIT_WHITELIST = {
    "src/routers/write/_shared.py",
    "src/routers/sync/push.py",
    "src/routers/import_data/endpoints.py",
}


def test_projection_write_paths_acquire_locks_static_audit():
    """ADVERSE FINDING(中危/架构):静态审计「改了 projection 但没取
    user/ledger 锁」的写路径。

    契约 §4.7 要求应用 projection 之前取事务级 advisory lock(PostgreSQL)。
    当前以下入口调用 projection 写函数但**完全没有** lock 调用:

    - `src/routers/read/trash.py`(restore_tx / purge_tx /
      gc_orphan_attachments_for_ledger)—— 回收站恢复/彻底删除与并发 push
      的 tx upsert 可交叉;
    - `src/services/data_cleanup/cleaner.py`(purge_tx + GC)、
      `src/services/data_cleanup/duplicates.py`(delete_tx + GC)
      —— 后台清理/去重任务与在线写入并发;
    - `src/routers/write/ledgers.py` 的 `delete_ledger`:取了
      lock_ledger_for_materialize(line 308)但没取 owner 的 user 锁 ——
      与 push 的 user-scope 分支交错时,「账本 truncate」与
      「user-global rename cascade 按 sync_id 全表 UPDATE」可并发命中同一批行。

    PostgreSQL 下这是真实竞态;SQLite 无 advisory lock(no-op),该行为在
    测试中不可复现 → 本测试用**静态扫描**守住覆盖集,新增无锁入口即红。
    """
    import pathlib
    import re

    root = pathlib.Path("src")
    pattern = re.compile(
        r"projection\.(upsert_\w+|delete_\w+|purge_tx|restore_tx|"
        r"rename_cascade_\w+|detach_cascade_tag|_truncate_ledger|gc_orphan_\w+)"
    )
    unlocked: list[str] = []
    for path in root.rglob("*.py"):
        rel = str(path).replace("\\", "/")
        # 业务层被调用方(锁由 caller 负责)与已知有锁的入口排除
        if path.name in {"projection.py", "sync_applier.py", "snapshot_mutator.py"}:
            continue
        if rel in _LOCK_AUDIT_WHITELIST:
            continue
        text = path.read_text(encoding="utf-8")
        if not pattern.search(text):
            continue
        has_ledger = "lock_ledger_for_materialize" in text
        has_user = "lock_user_global" in text
        if not (has_ledger and has_user):
            unlocked.append(f"{rel}(ledger_lock={has_ledger}, user_lock={has_user})")

    assert unlocked == [], (
        "// ADVERSE FINDING: 以下写路径修改 projection 但未按 §4.7 取 user+ledger 锁 —— "
        f"{unlocked};PostgreSQL 上并发调用会与 push/write 的 cascade 交错"
        "(SQLite 无 advisory lock,该风险不可在测试中复现,属架构级问题)"
    )


def test_lock_ordering_is_user_then_ledger_in_push():
    """静态检查:push 路径的锁顺序是 user→ledger(防死锁契约)。"""
    import pathlib
    src = pathlib.Path("src/routers/sync/push.py").read_text(encoding="utf-8")
    user_idx = src.find("lock_user_global(db, ledger.user_id)")
    ledger_idx = src.find("lock_ledger_for_materialize(db, ledger.id)")
    assert user_idx != -1 and ledger_idx != -1, "锁调用缺失"
    assert user_idx < ledger_idx, "锁顺序契约违背:必须先取 user 锁再取 ledger 锁(§4.7)"
    # 批首预取 caller user 锁(批内含 user-global 变更时)
    assert "if any(c.entity_type in USER_GLOBAL_ENTITY_TYPES for c in req.changes)" in src
