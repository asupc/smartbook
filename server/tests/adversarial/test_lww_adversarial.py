"""对抗性测试:LWW 决胜 / 幂等分支 / 时钟偏移(clamp)语义。

契约参照 docs/SYNC_ARCHITECTURE.md §4.2(LWW + clamp)、§4.8(软删 × LWW
复活语义)、§4.4(rename cascade)。

核心发现方向:`(updated_at, device_id)` 元组被同时当作**幂等键**使用,
replay 分支不比对 action / payload —— 任何同 device 同 ts 的**不同**逻辑变更
都会被当成重放静默丢弃(同时 accepted 计数照加,客户端以为成功)。
"""
from __future__ import annotations

from datetime import timedelta

from _adv_helpers import (
    ReadTxProjection,
    SyncChange,
    change,
    iso,
    make_client,
    now_utc,
    push,
    register_login,
    sync_changes,
    teardown,
    tx_change,
    tx_projection,
)


# =========================================================================== #
# 1. replay 分支不比对 action / payload(根因)                                  #
# =========================================================================== #

def test_same_tuple_different_payload_cross_request_is_lost():
    """ADVERSE FINDING:同 device 同 updated_at 的**不同 payload** 被判为幂等重放,
    静默丢弃 + accepted 计数照加。

    src/routers/sync/push.py:515-526 —— `existing_tuple == incoming_tuple` 即
    `continue`(跳过 apply),分支内不比较 action、不比较 payload。客户端拿
    200/accepted 认为写入成功,实际服务端与 web 都停留在旧值。
    这是「同毫秒编辑」的真实可达路径:mobile 用 change.createdAt 当 updated_at
    (client/lib/cloud/sync/sync_engine.dart:837),离线期间同一实体被编辑两次
    若落在同一微秒/毫秒(或时钟被 clamp 到同一值,见本节后面的 finding),
    第二次永久丢失。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l1@adv.test", "d-l1")
        # 窗口内 ts(不触发 clamp),且两次用**同一个字符串** → 元组必然相等
        ts = iso(now_utc() + timedelta(seconds=1))
        push(client, token, device, [tx_change("tx-1", amount=11, ts=ts)])
        # 跨请求:同 ts、同 device,但 payload 不同(金额 12)
        res = push(client, token, device, [tx_change("tx-1", amount=12, ts=ts)])
        assert res.status_code == 200, res.text
        body = res.json()
        # 客户端视角:1 accepted → 它认为 12 已生效
        assert body["accepted"] == 1, body
        assert tx_projection(sf, "tx-1").amount == 12.0, (
            "// ADVERSE FINDING: 同 (updated_at, device_id) 的不同 payload "
            "被当成重放丢弃 —— replay 分支不比对 action/payload"
            f"(实际 amount={tx_projection(sf, 'tx-1').amount})"
        )
    finally:
        teardown()


def test_same_tuple_delete_after_upsert_is_swallowed():
    """ADVERSE FINDING:同 (updated_at, device_id) 的 create 后 delete —— delete
    被判为 upsert 的重放而丢弃,交易在服务端/web 继续可见(客户端本地已删 →
    幽灵交易)。

    src/routers/sync/push.py:515 判重放时 action 不参与比较;upsert 与 delete
    共用 (updated_at, device_id) 元组 → delete 被吞。修复方向:重放判定必须
    同时比对 action(或引入 change 级序列号)。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l2@adv.test", "d-l2")
        ts = iso(now_utc() + timedelta(seconds=1))  # 窗口内,无 clamp 漂移
        push(client, token, device, [tx_change("tx-del", amount=10, ts=ts)])
        res = push(client, token, device, [
            change("transaction", "tx-del", {}, action="delete", ledger_id="L01",
                   updated_at=ts),
        ])
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 1, res.json()

        row = tx_projection(sf, "tx-del")
        assert row is not None and row.deleted_at is not None, (
            "// ADVERSE FINDING: 同 ts 的 delete 被当作 upsert 的幂等重放丢弃 —— "
            f"交易仍可见(deleted_at={row.deleted_at if row else 'ROW GONE'}),"
            "客户端已本地删除 → 幽灵交易"
        )
    finally:
        teardown()


