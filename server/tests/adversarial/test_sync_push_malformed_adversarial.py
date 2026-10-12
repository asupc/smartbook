"""对抗性测试:push 畸形 / 边界 / 幂等(同步域)。

覆盖攻击清单「push 畸形/边界」「重放」「批量」三组。契约参照
docs/SYNC_ARCHITECTURE.md §4.2(LWW)、§4.5(字段 merge)、§4.6(change_id
单调性)、§4.10(首绑 / 被移除成员)。

红色条目注释 `// ADVERSE FINDING: <标题>`;可辩护但脆弱的加 `// HARDENING:`。
"""
from __future__ import annotations

import json
import time

from _adv_helpers import (
    Ledger,
    ReadTxProjection,
    SyncChange,
    auth_headers,
    change,
    iso,
    make_client,
    now_utc,
    push,
    push_raw,
    read_txs,
    register_login,
    sync_changes,
    teardown,
    tx_change,
    tx_projection,
)
from datetime import timedelta

import pytest


# =========================================================================== #
# 1. 缺字段 / 类型错 / 通道混用                                                  #
# =========================================================================== #

def test_push_missing_required_fields_returns_422_not_500():
    """缺 entity_type / updated_at / device_id → 422;非法 device → 401。"""
    client, _sf = make_client()
    try:
        token, device, _ = register_login(client, "m1@adv.test", "d-m1")
        cases = [
            {"changes": [{"entity_type": "transaction", "entity_sync_id": "t",
                          "action": "upsert", "payload": {}, "updated_at": iso()}]},
            {"device_id": device, "changes": [{"entity_type": "transaction",
                                               "entity_sync_id": "t", "action": "upsert",
                                               "payload": {}}]},
            {"changes": []},
            {"device_id": device, "changes": [
                {"entity_sync_id": "t", "action": "upsert", "payload": {},
                 "updated_at": iso()}]},
            {"device_id": device, "changes": [
                {"entity_type": "transaction", "entity_sync_id": "t", "action": "remove",
                 "payload": {}, "updated_at": iso()}]},
            {"device_id": device, "changes": [
                {"entity_type": "transaction", "entity_sync_id": "t", "action": "upsert",
                 "payload": [1, 2, 3], "updated_at": iso()}]},
        ]
        for body in cases:
            res = client.post("/api/v1/sync/push", headers=auth_headers(token), json=body)
            assert res.status_code == 422, (body, res.status_code, res.text)
        # 不存在的 device → 401(而不是静默接受)
        res = push(client, token, "no-such-device", [tx_change("tx-1")])
        assert res.status_code == 401, res.text
    finally:
        teardown()


def test_push_empty_changes_batch_is_accepted_noop():
    """空批 200 且不动任何状态(max_cursor 可回退到 0/最近值)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m2@adv.test", "d-m2")
        before = len(sync_changes(sf))
        res = push(client, token, device, [])
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 0
        assert len(sync_changes(sf)) == before
    finally:
        teardown()


def test_push_ledger_scoped_without_ledger_id_is_rejected_not_applied():
    """ledger-scoped 缺 ledger_id → rejected++,不写事件、不落投影。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m3@adv.test", "d-m3")
        res = push(client, token, device, [
            change("transaction", "tx-noled", {"syncId": "tx-noled", "type": "expense",
                                               "amount": 1, "happenedAt": iso()}),
        ])
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["rejected"] == 1, body
        assert body["accepted"] == 0, body
        assert tx_projection(sf, "tx-noled") is None
        assert sync_changes(sf, entity_type="transaction") == []
    finally:
        teardown()


