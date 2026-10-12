"""对抗性测试:rename cascade / 投影一致性 / 级联删除 / 增量 pull 边界。

契约参照 docs/SYNC_ARCHITECTURE.md §4.4(rename cascade 双路径 + P0-1 谓词)、
§4.5(merge 语义)、§4.6(change_id 单调性)/ pull 边界。

覆盖攻击清单「rename cascade」「投影一致性」「级联删除」三组。
"""
from __future__ import annotations

from datetime import timedelta

from _adv_helpers import (
    ReadBudgetProjection,
    ReadTxProjection,
    SyncChange,
    UserAccountProjection,
    UserCategoryProjection,
    UserTagProjection,
    auth_headers,
    change,
    db_rows,
    iso,
    ledger_internal_id,
    make_client,
    now_utc,
    push,
    read_txs,
    register_login,
    replay_projection_state,
    sync_changes,
    teardown,
    tx_change,
    tx_projection,
    web_create_category,
    web_create_ledger,
    web_create_tx,
)
from _adv_helpers import select


# =========================================================================== #
# 1. rename cascade:投影刷写正确性                                                #
# =========================================================================== #

def _seed_category_and_tx(client, token, device, *, cat_name="Food", tx_amount=10):
    base = now_utc()
    push(client, token, device, [
        change("category", "cat-1", {"syncId": "cat-1", "name": cat_name,
                                     "kind": "expense"}, updated_at=iso(base)),
        change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                       "amount": tx_amount, "happenedAt": iso(),
                                       "categoryId": "cat-1", "categoryName": cat_name,
                                       "categoryKind": "expense"},
               ledger_id="L01", updated_at=iso(base)),
    ])
    return base