def test_replay_verification_ignores_payload_by_design_probe():
    """根因探针:窗口内同 ts 的 upsert 重推**完全相同** payload 才是合法 replay;
    当前实现无法区分「同 payload」与「同 ts 不同 payload」。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l3@adv.test", "d-l3")
        ts = iso(now_utc() + timedelta(seconds=1))
        batch = [tx_change("tx-idem", amount=42, ts=ts)]
        assert push(client, token, device, batch).json()["accepted"] == 1
        assert push(client, token, device, batch).json()["accepted"] == 1
        assert push(client, token, device, batch).json()["accepted"] == 1
        assert len(sync_changes(sf, entity_type="transaction",
                                entity_sync_id="tx-idem")) == 1
    finally:
        teardown()


def test_future_ts_retry_breaks_idempotency_duplicate_events():
    """ADVERSE FINDING:时钟超前(>5s)的 change 被 clamp 到「本次请求的
    now+5s」——天花板随服务器时钟漂移,于是**同一批重试**每次都落成新事件行,
    幂等保证失效(SYNC_ARCHITECTURE §4.2「同 (updated_at, device_id) 重推 =
    幂等回放」不成立)。

    src/routers/sync/push.py:422-424:max_allowed = now + 5s,`now` 每次请求
    重新取值。数据最终收敛(投影 amount 正确),但事件流按重试次数线性膨胀,
    且 pull 端会反复 apply 同一 payload。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l3b@adv.test", "d-l3b")
        ts = iso(now_utc() + timedelta(seconds=3600))  # 远超 5s 窗口
        batch = [tx_change("tx-fut", amount=42, ts=ts)]
        for _ in range(3):
            res = push(client, token, device, batch)
            assert res.status_code == 200
            assert res.json()["accepted"] == 1, res.json()

        rows = sync_changes(sf, entity_type="transaction", entity_sync_id="tx-fut")
        assert len(rows) == 1, (
            "// ADVERSE FINDING: 未来时间戳被 clamp 到漂移的天花板 → 同批重试"
            f"产生 {len(rows)} 条重复事件行(幂等失效);投影虽收敛,事件流无界膨胀"
        )
    finally:
        teardown()


# =========================================================================== #
# 2. 同批内 rename cascade 抢占 tx 的 LWW 槽位(高危丢失更新)                      #
# =========================================================================== #

def test_cascade_fanout_swallows_same_batch_client_tx_edit():
    """ADVERSE FINDING(高危):同批 [类目改名, 该改名影响到的交易编辑] 且**时间戳
    相同时**,交易的编辑被 cascade 补发事件抢占 LWW 槽位后当成重放丢弃。

    机制:push 循环先处理 category rename → `_emit_user_global_cascade_tx_changes`
    (src/routers/sync/push.py:50-103,调用点 :606) 以 `updated_at=rename 的
    incoming_updated_at` bulk insert 一条 cascade-only tx upsert(:94)。等
    循环走到批内**同一条 tx 的客户端编辑**时,latest change 的
    (updated_at, device_id) 与它完全相同 → 命中 :515 的 replay 分支 →
    `continue`(:526),客户端 payload 从未 apply。

    结果三端分裂:服务端投影 amount=10(旧值)、事件流只有 cascade 版 payload、
    而 push 响应 accepted=2 —— 客户端以为编辑成功。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l4@adv.test", "d-l4")
        base = now_utc()
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Food",
                                         "kind": "expense"}, updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "categoryId": "cat-1", "categoryName": "Food",
                                           "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        ts = iso(base + timedelta(seconds=3))  # 窗口内,无 clamp 漂移
        res = push(client, token, device, [
            # rename
            change("category", "cat-1", {"syncId": "cat-1", "name": "Meals",
                                         "kind": "expense"}, updated_at=ts),
            # 同批、同 ts 的 tx 编辑(金额 555)
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 555, "happenedAt": iso(),
                                           "categoryId": "cat-1", "categoryName": "Meals",
                                           "categoryKind": "expense"},
                   ledger_id="L01", updated_at=ts),
        ])
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 2, res.json()

        row = tx_projection(sf, "tx-1")
        assert row.amount == 555.0, (
            "// ADVERSE FINDING: 同批 rename cascade 以相同 (updated_at, device) 补发"
            " tx 事件,抢占 LWW 槽位后客户端编辑命中 replay 分支被丢弃;"
            f"投影残留 amount={row.amount}(客户端已 accepted=2)"
        )
    finally:
        teardown()


def test_cascade_event_does_not_block_later_batch_edit():
    """对照组:下一批(ts 更大)的编辑正常生效 —— 证明丢失是「同 ts」特定窗口。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l5@adv.test", "d-l5")
        base = now_utc()
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Food",
                                         "kind": "expense"}, updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "categoryId": "cat-1", "categoryName": "Food",
                                           "categoryKind": "expense"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        ts = iso(base + timedelta(seconds=3))  # 窗口内,无 clamp 漂移
        push(client, token, device, [
            change("category", "cat-1", {"syncId": "cat-1", "name": "Meals",
                                         "kind": "expense"}, updated_at=ts),
        ])
        # 更晚的独立编辑
        res = push(client, token, device, [
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 777, "happenedAt": iso()},
                   ledger_id="L01", updated_at=iso(base + timedelta(seconds=4))),
        ])
        assert res.json()["accepted"] == 1, res.json()
        assert tx_projection(sf, "tx-1").amount == 777.0
    finally:
        teardown()