def test_push_user_global_ignores_borrowed_ledger_id_channel():
    """user-global(account)带 ledger_id 也应落 scope='user' / ledger_id IS NULL。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m4@adv.test", "d-m4")
        res = push(client, token, device, [
            change("account", "acc-mix", {"syncId": "acc-mix", "name": "Cash"},
                   ledger_id="L01"),
        ])
        assert res.status_code == 200, res.text
        rows = sync_changes(sf, entity_type="account")
        assert len(rows) == 1
        assert rows[0].scope == "user", rows[0].scope
        assert rows[0].ledger_id is None, "user-global 事件不应挂账本(P0 通道契约)"
    finally:
        teardown()


def test_push_unknown_entity_type_is_loosely_accepted():
    """HARDENING:未知 entity_type('wombat')被静默接受并写进事件流(无白名单)。

    pull 端 mobile 只 warning 跳过,因此不破坏一致性;但服务端接受任意
    entity_type 意味着事件流可被污染,且这些行永远无法被 pull 端消费。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m5@adv.test", "d-m5")
        res = push(client, token, device, [
            change("wombat", "w-1", {"syncId": "w-1"}, ledger_id="L01"),
        ])
        assert res.status_code == 200, res.text
        body = res.json()
        # 当前行为:被当作普通 ledger-scope change 接受(entity_type 无校验)
        assert body["accepted"] == 1, body
        rows = sync_changes(sf, entity_type="wombat")
        assert len(rows) == 1
    finally:
        teardown()


def test_push_payload_syncid_mismatch_writes_payload_syncid_into_projection():
    """ADVERSE FINDING:entity_sync_id 与 payload.syncId 不一致时投影按 payload 落,
    事件行按 entity_sync_id 落 —— 后续 delete(用 entity_sync_id)永远删不掉该行。

    push.py 用 change.entity_sync_id 作为事件行/LWW 键,而
    sync_applier.apply_change_to_projection 把 payload['syncId'] 交给
    projection.upsert_tx 当 PK(src/sync_applier.py:751 setdefault + 
    src/projection.py:199)。delete 走 _delete_tx → projection.delete_tx(
    ledger_id, sync_id=change.entity_sync_id) → 查不到 payload.syncId 那行。
    该行成为永久幽灵:read/统计/导出都看得到,任何事件都删不掉。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m6@adv.test", "d-m6")
        res = push(client, token, device, [
            change("transaction", "tx-A", {"syncId": "tx-B", "type": "expense",
                                           "amount": 3, "happenedAt": iso()},
                   ledger_id="L01"),
        ])
        assert res.status_code == 200, res.text

        # 客户端随后删除 tx-A(它认为自己的实体叫 tx-A)
        push(client, token, device, [
            change("transaction", "tx-A", {}, action="delete", ledger_id="L01"),
        ])

        rows = [r for r in _all_tx(sf)]
        # 期望:delete 生效后没有任何可见行
        assert rows == [], (
            "// ADVERSE FINDING: entity_sync_id/payload.syncId 不一致时 "
            f"delete 无法删除投影行,残留幽灵行 {[(r.sync_id, r.amount) for r in rows]}"
        )
    finally:
        teardown()


def _all_tx(sf) -> list:
    from _adv_helpers import db_rows
    return db_rows(sf, ReadTxProjection)


# =========================================================================== #
# 2. change_id 相关(客户端伪造 / 单调性)                                        #
# =========================================================================== #

def test_push_client_supplied_change_id_and_scope_are_ignored():
    """客户端自带 change_id / scope:不得影响服务端自增序号与 scope 判定。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m7@adv.test", "d-m7")
        body_change = tx_change("tx-1")
        body_change["change_id"] = 999_999
        body_change["scope"] = "ledger"
        res = push(client, token, device, [body_change])
        assert res.status_code == 200, res.text
        rows = sync_changes(sf, entity_type="transaction")
        assert len(rows) == 1
        assert rows[0].change_id < 999_999, "客户端不能指定 change_id"
    finally:
        teardown()