def test_rename_cascade_updates_projection_and_emits_cascade_event():
    """rename 后:投影 denorm 列刷新 + 补发 cascade-only tx 事件(落后设备可追平)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c1@adv.test", "d-c1")
        base = _seed_category_and_tx(client, token, device)
        res = push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Meals",
                                         "kind": "expense"},
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        assert res.json()["accepted"] == 1

        row = tx_projection(sf, "tx-1")
        assert row.category_name == "Meals", f"投影未刷新: {row.category_name}"

        tx_events = sync_changes(sf, entity_type="transaction", entity_sync_id="tx-1")
        assert len(tx_events) >= 2, "rename 必须补发 cascade-only tx 事件"
        assert tx_events[-1].payload_json["categoryName"] == "Meals"
    finally:
        teardown()


def test_rename_cascade_skips_soft_deleted_tx_rows():
    """软删(回收站)行:投影仍被 SQL 刷(cascade 谓词不过滤 deleted_at),
    但**不补发** cascade 事件 —— 避免 mobile 端按 upsert 重建已删交易。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c2@adv.test", "d-c2")
        base = _seed_category_and_tx(client, token, device)
        # 再建一条将被软删的交易
        push(client, token, device, [
            change("transaction", "tx-dead", {"syncId": "tx-dead", "type": "expense",
                                              "amount": 10, "happenedAt": iso(),
                                              "categoryId": "cat-1",
                                              "categoryName": "Food",
                                              "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base + timedelta(microseconds=1))),
        ])
        push(client, token, device, [
            change("transaction", "tx-dead", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Meals",
                                         "kind": "expense"},
                   updated_at=iso(base + timedelta(seconds=2))),
        ])
        live_events = sync_changes(sf, entity_type="transaction", entity_sync_id="tx-live")
        dead_events = [c for c in sync_changes(sf, entity_type="transaction",
                                               entity_sync_id="tx-dead")]
        assert not any(c.action == "upsert" and
                       (c.payload_json or {}).get("categoryName") == "Meals"
                       for c in dead_events[1:]), (
            "软删行不得补发 cascade upsert(会让 mobile 重建已删交易)"
        )
        assert tx_projection(sf, "tx-dead").deleted_at is not None
    finally:
        teardown()


def test_stale_tx_push_with_old_name_after_rename_restores_old_denorm():
    """ADVERSE FINDING(中危):改名后,离线老客户端推带**旧名**的交易编辑 →
    服务端投影的 category_name 被写回旧名(与新名不一致),直到下一次 rename 才自愈。

    src/sync_applier.py:814-843:`_detect_and_run_rename_cascade_user` 只在
    **类别实体自身**被 push 时才跑;tx upsert 走 `merge_with_existing` →
    payload 显式带的 `categoryName='Food'` 直接落库(merge 只补 None 字段,
    不校验 FK 一致性)。P0-1 契约只保证「按 sync_id 匹配」,没保证「name 与
    权威 category 行一致」。用户可见:web 交易列表显示旧分类名,而分类列表
    显示新名。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c3@adv.test", "d-c3")
        base = _seed_category_and_tx(client, token, device)
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Meals",
                                         "kind": "expense"},
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        assert tx_projection(sf, "tx-1").category_name == "Meals"

        # 离线设备(只知道旧名 Food)推该交易的编辑
        res = push(client, token, device, [
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 55, "happenedAt": iso(),
                                           "categoryId": "cat-1",
                                           "categoryName": "Food",
                                           "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base + timedelta(seconds=2))),
        ])
        assert res.json()["accepted"] == 1, res.json()

        cat = db_rows(sf, UserCategoryProjection, sync_id="cat-1")[0]
        row = tx_projection(sf, "tx-1")
        assert row.category_name == cat.name, (
            "// ADVERSE FINDING: 陈旧交易推送把投影 denorm 名写回旧值 —— "
            f"tx.category_name={row.category_name!r} 但 category.name={cat.name!r} "
            "(同一 FK 的两个 denorm 副本分裂,web 交易列表显示旧分类名)"
        )
    finally:
        teardown()


def test_account_rename_then_stale_tx_push_denorm_drift():
    """ADVERSE FINDING(中危,account 版):同名漂移同样发生,且 web 账户维度
    统计按 account_sync_id 聚合、列表按 account_name 展示 → 看板口径分裂。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c4@adv.test", "d-c4")
        base = now_utc()
        push(client, token, device, [
            change("account", "acc-1", {"syncId": "acc-1", "name": "Cash",
                                        "type": "cash", "currency": "CNY"},
                   updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "accountId": "acc-1", "accountName": "Cash"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        push(client, token, device, [
            change("account", "acc-1", {"syncId": "acc-1", "name": "Wallet",
                                        "type": "cash", "currency": "CNY"},
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        assert tx_projection(sf, "tx-1").account_name == "Wallet"
        push(client, token, device, [
            change("transaction", "tx-1", {"syncId": "tx-1", "accountId": "acc-1",
                                           "accountName": "Cash"},
                   ledger_id="L01", updated_at=iso(base + timedelta(seconds=2))),
        ])
        acc = db_rows(sf, UserAccountProjection, sync_id="acc-1")[0]
        row = tx_projection(sf, "tx-1")
        assert row.account_name == acc.name, (
            "// ADVERSE FINDING: 陈旧交易推送把 tx.account_name 写回旧值 —— "
            f"tx.account_name={row.account_name!r} vs account.name={acc.name!r}"
        )
    finally:
        teardown()


def test_new_tx_with_stale_name_same_batch_as_rename_drifts():
    """ADVERSE FINDING(中危):同批 [改名, 用旧名新建的交易] —— 新交易落旧名。

    `_emit_user_global_cascade_tx_changes` 只按「当前投影里引用该 sync_id 的行」
    补发/刷新;同批**之后**才插入的新 tx 不在其点查快照内,其 payload 里的旧名
    原样落库 → 新建交易显示旧分类名(用户刚改名却仍看到旧名)。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c5@adv.test", "d-c5")
        base = now_utc()
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Food",
                                         "kind": "expense"}, updated_at=iso(base)),
        ])
        res = push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Meals",
                                         "kind": "expense"},
                   updated_at=iso(base + timedelta(seconds=1))),
            change("transaction", "tx-new", {"syncId": "tx-new", "type": "expense",
                                             "amount": 5, "happenedAt": iso(),
                                             "categoryId": "cat-1",
                                             "categoryName": "Food",
                                             "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base + timedelta(seconds=1))),
        ])
        assert res.json()["accepted"] == 2, res.json()
        row = tx_projection(sf, "tx-new")
        cat = db_rows(sf, UserCategoryProjection, sync_id="cat-1")[0]
        assert row.category_name == cat.name, (
            "// ADVERSE FINDING: 同批 rename 之后新建的交易沿用旧名 —— "
            f"tx.category_name={row.category_name!r} vs category.name={cat.name!r}"
        )
    finally:
        teardown()


def test_tag_delete_detaches_references_from_projection():
    """tag 删除:投影的 tags_csv / tag_sync_ids_json 引用必须被剥离。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c6@adv.test", "d-c6")
        base = now_utc()
        push(client, token, device, [
            change("tag", "tag-1", {"syncId": "tag-1", "name": "Travel",
                                    "color": "#fff"}, updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "tags": "Travel", "tagIds": ["tag-1"]},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        push(client, token, device, [
            change("tag", "tag-1", {}, action="delete",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        row = tx_projection(sf, "tx-1")
        assert row.tags_csv is None, f"tags_csv 残留: {row.tags_csv!r}"
        assert row.tag_sync_ids_json is None, f"tag_ids 残留: {row.tag_sync_ids_json!r}"
        assert db_rows(sf, UserTagProjection, sync_id="tag-1") == []
    finally:
        teardown()


def test_stale_tx_push_after_tag_delete_resurrects_dangling_tag_ref():
    """ADVERSE FINDING(中危):tag 删除后,离线设备推带该 tag 的交易 →
    悬挂 tag 引用被写回投影(且 tag 实体已不存在 → 永久孤儿)。

    src/sync_applier.py:456-476 `_delete_user_tag` 只在 delete 时剥离一次;
    后续 tx upsert 的 payload 若仍带 `tags`/`tagIds`,`merge_with_existing`
    会照原样写回(merge 只补 None,不校验引用有效性)。web 交易列表显示一个
    在标签列表里已不存在的标签名。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c7@adv.test", "d-c7")
        base = now_utc()
        push(client, token, device, [
            change("tag", "tag-1", {"syncId": "tag-1", "name": "Travel",
                                    "color": "#fff"}, updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "tags": "Travel", "tagIds": ["tag-1"]},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        push(client, token, device, [
            change("tag", "tag-1", {}, action="delete",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        # 离线设备(不知 tag 已删)推旧版交易
        push(client, token, device, [
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "tags": "Travel", "tagIds": ["tag-1"]},
                   ledger_id="L01", updated_at=iso(base + timedelta(seconds=2))),
        ])
        row = tx_projection(sf, "tx-1")
        tag_exists = bool(db_rows(sf, UserTagProjection, sync_id="tag-1"))
        assert not (row.tag_sync_ids_json and not tag_exists), (
            "// ADVERSE FINDING: tag 删除后陈旧交易推送复活悬挂引用 —— "
            f"tag_sync_ids_json={row.tag_sync_ids_json!r} 但 tag 行已删除"
        )
    finally:
        teardown()


def test_rename_cascade_idempotent_repeated_renames():
    """多轮改名:投影每轮都被拉到最新名(cascade 幂等纠正)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c8@adv.test", "d-c8")
        base = _seed_category_and_tx(client, token, device)
        for i, name in enumerate(["A", "B", "C", "D"], start=1):
            push(client, token, device, [
                change("category", "cat-1", {"syncId": "cat-1", "name": name,
                                             "kind": "expense"},
                       updated_at=iso(base + timedelta(seconds=i))),
            ])
            assert tx_projection(sf, "tx-1").category_name == name, (
                f"第 {i} 轮改名后投影未跟上"
            )
    finally:
        teardown()


def test_rename_cascade_does_not_cross_ledger_boundary_by_name():
    """cascade 按 sync_id 匹配:同名不同 sync_id 的交易不受影响(避免误伤)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "c9@adv.test", "d-c9")
        base = now_utc()
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Food",
                                         "kind": "expense"}, updated_at=iso(base)),
            change("category", "cat-2", {"syncId": "cat-2", "name": "Food",
                                         "kind": "expense"}, updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 1, "happenedAt": iso(),
                                           "categoryId": "cat-1", "categoryName": "Food",
                                           "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base)),
            change("transaction", "tx-2", {"syncId": "tx-2", "type": "expense",
                                           "amount": 2, "happenedAt": iso(),
                                           "categoryId": "cat-2", "categoryName": "Food",
                                           "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Meals",
                                         "kind": "expense"},
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        assert tx_projection(sf, "tx-1").category_name == "Meals"
        assert tx_projection(sf, "tx-2").category_name == "Food", (
            "同名但不同 sync_id 的分类不应被误伤(sync_id 谓词契约)"
        )
    finally:
        teardown()


# =========================================================================== #
# 2. 双路径行为一致性(push vs web write)                                        #
# =========================================================================== #

def test_push_and_web_path_delete_category_with_linked_tx_diverge():
    """ADVERSE FINDING(中危):同一操作(删被交易引用的分类)两条路径语义相反。

    - **push 路径**:`sync_applier._delete_user_category`(src/sync_applier.py:303)
      无关联校验,直接删分类行;引用它的交易保留悬挂 `category_sync_id`
      (web 交易列表显示旧分类名,分类列表已无该分类)。
    - **web 路径**:`snapshot_mutator.delete_category`(src/snapshot_mutator.py:706-750)
      + endpoints 的家族校验 → 返回 400 "category has N transactions"。

    SYNC_ARCHITECTURE §4.4 只规定 cascade 怎么刷 denorm,未规定删除前引用校验
    的双路径一致性;account 侧 push 路径有校验(`_delete_user_account`),
    category 侧没有 —— 三处(account/category/tag)策略不统一。
    """
    client, sf = make_client()
    try:
        # push 路径
        token, device, _ = register_login(client, "d1@adv.test", "d-d1")
        web_token, _, _ = register_login(client, "d1@adv.test", "dev-web", "web")
        base = now_utc()
        push(client, token, device, [
            change("category", "cat-p", {"syncId": "cat-p", "name": "Food2",
                                         "kind": "expense"}, updated_at=iso(base)),
            change("transaction", "tx-p", {"syncId": "tx-p", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "categoryId": "cat-p",
                                           "categoryName": "Food2",
                                           "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        res = push(client, token, device, [
            change("category", "cat-p", {}, action="delete",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        push_deleted = res.json()["accepted"] == 1 and res.json()["failed_count"] == 0
        push_dangling = tx_projection(sf, "tx-p").category_sync_id == "cat-p"

        # web 路径(等价操作)
        web_create_ledger(client, web_token, "W01")
        cat_res = web_create_category(client, web_token, "W01", "Veg")
        cat_id = cat_res.json()["entity_id"]
        web_create_tx(client, web_token, "W01", 7, category_id=cat_id,
                      category_name="Veg", category_kind="expense")
        del_res = client.request("DELETE", f"/api/v1/write/ledgers/W01/categories/{cat_id}",
                                 headers=auth_headers(web_token),
                                 json={"base_change_id": 0})

        # 期望:两条路径行为一致(要么都拒绝、要么都同样留下悬挂引用)
        diverged = push_deleted and push_dangling and del_res.status_code == 400
        assert not diverged, (
            "// ADVERSE FINDING: 同一「删被引用的分类」操作两条路径语义相反 —— "
            f"push 路径静默成功并留下悬挂引用(dangling={push_dangling}),"
            f"web 路径拒绝(HTTP {del_res.status_code})。"
            "sync_applier._delete_user_category(src/sync_applier.py:303) 无关联校验,"
            "web 快路径的 _cascade_items_for_category_delete + mutator 家族校验拦截。"
            "对照:account 侧 push 路径**有**校验(_delete_user_account:419)。"
        )
    finally:
        teardown()


def test_push_and_web_path_category_rename_both_refresh_projection():
    """双路径 rename 一致性:两条路径都刷新投影 denorm(不出现路径差异)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d2@adv.test", "d-d2")
        web_token, _, _ = register_login(client, "d2@adv.test", "dev-web", "web")
        base = _seed_category_and_tx(client, token, device)
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "PushName",
                                         "kind": "expense"},
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        assert tx_projection(sf, "tx-1").category_name == "PushName"

        # web 路径 rename 同一个分类
        res = client.patch("/api/v1/write/ledgers/L01/categories/cat-1",
                           json={"base_change_id": 0, "name": "WebName"},
                           headers=auth_headers(web_token))
        assert res.status_code == 200, res.text
        assert tx_projection(sf, "tx-1").category_name == "WebName", (
            "web 路径 rename 也必须刷新投影(双路径 cascade 一致性)"
        )
    finally:
        teardown()


# =========================================================================== #
# 3. 投影 ↔ 事件重放一致性                                                      #
# =========================================================================== #

def test_projection_matches_replay_after_lifecycle_ops():
    """create → update → delete → revive → purge 全生命周期后:
    read 投影与事件重放(mobile 语义)一致。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d3@adv.test", "d-d3")
        web_token, _, _ = register_login(client, "d3@adv.test", "dev-web", "web")
        base = now_utc()
        push(client, token, device, [tx_change("tx-1", amount=10, ts=iso(base))])
        push(client, token, device, [tx_change("tx-1", amount=20,
                                               ts=iso(base + timedelta(seconds=1)))])
        push(client, token, device, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=2))),
        ])
        # revive(更晚的 upsert)
        push(client, token, device, [tx_change("tx-1", amount=30,
                                               ts=iso(base + timedelta(seconds=3)))])
        # purge(物理删 + compact upsert 历史)
        res = client.post("/api/v1/read/workspace/trash/tx-1/purge",
                          headers=auth_headers(web_token))
        # 已复活 → 不在回收站 → 404(不是缺陷,只是确认清理语义)
        assert res.status_code in (200, 404), res.text

        visible = read_txs(client, web_token, "L01")
        replay = replay_projection_state(sync_changes(sf, entity_type="transaction"))
        visible_ids = {t["id"] for t in visible}
        assert visible_ids == set(replay.keys()), (
            f"投影 {visible_ids} vs 事件重放 {set(replay.keys())} 不一致"
        )
        for t in visible:
            assert replay[t["id"]]["amount"] == t["amount"], (t, replay[t["id"]])
    finally:
        teardown()


def test_projection_matches_replay_with_interleaved_entities():
    """混合实体(account/category/tag/budget/adjustment)交错操作后投影与重放一致。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d4@adv.test", "d-d4")
        web_token, _, _ = register_login(client, "d4@adv.test", "dev-web", "web")
        base = now_utc()
        push(client, token, device, [
            change("account", "acc-1", {"syncId": "acc-1", "name": "Cash",
                                        "type": "cash", "currency": "CNY"},
                   updated_at=iso(base)),
            change("category", "cat-1", {"syncId": "cat-1", "name": "Food",
                                         "kind": "expense"}, updated_at=iso(base)),
            change("budget", "bud-1", {"syncId": "bud-1", "type": "total",
                                       "amount": 500, "period": "monthly",
                                       "startDay": 1, "enabled": True},
                   ledger_id="L01", updated_at=iso(base)),
            tx_change("tx-1", amount=10, ts=iso(base), accountId="acc-1",
                      accountName="Cash", categoryId="cat-1", categoryName="Food",
                      categoryKind="expense"),
            change("account_adjustment", "adj-1", {"syncId": "adj-1",
                                                   "accountId": "acc-1",
                                                   "accountName": "Cash",
                                                   "amount": 100,
                                                   "balanceBefore": 0,
                                                   "balanceAfter": 100,
                                                   "happenedAt": iso()},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        # 交错:删 category(会留下悬挂引用)、删 budget、改 account 名
        push(client, token, device, [
            change("budget", "bud-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=1))),
            change("account", "acc-1", {"syncId": "acc-1", "name": "Wallet",
                                        "type": "cash", "currency": "CNY"},
                   updated_at=iso(base + timedelta(seconds=1))),
        ])

        visible = read_txs(client, web_token, "L01")
        replay = replay_projection_state(sync_changes(sf, entity_type="transaction"))
        assert {t["id"] for t in visible} == set(replay.keys())
        # 账户改名后 tx denorm 已刷
        assert visible[0]["account_name"] == "Wallet"
        # budget 已删
        budgets = client.get("/api/v1/read/ledgers/L01/budgets",
                            headers=auth_headers(web_token)).json()
        assert budgets == [], budgets
        # adjustment 的 account_name 也随 rename cascade 刷新
        adjs = db_rows(sf, __import__("src.models", fromlist=["x"]).ReadAccountAdjustmentProjection)
        assert adjs and adjs[0].account_name == "Wallet", adjs
    finally:
        teardown()


def test_full_snapshot_absent_when_ledger_has_no_changes():
    """空账本 / 无 change 的账本:/sync/full 返回 snapshot=None(不炸)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d5@adv.test", "d-d5")
        push(client, token, device, [tx_change("tx-1", amount=1)])
        res = client.get("/api/v1/sync/full?ledger_id=L01",
                        headers=auth_headers(token, device))
        assert res.status_code == 200
        assert res.json()["snapshot"] is not None
        res = client.get("/api/v1/sync/full?ledger_id=NO-SUCH",
                        headers=auth_headers(token, device))
        assert res.status_code == 200
        assert res.json()["snapshot"] is None
    finally:
        teardown()


def test_soft_deleted_tx_absent_from_full_snapshot_and_pull_has_tombstone():
    """软删交易:不出现在 /sync/full(避免重建),但 pull 事件流里有 delete 墓碑。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d6@adv.test", "d-d6")
        base = now_utc()
        push(client, token, device, [tx_change("tx-1", amount=10, ts=iso(base))])
        push(client, token, device, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        full = client.get("/api/v1/sync/full?ledger_id=L01",
                         headers=auth_headers(token, device)).json()
        import json as _json
        content = _json.loads(full["snapshot"]["payload"]["content"])
        assert content["items"] == [], content

        pull = client.get("/api/v1/sync/pull?since=0&limit=50",
                         headers=auth_headers(token, device)).json()
        actions = [(c["entity_sync_id"], c["action"]) for c in pull["changes"]
                   if c["entity_type"] == "transaction"]
        assert ("tx-1", "delete") in actions, actions
    finally:
        teardown()


# =========================================================================== #
# 4. pull 增量边界                                                              #
# =========================================================================== #

def test_pull_cursor_boundaries_exact_last_max_negative_nonnum():
    """pull 边界:since == 最后一条 / 极大 / 负数 / 非数字。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d7@adv.test", "d-d7")
        base = now_utc()
        push(client, token, device, [
            tx_change(f"tx-{i}", amount=i, ts=iso(base + timedelta(microseconds=i)))
            for i in range(3)
        ])
        hdr = auth_headers(token, device)

        # since == 最后一条 → 空,has_more False
        res = client.get("/api/v1/sync/pull?since=3&limit=10", headers=hdr)
        body = res.json()
        assert body["changes"] == [] and body["has_more"] is False
        assert body["server_cursor"] == 3, body

        # since == 倒数第二条 → 只返回最后一条
        res = client.get("/api/v1/sync/pull?since=2&limit=10", headers=hdr)
        assert [c["change_id"] for c in res.json()["changes"]] == [3]

        # 极大 → 空
        res = client.get(f"/api/v1/sync/pull?since={2**63 - 1}&limit=10", headers=hdr)
        assert res.status_code == 200 and res.json()["changes"] == []

        # 负数 → 422(ge=0)
        assert client.get("/api/v1/sync/pull?since=-1&limit=10", headers=hdr).status_code == 422
        # 非数字 → 422
        assert client.get("/api/v1/sync/pull?since=abc&limit=10", headers=hdr).status_code == 422
        # limit 越界 → 422
        assert client.get("/api/v1/sync/pull?since=0&limit=0", headers=hdr).status_code == 422
        assert client.get("/api/v1/sync/pull?since=0&limit=5001", headers=hdr).status_code == 422
    finally:
        teardown()


def test_pull_has_more_and_cursor_pagination_no_gap():
    """limit 分页:server_cursor 推进无跳号、无重复、has_more 语义正确。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d8@adv.test", "d-d8")
        base = now_utc()
        push(client, token, device, [
            tx_change(f"tx-{i}", amount=i, ts=iso(base + timedelta(microseconds=i)))
            for i in range(5)
        ])
        hdr = auth_headers(token, device)
        seen: list[int] = []
        cursor = 0
        for _ in range(10):
            body = client.get(f"/api/v1/sync/pull?since={cursor}&limit=2",
                            headers=hdr).json()
            seen.extend(c["change_id"] for c in body["changes"])
            if not body["has_more"]:
                break
            cursor = body["server_cursor"]
        assert seen == [1, 2, 3, 4, 5], f"分页丢包/重复: {seen}"
    finally:
        teardown()


def test_pull_cursor_ahead_of_server_returns_empty_not_error():
    """客户端 cursor 超过服务端已知最大值(备份恢复回滚/客户端漂移):
    pull 返回空且不报错(不会静默重放全部历史)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d9@adv.test", "d-d9")
        push(client, token, device, [tx_change("tx-1", amount=1)])
        db = sync_changes(sf)
        max_id = max(c.change_id for c in db)
        res = client.get(f"/api/v1/sync/pull?since={max_id + 1000}&limit=10",
                        headers=auth_headers(token, device))
        assert res.status_code == 200
        body = res.json()
        assert body["changes"] == []
        assert body["server_cursor"] == max_id + 1000, (
            "cursor 超出时必须原样回带(客户端据此判断是否需要 fullPush)"
        )
    finally:
        teardown()


def test_pull_excludes_own_device_changes_but_includes_others():
    """pull 按 `device_id` query 参数过滤本机变更(sync/pull 的 device_id 是
    Query 而非 header!);不带该参数时不过滤(web / catch-up 语义)。"""
    client, sf = make_client()
    try:
        token_a, device_a, _ = register_login(client, "d10@adv.test", "dev-a")
        token_b, device_b, _ = register_login(client, "d10@adv.test", "dev-b")
        assert device_a != device_b, "同用户两台设备必须是不同 device id"
        push(client, token_a, device_a, [tx_change("tx-a1", amount=1)])
        push(client, token_b, device_b, [tx_change("tx-b1", amount=2)])

        body = client.get(
            f"/api/v1/sync/pull?since=0&limit=50&device_id={device_a}",
            headers=auth_headers(token_a),
        ).json()
        ids = {c["entity_sync_id"] for c in body["changes"]}
        assert "tx-a1" not in ids, f"本机变更不应被拉回: {ids}"
        assert "tx-b1" in ids, f"他机变更必须拉到: {ids}"

        # 不带 device_id → 不做本机过滤
        body_nod = client.get("/api/v1/sync/pull?since=0&limit=50",
                              headers=auth_headers(token_a)).json()
        ids_nod = {c["entity_sync_id"] for c in body_nod["changes"]}
        assert {"tx-a1", "tx-b1"} <= ids_nod, ids_nod
    finally:
        teardown()


def test_pull_user_global_scope_isolated_between_users():
    """__user_global__ 通道:scope='user' 行只返回 `user_id == caller` 的,
    绝不泄露其他用户的 user-global 资源;同用户另一设备可见(专有通道语义)。"""
    client, sf = make_client()
    try:
        token_a, device_a, _ = register_login(client, "d11a@adv.test", "dev-a")
        token_b, device_b, _ = register_login(client, "d11b@adv.test", "dev-b")
        push(client, token_a, device_a, [
            change("account", "acc-a", {"syncId": "acc-a", "name": "A"}),
        ])
        push(client, token_b, device_b, [
            change("account", "acc-b", {"syncId": "acc-b", "name": "B"}),
        ])

        # A 用户(不带 device 过滤)只看到自己的 acc-a,sentinel ledger_id
        body = client.get("/api/v1/sync/pull?since=0&limit=50",
                          headers=auth_headers(token_a)).json()
        scoped = [(c["entity_sync_id"], c["scope"], c["ledger_id"])
                  for c in body["changes"] if c["entity_type"] == "account"]
        assert scoped == [("acc-a", "user", "__user_global__")], (
            f"user-scope 隔离失效(应只见自己的 acc-a + sentinel): {scoped}"
        )

        # 同用户第二台设备也能拉到(用户通道,不依赖发起设备)
        token_a2, device_a2, _ = register_login(client, "d11a@adv.test", "dev-a2")
        body2 = client.get(
            f"/api/v1/sync/pull?since=0&limit=50&device_id={device_a2}",
            headers=auth_headers(token_a2),
        ).json()
        scoped2 = [(c["entity_sync_id"], c["ledger_id"]) for c in body2["changes"]
                   if c["entity_type"] == "account"]
        assert ("acc-a", "__user_global__") in scoped2, scoped2
    finally:
        teardown()


def test_pull_enrichment_fills_actor_fields_for_tx():
    """pull 的 transaction payload 必须补全 createdByUserId/updatedByUserId
    (老 SyncChange 行缺这些字段时从投影回填)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d12@adv.test", "dev-a")
        push(client, token, device, [tx_change("tx-1", amount=1)])
        # 手动清掉 payload 里的 actor 字段(模拟 push 修复前的老行)
        with sf() as db:
            row = db.scalar(select(SyncChange).where(SyncChange.entity_sync_id == "tx-1"))
            payload = dict(row.payload_json)
            payload.pop("createdByUserId", None)
            payload.pop("updatedByUserId", None)
            row.payload_json = payload
            db.commit()

        token_other, device_other, user_other = register_login(client, "d12b@adv.test", "dev-b")
        # 用一个能看见该账本的用户?不行 —— 需要同用户另一设备
        token2, device2, _ = register_login(client, "d12@adv.test", "dev-a2")
        body = client.get("/api/v1/sync/pull?since=0&limit=50",
                         headers=auth_headers(token2, device2)).json()
        tx_change_out = [c for c in body["changes"] if c["entity_type"] == "transaction"]
        assert tx_change_out, body
        payload = tx_change_out[0]["payload"]
        assert payload.get("createdByUserId"), f"enrichment 缺失: {payload}"
        assert payload.get("updatedByUserId"), f"enrichment 缺失: {payload}"
    finally:
        teardown()


def test_projection_source_change_id_tracks_latest_upsert():
    """投影行的 source_change_id 必须指向最后一次 apply 的事件(诊断列正确性)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "d13@adv.test", "d-d13")
        base = now_utc()
        push(client, token, device, [tx_change("tx-1", amount=10, ts=iso(base))])
        first = tx_projection(sf, "tx-1").source_change_id
        push(client, token, device, [tx_change("tx-1", amount=20,
                                               ts=iso(base + timedelta(seconds=1)))])
        second = tx_projection(sf, "tx-1").source_change_id
        assert second > first, (first, second)
        latest = max(c.change_id for c in sync_changes(sf, entity_sync_id="tx-1"))
        assert second == latest, (second, latest)
    finally:
        teardown()


def test_projection_row_user_id_is_ledger_owner_denorm():
    """投影行 user_id = ledger owner(denorm),不随操作者变(共享账本前提)。"""
    client, sf = make_client()
    try:
        token, device, user_id = register_login(client, "d14@adv.test", "d-d14")
        push(client, token, device, [tx_change("tx-1", amount=1)])
        internal = ledger_internal_id(sf, "L01")
        row = tx_projection(sf, "tx-1")
        assert row.user_id == user_id, (row.user_id, user_id)
        assert row.ledger_id == internal
    finally:
        teardown()