# =========================================================================== #
# 3. 时钟偏移 clamp 造成的同批坍缩(丢失更新)                                     #
# =========================================================================== #

def test_clock_skew_single_batch_multi_edit_same_entity_collapses():
    """ADVERSE FINDING:时钟超前的设备在**一个批**里对同一实体多次编辑时,
    所有 change 的 updated_at 被 clamp 到同一个 (server_now+5s) →
    只有第一条 apply,后续命中 replay 分支被丢弃,但 accepted=N(客户端误认为全部成功)。

    机制:src/routers/sync/push.py:422-424 对每条 change 独立
    `min(raw, now+5s)` —— 超前时钟的多个递增时间戳坍缩成同一值;
    再叠加 :515 的 replay 判定 → 后续变更全部静默丢失。
    客户端最终 edit 丢失(amount=1 而非 3),且响应无任何 conflict/failed 信号。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l6@adv.test", "d-l6")
        res = push(client, token, device, [
            tx_change("tx-1", amount=1, ts="2100-01-01T00:00:00+00:00"),
            tx_change("tx-1", amount=2, ts="2100-01-01T00:00:05+00:00"),
            tx_change("tx-1", amount=3, ts="2100-01-01T00:00:10+00:00"),
        ])
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 3, res.json()
        assert res.json()["rejected"] == 0, res.json()

        row = tx_projection(sf, "tx-1")
        assert row.amount == 3.0, (
            "// ADVERSE FINDING: 时钟超前 + 同批同实体多编辑 → clamp 坍缩成同 ts,"
            "后续编辑被当重放丢弃(响应 accepted=3 无任何告警);"
            f"投影 amount={row.amount},客户端最后编辑=3"
        )
    finally:
        teardown()


def test_clock_skew_distinct_entities_all_apply():
    """对照:时钟超前的同批**不同实体** → 各自 clamp 但互不冲突,全部落地。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l7@adv.test", "d-l7")
        res = push(client, token, device, [
            tx_change(f"tx-{i}", amount=i, ts=f"2100-01-01T00:00:0{i}+00:00")
            for i in range(3)
        ])
        assert res.json()["accepted"] == 3, res.json()
        with sf() as db:
            from _adv_helpers import select
            amounts = sorted(r.amount for r in db.scalars(select(ReadTxProjection)).all())
        assert amounts == [0.0, 1.0, 2.0], amounts
    finally:
        teardown()