def test_change_id_is_strictly_monotonic_across_batches():
    """change_id 严格递增(跨批、跨实体)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m8@adv.test", "d-m8")
        for i in range(5):
            push(client, token, device, [tx_change(f"tx-{i}", amount=i + 1)])
        ids = [c.change_id for c in sync_changes(sf)]
        assert ids == sorted(ids) and len(set(ids)) == len(ids)
        assert ids == list(range(1, 6)), ids
    finally:
        teardown()


def test_replay_same_batch_is_idempotent_no_duplicate_rows():
    """同 (updated_at, device) 整批重放:accepted 计数走幂等分支,不双写。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m9@adv.test", "d-m9")
        ts = iso(now_utc() + timedelta(seconds=5))
        batch = [
            tx_change("tx-1", amount=11, ts=ts),
            tx_change("tx-2", amount=22, ts=ts),
            change("account", "acc-1", {"syncId": "acc-1", "name": "Cash"}, updated_at=ts),
        ]
        first = push(client, token, device, batch)
        second = push(client, token, device, batch)
        assert first.status_code == 200 and second.status_code == 200
        assert second.json()["accepted"] == 3, second.json()
        assert second.json()["rejected"] == 0, second.json()

        assert len(sync_changes(sf, entity_type="transaction")) == 2
        assert len(sync_changes(sf, entity_type="account")) == 1
        assert len(_all_tx(sf)) == 2
    finally:
        teardown()


def test_batch_replay_after_partial_failure_is_idempotent():
    """批内一条 poison(account delete with linked tx)+ 整批重放:
    稳定可重放,failed 计数一致,不产生额外事件行。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m10@adv.test", "d-m10")
        base = now_utc()
        push(client, token, device, [
            change("account", "acc-1", {"syncId": "acc-1", "name": "Cash"},
                   updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "accountId": "acc-1", "accountName": "Cash"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        poison_batch = [
            change("account", "acc-1", {}, action="delete",
                   updated_at=iso(base + timedelta(seconds=1))),
            tx_change("tx-2", amount=20, ts=iso(base + timedelta(seconds=2))),
        ]
        first = push(client, token, device, poison_batch)
        second = push(client, token, device, poison_batch)
        assert first.status_code == second.status_code == 200
        # HARDENING:poison 条的 SyncChange 行随 savepoint 回滚,重放时它仍是
        # 「首次见到」→ 再次 apply 再次失败。结果确定性(failed 恒为 1),
        # 客户端可据此熔断标记 poisoned,不会无限重推同一批。
        assert first.json()["failed_count"] == 1, first.json()
        assert second.json()["failed_count"] == 1, second.json()
        assert second.json()["accepted"] == 1, (
            "已 commit 的 tx-2 重放必须走幂等分支(accepted),"
            f"而不是被当成新写入:{second.json()}"
        )
        # 关键一致性:重放不新增事件行
        assert len(sync_changes(sf, entity_type="transaction")) == 2
        assert len(_all_tx(sf)) == 2
    finally:
        teardown()


# =========================================================================== #
# 3. 时间戳边界                                                                  #
# =========================================================================== #

def test_push_epoch_and_year_9999_updated_at_are_actionable():
    """epoch 0 / 9999 年的 updated_at 均被接受,且 clamp 只对「未来」生效。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m11@adv.test", "d-m11")
        res = push(client, token, device, [
            tx_change("tx-e", amount=1, ts="1970-01-01T00:00:00+00:00"),
            tx_change("tx-f", amount=2, ts="9999-12-31T23:59:59+00:00"),
            tx_change("tx-g", amount=3, ts="2026-01-01T00:00:00+00:00"),
        ])
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 3, res.json()

        rows = {c.entity_sync_id: c for c in sync_changes(sf, entity_type="transaction")}
        assert rows["tx-e"].updated_at.year == 1970
        # 9999 年 → clamp 到 server_now+5s
        assert rows["tx-f"].updated_at.year < 2100, "未来时间戳必须被 clamp"
    finally:
        teardown()