def test_clock_skew_legit_later_push_within_window_wins():
    """HARDENING:被 clamp 后,推一个**仍在 5s 窗口内**的 ts 会被拒(天花板领先),
    但推「贴近 server_now」的 ts 也只能平/输;唯一出路是等窗口过去。
    「clamp 只压制未来时间,不会永久锁死」——但存在最长 5s 的写入真空期。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l8@adv.test", "d-l8")
        push(client, token, device, [
            tx_change("tx-1", amount=1, ts="9999-12-31T23:59:59+00:00"),
        ])
        # clamp 天花板 = now1 + 5s;此刻 server_now+1s 仍低于天花板 → 被拒
        res = push(client, token, device, [
            tx_change("tx-1", amount=99, ts=iso(now_utc() + timedelta(seconds=1))),
        ])
        assert res.json()["rejected"] == 1, (
            "HARDENING: clamp 天花板领先当前时钟,窗口内合法写入被 LWW 拒绝"
        )
        # 协议允许的出路:客户端用同样「未来」的 ts 且值更大 → 能赢
        res = push(client, token, device, [
            tx_change("tx-1", amount=100, ts="9999-12-31T23:59:59+00:00"),
        ])
        assert res.json()["accepted"] == 1, res.json()
        # 数据本身收敛,不会永久锁死
        assert tx_projection(sf, "tx-1").amount == 100.0
    finally:
        teardown()


def test_clock_rollback_device_same_ts_uses_device_tiebreak():
    """时钟回拨设备的同 ts 重推:由 (ts, device_id) 元组决胜,不按到达顺序。"""
    client, sf = make_client()
    try:
        token_a, device_a, _ = register_login(client, "l9@adv.test", "aaa-dev")
        token_b, device_b, _ = register_login(client, "l9@adv.test", "zzz-dev")
        assert device_a < device_b
        old = iso(now_utc() - timedelta(seconds=3600))
        push(client, token_a, device_a, [tx_change("tx-1", amount=1, ts=old)])
        newer = iso(now_utc() - timedelta(seconds=3599))
        push(client, token_b, device_b, [tx_change("tx-1", amount=2, ts=newer)])
        assert tx_projection(sf, "tx-1").amount == 2.0
        # A 用同 ts 回推(device_a 更小) → 元组更小 → 被拒
        res = push(client, token_a, device_a, [tx_change("tx-1", amount=3, ts=newer)])
        assert res.json()["rejected"] == 1, (
            f"device_id tie-break 应拒绝字典序更小的设备: {res.json()}"
        )
        assert tx_projection(sf, "tx-1").amount == 2.0
    finally:
        teardown()


# =========================================================================== #
# 4. 软删 × LWW 复活语义(§4.8)                                                 #
# =========================================================================== #

def test_delete_then_older_upsert_does_not_revive():
    """§4.8:delete 之后推更旧的 upsert → LWW 在 push 层拒绝,行保持软删。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l10@adv.test", "d-l10")
        base = now_utc()
        push(client, token, device, [tx_change("tx-1", amount=10, ts=iso(base))])
        push(client, token, device, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=2))),
        ])
        res = push(client, token, device, [
            tx_change("tx-1", amount=99, ts=iso(base + timedelta(seconds=1))),
        ])
        assert res.json()["rejected"] == 1, res.json()
        assert res.json()["conflict_count"] == 1, res.json()
        row = tx_projection(sf, "tx-1")
        assert row is not None and row.deleted_at is not None, "更旧的 upsert 不得复活"
    finally:
        teardown()


def test_delete_then_newer_upsert_revives_with_full_fields():
    """§4.8:delete 之后推更晚 ts 的 upsert → 复活且内容为该 upsert 版本。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l11@adv.test", "d-l11")
        base = now_utc()
        push(client, token, device, [
            tx_change("tx-1", amount=10, ts=iso(base), note="orig", accountName="Cash",
                      accountId="acc-1"),
        ])
        push(client, token, device, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        res = push(client, token, device, [
            tx_change("tx-1", amount=20, ts=iso(base + timedelta(seconds=2)),
                      note="revived", accountName="Cash", accountId="acc-1"),
        ])
        assert res.json()["accepted"] == 1, res.json()
        row = tx_projection(sf, "tx-1")
        assert row.deleted_at is None, "更晚的 upsert 必须清软删(复活语义)"
        assert row.amount == 20.0
        assert row.note == "revived"
        assert row.account_name == "Cash" and row.account_sync_id == "acc-1", (
            "复活后字段必须完整(merge 不得丢字段)"
        )
    finally:
        teardown()


def test_delete_revive_multiple_rounds_consistent():
    """连续 delete / revive 五轮:read 投影与事件重放终态一致。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l12@adv.test", "d-l12")
        base = now_utc()
        push(client, token, device, [tx_change("tx-1", amount=0, ts=iso(base))])
        for i in range(1, 6):
            push(client, token, device, [
                change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                       updated_at=iso(base + timedelta(seconds=2 * i - 1))),
            ])
            push(client, token, device, [
                tx_change("tx-1", amount=float(i), ts=iso(base + timedelta(seconds=2 * i))),
            ])
        row = tx_projection(sf, "tx-1")
        assert row.deleted_at is None and row.amount == 5.0, (row.amount, row.deleted_at)

        # 事件重放(mobile 语义)与投影对齐
        from _adv_helpers import replay_projection_state
        state = replay_projection_state(sync_changes(sf, entity_type="transaction"))
        assert state["tx-1"]["amount"] == 5.0, state
    finally:
        teardown()


def test_purged_tombstone_still_blocks_stale_replay():
    """purge 清掉 upsert 历史后,墓碑仍占 LWW 槽位 → 陈旧设备的老版本被拒。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l13@adv.test", "d-l13")
        web_token, _, _ = register_login(client, "l13@adv.test", "dev-web", "web")
        base = now_utc()
        push(client, token, device, [tx_change("tx-1", amount=10, ts=iso(base))])
        push(client, token, device, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        res = client.post("/api/v1/read/workspace/trash/tx-1/purge",
                          headers={"Authorization": f"Bearer {web_token}"})
        assert res.status_code == 200, res.text
        # upsert 历史被 compact 掉,只剩墓碑
        actions = [c.action for c in sync_changes(sf, entity_sync_id="tx-1")]
        assert actions == ["delete"], actions

        replay = push(client, token, device, [tx_change("tx-1", amount=10, ts=iso(base))])
        assert replay.json()["rejected"] == 1, replay.json()
        assert tx_projection(sf, "tx-1") is None, "purge 后不得被陈旧重推复活"
    finally:
        teardown()


def test_soft_deleted_row_keeps_lww_slot_over_newer_upsert_from_older_device():
    """软删行 + 新 upsert:落盘版本 = (ts, device) 大者;不确定时以投影为准。"""
    client, sf = make_client()
    try:
        token_a, device_a, _ = register_login(client, "l14@adv.test", "aaa-dev")
        token_b, device_b, _ = register_login(client, "l14@adv.test", "zzz-dev")
        base = now_utc()
        push(client, token_a, device_a, [tx_change("tx-1", amount=10, ts=iso(base))])
        # A 删(ts+2);B 同时编辑(ts+3,同 device 不同 → B 胜)
        push(client, token_a, device_a, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=2))),
        ])
        res = push(client, token_b, device_b, [
            tx_change("tx-1", amount=77, ts=iso(base + timedelta(seconds=3))),
        ])
        assert res.json()["accepted"] == 1, res.json()
        row = tx_projection(sf, "tx-1")
        assert row.deleted_at is None and row.amount == 77.0, (row.amount, row.deleted_at)
    finally:
        teardown()


# =========================================================================== #
# 5. delete 事件参与同序列 LWW                                                   #
# =========================================================================== #

def test_lww_series_compares_delete_and_upsert_together():
    """delete 与 upsert 在同一 (entity_type, entity_sync_id) 序列内比较
    (delete 的 updated_at 参与,不过滤 action)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l15@adv.test", "d-l15")
        base = now_utc()
        # 先写一个"未来"的 delete(离线的另一端),再推较旧 upsert
        push(client, token, device, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=iso(base + timedelta(seconds=30))),
        ])
        res = push(client, token, device, [
            tx_change("tx-1", amount=1, ts=iso(base + timedelta(seconds=1))),
        ])
        assert res.json()["rejected"] == 1, res.json()
        # delete 先到(行不存在)→ 幂等 no-op;再推 upsert 被拒 → 该行始终不存在
        assert tx_projection(sf, "tx-1") is None

        # 更晚的 upsert 可复活
        res = push(client, token, device, [
            tx_change("tx-1", amount=2, ts=iso(base + timedelta(seconds=31))),
        ])
        assert res.json()["accepted"] == 1, res.json()
        assert tx_projection(sf, "tx-1").amount == 2.0
    finally:
        teardown()


def test_lww_tie_same_ts_same_device_different_action_keeps_first():
    """HARDENING:同 ts 同 device 的 upsert→delete→upsert 序列,
    中间 delete 被 replay 分支吞掉(见前述 finding),最终以首个 upsert 为准。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "l16@adv.test", "d-l16")
        ts = iso(now_utc() + timedelta(seconds=10))
        push(client, token, device, [tx_change("tx-1", amount=10, ts=ts)])
        push(client, token, device, [
            change("transaction", "tx-1", {}, action="delete", ledger_id="L01",
                   updated_at=ts),
        ])
        row = tx_projection(sf, "tx-1")
        # 当前行为:delete 被 replay 吞掉,行继续存活(与上一条 FINDING 同根因)
        assert row is not None and row.deleted_at is None
        assert len(sync_changes(sf, entity_sync_id="tx-1")) == 1
    finally:
        teardown()