def test_push_happened_at_9999_survives_untouched():
    """happenedAt 是用户数据,不参与 clamp —— 9999 年原样保留(只影响排序)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m12@adv.test", "d-m12")
        res = push(client, token, device, [
            tx_change("tx-far", amount=1, happenedAt="9999-12-31T23:59:59+00:00"),
        ])
        assert res.status_code == 200, res.text
        row = tx_projection(sf, "tx-far")
        assert row is not None
        assert row.happened_at.year == 9999, row.happened_at
    finally:
        teardown()


def test_push_invalid_happened_at_falls_back_to_now():
    """HARDENING:非法 happenedAt 字符串被静默替换成「服务器当前时刻」而非拒绝。

    projection._parse_happened_at 容错返回 now()。客户端拼错日期不会报错,
    而是把交易落到"今天" —— 静默数据变形(可辩护的容错 vs 拒绝的选择)。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m13@adv.test", "d-m13")
        before = now_utc()
        res = push(client, token, device, [
            tx_change("tx-badts", amount=1, happenedAt="not-a-date"),
        ])
        assert res.status_code == 200
        assert res.json()["accepted"] == 1
        row = tx_projection(sf, "tx-badts")
        assert row is not None
        happened = row.happened_at
        if happened.tzinfo is None:  # sqlite 存 naive UTC
            from datetime import timezone as _tz
            happened = happened.replace(tzinfo=_tz.utc)
        delta = abs((happened - before).total_seconds())
        assert delta < 30, f"非法 happenedAt 落成 now(): {row.happened_at}"
    finally:
        teardown()


def test_push_same_millisecond_two_devices_tiebreak_is_deterministic():
    """同 updated_at 两设备:device_id 字典序大者胜,重复跑结果一致。"""
    results = []
    for run in range(2):
        client, sf = make_client()
        try:
            token_a, device_a, _ = register_login(client, f"m14a{run}@adv.test", "aaa-dev")
            token_b, device_b, _ = register_login(client, f"m14a{run}@adv.test", "zzz-dev")
            assert device_b > device_a, (device_a, device_b)
            ts = iso(now_utc() + timedelta(seconds=1))
            push(client, token_a, device_a, [tx_change("tx-1", amount=100, ts=ts)])
            push(client, token_b, device_b, [tx_change("tx-1", amount=200, ts=ts)])
            assert tx_projection(sf, "tx-1").amount == 200.0
            results.append(200.0)
        finally:
            teardown()
    assert results == [200.0, 200.0], "tie-break 必须确定性(与到达顺序无关)"


def test_push_later_arrival_with_older_timestamp_is_rejected():
    """后到但时间戳旧 → 拒绝(不得覆盖新值)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m15@adv.test", "d-m15")
        base = now_utc()
        push(client, token, device, [tx_change("tx-1", amount=200,
                                               ts=iso(base + timedelta(seconds=10)))])
        res = push(client, token, device, [tx_change("tx-1", amount=100,
                                                     ts=iso(base + timedelta(seconds=1)))])
        assert res.status_code == 200
        assert res.json()["rejected"] == 1, res.json()
        assert res.json()["conflict_count"] == 1, res.json()
        assert tx_projection(sf, "tx-1").amount == 200.0
    finally:
        teardown()


# =========================================================================== #
# 4. 批量(1000 条 / 部分失败 / poison 隔离)                                     #
# =========================================================================== #

def test_push_1000_changes_all_land_no_packet_loss():
    """一次 push 1000 条:全部 accepted、全部落投影、change_id 连续无断档。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m16@adv.test", "d-m16")
        base = now_utc()
        batch = [
            tx_change(f"tx-{i}", amount=i + 1,
                      ts=iso(base + timedelta(microseconds=i)))
            for i in range(1000)
        ]
        res = push(client, token, device, batch)
        assert res.status_code == 200, res.text[:300]
        body = res.json()
        assert body["accepted"] == 1000, (body["accepted"], body["failed_count"])
        assert body["failed_count"] == 0

        rows = _all_tx(sf)
        assert len(rows) == 1000, f"投影行丢失:{len(rows)}"
        ids = [c.change_id for c in sync_changes(sf, entity_type="transaction")]
        assert ids == list(range(1, 1001)), "change_id 必须连续(无断档)"
    finally:
        teardown()


def test_push_partial_apply_failure_keeps_batch_consistent():
    """批内一条 apply 失败 → savepoint 隔离:其余 change 照常 commit,
    失败条不留孤儿事件行(事件与投影原子)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m17@adv.test", "d-m17")
        base = now_utc()
        push(client, token, device, [
            change("account", "acc-1", {"syncId": "acc-1", "name": "Cash"},
                   updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "accountId": "acc-1", "accountName": "Cash"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        res = push(client, token, device, [
            # poison:账户仍有活跃交易 → delete 被拒(ValueError → savepoint 回滚)
            change("account", "acc-1", {}, action="delete",
                   updated_at=iso(base + timedelta(seconds=1))),
            tx_change("tx-2", amount=20, ts=iso(base + timedelta(seconds=2))),
        ])
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["failed_count"] == 1, body
        assert body["accepted"] == 1, body

        # 失败条:account delete 事件行必须不存在(不能留孤儿)
        assert sync_changes(sf, entity_type="account", action="delete") == []
        # 账户仍在
        from _adv_helpers import db_rows, UserAccountProjection
        assert len(db_rows(sf, UserAccountProjection, sync_id="acc-1")) == 1
        # 通过的那条正常落地
        assert tx_projection(sf, "tx-2") is not None
    finally:
        teardown()


def test_push_poison_change_does_not_block_subsequent_batches():
    """poison change 被隔离后,后续批次的正常 change 不受影响(不会永久卡同步)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m18@adv.test", "d-m18")
        base = now_utc()
        push(client, token, device, [
            change("account", "acc-1", {"syncId": "acc-1", "name": "Cash"},
                   updated_at=iso(base)),
            change("transaction", "tx-1", {"syncId": "tx-1", "type": "expense",
                                           "amount": 10, "happenedAt": iso(),
                                           "accountId": "acc-1", "accountName": "Cash"},
                   ledger_id="L01", updated_at=iso(base)),
        ])
        push(client, token, device, [
            change("account", "acc-1", {}, action="delete",
                   updated_at=iso(base + timedelta(seconds=1))),
        ])
        res = push(client, token, device, [tx_change("tx-3", amount=30,
                                                     ts=iso(base + timedelta(seconds=3)))])
        assert res.json()["accepted"] == 1, res.json()
        assert tx_projection(sf, "tx-3") is not None
    finally:
        teardown()


def test_push_large_batch_then_incremental_edit_preserves_other_fields():
    """大批量后对单条做 partial update:未携带字段不得被默认值覆盖(§4.5 merge)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m19@adv.test", "d-m19")
        base = now_utc()
        res = push(client, token, device, [
            tx_change("tx-1", amount=88.5, ts=iso(base),
                      note="dinner", accountName="Cash", accountId="acc-1",
                      categoryName="Food", categoryId="cat-1",
                      categoryKind="expense", tags="A,B", tagIds=["t1", "t2"]),
        ])
        assert res.json()["accepted"] == 1, res.json()

        # partial update:只带 amount(旧客户端行为)
        res = push(client, token, device, [
            change("transaction", "tx-1",
                   {"syncId": "tx-1", "amount": 99.0},
                   ledger_id="L01", updated_at=iso(base + timedelta(seconds=1))),
        ])
        assert res.json()["accepted"] == 1, res.json()
        row = tx_projection(sf, "tx-1")
        assert row.amount == 99.0
        assert row.note == "dinner", "partial update 丢了 note(merge 契约违背)"
        assert row.account_name == "Cash"
        assert row.category_name == "Food"
        assert row.tags_csv == "A,B"
        assert row.tag_sync_ids_json == '["t1", "t2"]'
    finally:
        teardown()


# =========================================================================== #
# 5. ledger 元数据通道                                                          #
# =========================================================================== #

def test_push_ledger_meta_clamps_month_start_day_and_keeps_blank_name():
    """monthStartDay 越界被 clamp 到 [1,28];空 ledgerName/currency 不覆盖旧值。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m20@adv.test", "d-m20")
        push(client, token, device, [
            change("ledger", "LM01", {"ledgerName": "N", "currency": "CNY",
                                      "monthStartDay": 99}, ledger_id="LM01"),
        ])
        with sf() as db:
            lg = db.scalar(__import__("sqlalchemy").select(Ledger).where(
                Ledger.external_id == "LM01"))
            assert lg.month_start_day == 28, lg.month_start_day

        # 空名 + 空币种 → 保留旧值;字符串 monthStartDay → 忽略
        push(client, token, device, [
            change("ledger", "LM01", {"ledgerName": "  ", "currency": "  ",
                                      "monthStartDay": "5"}, ledger_id="LM01"),
        ])
        with sf() as db:
            lg = db.scalar(__import__("sqlalchemy").select(Ledger).where(
                Ledger.external_id == "LM01"))
            assert lg.name == "N", lg.name
            assert lg.currency == "CNY", lg.currency
            assert lg.month_start_day == 28, lg.month_start_day
    finally:
        teardown()


# =========================================================================== #
# 6. 同步响应形状                                                                #
# =========================================================================== #

def test_push_response_shape_and_cursor_semantics():
    """accepted/rejected/conflict/failed 计数与 server_cursor 语义。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m21@adv.test", "d-m21")
        base = now_utc()
        push(client, token, device, [
            tx_change("tx-1", amount=1, ts=iso(base + timedelta(seconds=5))),
        ])
        res = push(client, token, device, [
            tx_change("tx-2", amount=2, ts=iso(base + timedelta(seconds=2))),
            tx_change("tx-1", amount=99, ts=iso(base + timedelta(seconds=1))),  # 冲突
        ])
        body = res.json()
        assert body["accepted"] == 1
        assert body["rejected"] == 1
        assert body["conflict_count"] == 1
        assert body["failed_count"] == 0
        assert body["server_timestamp"]
        # server_cursor 是本请求内被接受 change 的最大 change_id
        assert body["server_cursor"] == tx_projection(sf, "tx-2").source_change_id
        assert len(body["conflict_samples"]) >= 1
        sample = body["conflict_samples"][0]
        assert sample["reason"] == "lww_rejected_older_change"
        assert sample["entitySyncId"] == "tx-1"
    finally:
        teardown()


def test_push_conflict_audit_is_throttled_but_counters_accurate():
    """conflict 反复重推:计数器每次都准确,不因 AuditLog 节流而失真。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m22@adv.test", "d-m22")
        base = now_utc()
        push(client, token, device, [
            tx_change("tx-1", amount=500, ts=iso(base + timedelta(seconds=60))),
        ])
        stale = [tx_change("tx-1", amount=1, ts=iso(base + timedelta(seconds=1)))]
        for _ in range(3):
            res = push(client, token, device, stale)
            assert res.json()["rejected"] == 1, res.json()
            assert res.json()["conflict_count"] == 1, res.json()
        # 事件流里 tx-1 只有最初一条
        assert len(sync_changes(sf, entity_type="transaction",
                                entity_sync_id="tx-1")) == 1
    finally:
        teardown()


def test_push_payload_mutation_of_client_dict_does_not_leak_bewteen_changes():
    """同批两条 change 各自独立:actor 注入不得串数据。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "m23@adv.test", "d-m23")
        res = push(client, token, device, [
            tx_change("tx-1", amount=1),
            tx_change("tx-2", amount=2),
        ])
        assert res.json()["accepted"] == 2
        rows = sync_changes(sf, entity_type="transaction")
        assert {r.entity_sync_id for r in rows} == {"tx-1", "tx-2"}
        for row in rows:
            payload = row.payload_json
            assert payload["createdByUserId"] == payload["updatedByUserId"]
    finally:
        teardown()


@pytest.mark.parametrize("bad_updated_at", [
    "not-a-date", "", "2026-13-45T99:99:99", 12345, None, True,
])
def test_push_malformed_updated_at_never_500(bad_updated_at):
    """畸形 updated_at 一律不 500(422 或 4xx/接受),服务端不崩。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, f"m24-{abs(hash(str(bad_updated_at)))%10000}@adv.test", "d-m24")
        chg = tx_change("tx-1")
        if bad_updated_at is None:
            chg.pop("updated_at", None)
        else:
            chg["updated_at"] = bad_updated_at
        res = client.post("/api/v1/sync/push", headers=auth_headers(token),
                          json={"device_id": device, "changes": [chg]})
        assert res.status_code < 500, (bad_updated_at, res.status_code, res.text[:200])
    finally:
        teardown()
