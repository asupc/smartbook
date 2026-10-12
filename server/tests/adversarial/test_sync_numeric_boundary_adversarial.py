"""对抗性测试:数值边界 / 币种 / 非标准 JSON 字面量。

覆盖攻击清单「数值边界」。核心关注:非有限浮点(NaN/Infinity)能否进入
投影与事件流、以及进入后各读路径 / 序列化的行为(是否 500、是否输出
非标准 JSON)。
"""
from __future__ import annotations

import json
from datetime import timedelta

from _adv_helpers import (
    ReadBudgetProjection,
    ReadTxProjection,
    UserAccountProjection,
    auth_headers,
    change,
    db_rows,
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
    web_create_ledger,
    web_create_tx,
)
from _adv_helpers import select


def _inject_infinity(amount_literal: str):
    """把 push body 里的 `"amount": 1` 替换成给定字面量。"""
    def mutate(raw: str) -> str:
        return raw.replace('"amount": 1,', f'"amount": {amount_literal},')
    return mutate


# =========================================================================== #
# 1. 非标准 JSON 字面量(NaN / Infinity)                                        #
# =========================================================================== #

def test_push_infinity_amount_enters_projection_and_poisons_reads():
    """ADVERSE FINDING(高危):push 的 amount 用非标准 JSON 字面量 `Infinity`
    (Python json 默认接受)→ 服务端 float('inf') 落进 read_tx_projection.amount,
    随后所有读路径返回 `"amount": null`(Starlette JSONResponse 的
    allow_nan=False 把 inf 序列化成 null),而 /sync/full 直接输出**非法 JSON
    字面量** `Infinity`。

    证据链:
    - src/projection.py:54-60 `_as_float` 用裸 `float(v)`,接受 'inf'/'Infinity';
    - 落库后 `read/ledgers.py` 的 ReadTransactionOut.amount: float → pydantic
      序列化 inf → JSONResponse(json.dumps(..., allow_nan=False)) 抛错?
      实测为 null(见断言)—— 无论如何,金额语义已损坏;
    - `snapshot_builder.build` 输出进 `/sync/full` 的 content 字符串,
      客户端 `json.decode`(Dart 严格 JSON)**会解析失败** → mobile 首次同步
      直接崩在畸形 payload 上。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n1@adv.test", "d-n1")
        web_token, _, _ = register_login(client, "n1@adv.test", "dev-web", "web")
        res = push_raw(
            client, token,
            {"device_id": device,
             "changes": [tx_change("tx-inf", amount=1, ledger_id="L01")]},
            _inject_infinity("Infinity"),
        )
        assert res.status_code == 200, res.text

        row = tx_projection(sf, "tx-inf")
        assert row is None or row.amount == row.amount and row.amount != float("inf"), (
            "// ADVERSE FINDING: 非标准 JSON 字面量 Infinity 未被拒绝,"
            f"落进投影 amount={row.amount if row else None}"
            "(应为 422 或规范化;当前污染投影与统计)"
        )
    finally:
        teardown()


def test_push_nan_amount_rejected_or_isolated():
    """NaN 字面量:apply 阶段被 SQLite NOT NULL / 数据库拒绝 → savepoint 隔离
    (failed_count=1)。HARDENING:不污染投影,但客户端只拿到 failed_samples,
    且该 change 会被反复重推(未进 poison 持久化标记)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n2@adv.test", "d-n2")
        res = push_raw(
            client, token,
            {"device_id": device,
             "changes": [tx_change("tx-nan", amount=1, ledger_id="L01")]},
            _inject_infinity("NaN"),
        )
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["failed_count"] == 1, body
        assert tx_projection(sf, "tx-nan") is None, "NaN 不得落库"
        assert sync_changes(sf, entity_sync_id="tx-nan") == [], "不得留孤儿事件行"
    finally:
        teardown()


def test_push_string_numeric_amounts_coerced_inconsistently():
    """ADVERSE FINDING(低危):amount 以**字符串**形式给出时的容错不一致。

    - `"12.5"` → 落库 12.5;
    - `"1e400"` → 旧实现 float('1e400') = inf → 落库 inf(污染);
    - `"0x1p3"` → 旧实现 ValueError → 0.0(静默变 0)。

    同一字段三种输入产生三种语义(数值/溢出/静默归零),客户端无法预期。

    **修复后口径(断言已按 defensive 行为收紧)**:
    - `'1e400'` 溢出 → 封顶到双精度上限(有限值,绝不落 inf);
    - `'0x1p3'` 非法 → 入口拒绝(savepoint 隔离,投影无行),不再静默归零。
    因此这里不再无条件要求行存在 —— 拒绝(无行)也算通过,只要不出现
    「inf 落库」或「静默变 0」这两种污染形态。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n3@adv.test", "d-n3")
        push(client, token, device, [tx_change("tx-str-ok", amount="12.5")])
        push(client, token, device, [tx_change("tx-str-over", amount="1e400")])
        push(client, token, device, [tx_change("tx-str-bad", amount="0x1p3")])

        assert tx_projection(sf, "tx-str-ok").amount == 12.5
        over_row = tx_projection(sf, "tx-str-over")
        over = over_row.amount if over_row is not None else None
        bad_row = tx_projection(sf, "tx-str-bad")
        bad = bad_row.amount if bad_row is not None else None
        assert not (over == float("inf") or bad == 0.0), (
            "// ADVERSE FINDING: 字符串 amount 容错不一致 —— "
            f"'1e400'→{over}(溢出为 inf 落库),'0x1p3'→{bad}(静默归零);"
            "同字段三种输入三种语义"
        )
    finally:
        teardown()


def test_snapshot_content_with_infinity_is_invalid_strict_json():
    """ADVERSE FINDING(高危):/sync/full 的 snapshot.content 在投影含 inf 时
    输出非标准 JSON 字面量 `Infinity` —— Dart/JS 严格 JSON 解析器直接抛错,
    mobile 首次同步/重装全量拉取会失败。

    `snapshot_builder.build` 直接把 float('inf') 放进 dict,
    `full.py:payload_json = {"content": json.dumps(cached, ...)}` 用 Python
    默认 `allow_nan=True` → 输出违反 RFC 8259 的 token。
    对比:同服务端 HTTP 响应体走 Starlette JSONResponse(allow_nan=False),
    两条路径对同一数据给出不同的合法性 —— 数据层已经写入就不可能自愈。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n4@adv.test", "d-n4")
        web_token, _, _ = register_login(client, "n4@adv.test", "dev-web", "web")
        push_raw(
            client, token,
            {"device_id": device,
             "changes": [tx_change("tx-inf", amount=1, ledger_id="L01")]},
            _inject_infinity("Infinity"),
        )
        full = client.get("/api/v1/sync/full?ledger_id=L01",
                         headers=auth_headers(web_token)).json()
        content = full["snapshot"]["payload"]["content"]

        def _strict(x):
            raise ValueError(f"non-standard JSON constant: {x}")

        try:
            json.loads(content, parse_constant=_strict)
        except ValueError as exc:
            raise AssertionError(
                "// ADVERSE FINDING: /sync/full 的 snapshot.content 含非标准 JSON "
                f"字面量({exc})—— mobile 严格 JSON 解析会失败;"
                "根因是非有限浮点被允许写入投影"
            ) from exc
    finally:
        teardown()


# =========================================================================== #
# 2. 金额取值边界                                                               #
# =========================================================================== #

def test_amount_zero_negative_and_huge_are_accepted():
    """HARDENING:push 路径对 amount 无范围约束(0 / 负数 / 1e308 全部接受),
    与 web 路径(WriteTransactionCreateRequest.amount: float,同样无 gt)一致。
    负数 expense 会扭曲统计符号,但属于产品决策层(web/mobile 都能录入调整)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n5@adv.test", "d-n5")
        res = push(client, token, device, [
            tx_change("tx-zero", amount=0),
            tx_change("tx-neg", amount=-100),
            tx_change("tx-huge", amount=1e308),
        ])
        assert res.json()["accepted"] == 3, res.json()
        assert tx_projection(sf, "tx-zero").amount == 0.0
        assert tx_projection(sf, "tx-neg").amount == -100.0
        assert tx_projection(sf, "tx-huge").amount == 1e308
    finally:
        teardown()


def test_amount_2pow53_and_beyond_loses_precision_silently():
    """ADVERSE FINDING(低危):amount 落库为 Float(双精度),
    `2**53 + 1` 静默丢精度(→ 9007199254740992.0)。金额语义数据走浮点本身
    是设计取舍(与 UserExchangeRateProjection 的 `rate: str` 注释对比:
    「金额语义数据不走浮点」—— 交易金额却走了)。

    这不是 push 独有的问题,但 push 是唯一没有 pydantic 校验的入口:
    web 侧 amount 也是 float,同样损失。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n6@adv.test", "d-n6")
        big = 2**53 + 1  # 9007199254740993
        push(client, token, device, [tx_change("tx-big", amount=big)])
        stored = tx_projection(sf, "tx-big").amount
        assert stored == float(big), (
            "// ADVERSE FINDING: 大整数金额静默丢精度 —— "
            f"输入 {big} 落库 {stored!r}(Float 双精度);"
            "金额语义数据未使用 Decimal/字符串"
        )
    finally:
        teardown()


def test_amount_four_decimal_places_round_trip():
    """HARDENING:4 位小数金额 round-trip 保持(双精度足够,无截断逻辑)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n7@adv.test", "d-n7")
        push(client, token, device, [tx_change("tx-dec", amount=1.2345)])
        assert tx_projection(sf, "tx-dec").amount == 1.2345
    finally:
        teardown()


def test_amount_sum_overflow_to_infinity_yields_null_in_read():
    """ADVERSE FINDING(中危):多笔 1e308 相加 → SUM 溢出为 inf →
    /read/ledgers 的 expense_total 静默变 null(而非报错/封顶)。

    SQLite SUM 溢出返回 inf;`read/ledgers.py:73` 的 `float(r[2] or 0)` 保留 inf,
    Starlette JSONResponse(allow_nan=False)把 inf 序列化成 null。
    用户看到"支出合计为空"而不是异常提示 —— 静默数据不可用。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n8@adv.test", "d-n8")
        web_token, _, _ = register_login(client, "n8@adv.test", "dev-web", "web")
        push(client, token, device, [
            tx_change(f"tx-h{i}", amount=1e308) for i in range(3)
        ])
        body = client.get("/api/v1/read/ledgers",
                         headers=auth_headers(web_token)).json()
        assert len(body) == 1
        totals = body[0]
        assert totals["expense_total"] is not None and totals["balance"] is not None, (
            "// ADVERSE FINDING: 金额求和溢出为 inf → HTTP 层静默变成 null"
            f"(expense_total={totals['expense_total']}, balance={totals['balance']});"
            "无溢出检测/封顶,用户看到空值而非错误"
        )
    finally:
        teardown()


def test_tx_index_beyond_int64_isolated_int64_max_accepted():
    """txIndex 越界:int64 内接受(含负数),超 int64 溢出 → apply 失败隔离。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n9@adv.test", "d-n9")
        assert push(client, token, device,
                    [tx_change("tx-max", amount=1, txIndex=2**63 - 1)]
                    ).json()["accepted"] == 1
        assert tx_projection(sf, "tx-max").tx_index == 2**63 - 1
        assert push(client, token, device,
                    [tx_change("tx-negidx", amount=1, txIndex=-5)]
                    ).json()["accepted"] == 1
        assert tx_projection(sf, "tx-negidx").tx_index == -5

        # 2^70 超 int64 → 数据库层溢出,savepoint 隔离(不 500)
        res = push(client, token, device, [tx_change("tx-over", amount=1, txIndex=2**70)])
        assert res.status_code == 200, res.text
        assert res.json()["failed_count"] == 1, res.json()
        assert tx_projection(sf, "tx-over") is None
    finally:
        teardown()


# =========================================================================== #
# 3. 币种字段                                                                   #
# =========================================================================== #

def test_push_currency_fields_are_not_normalized_to_upper():
    """ADVERSE FINDING(低危):push 路径的 currencyCode / currencyCode /
    account.currency **不归一化大小写**,与 web 路径(.upper())不一致。

    同一个账本,web 写入存 'EUR',mobile 推送存 'eur' —— 读路径做
    `.upper()` 兜底(workspace.py:369/1169/1492),但:
    - `read/ledgers.py:450` 的账户 currency 原样输出(不 .upper());
    - 多币种判定 `currencies = {...upper()}` 会合并;而汇率查找
      `reconcile rates[ov.quote_currency.upper()]` 也 upper;
    结局:多数路径侥幸可用,但任何**按原值分组/去重**的下游(导出、趋势)
    会把 EUR/eur 当两种币。对照 web 侧 `WriteLedgerMetaUpdateRequest` 走
    `_normalize_currency`(strip + upper + 截断 16)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n10@adv.test", "d-n10")
        push(client, token, device, [
            change("ledger", "L01", {"ledgerName": "L", "currency": "usd"},
                   ledger_id="L01"),
            tx_change("tx-lower", amount=10, currencyCode="usd", nativeAmount=10),
            change("account", "acc-lower", {"syncId": "acc-lower", "name": "Cash",
                                            "currency": "usd"}),
        ])
        from _adv_helpers import Ledger
        with sf() as db:
            lg = db.scalar(select(Ledger).where(Ledger.external_id == "L01"))
        tx = tx_projection(sf, "tx-lower")
        acc = db_rows(sf, UserAccountProjection, sync_id="acc-lower")[0]
        raw_values = (lg.currency, tx.currency_code, acc.currency)
        assert all(v in (None, v.upper()) for v in raw_values), (
            "// ADVERSE FINDING: push 路径币种未归一化(push.py 直接透传 payload)—— "
            f"ledger.currency={lg.currency!r} tx.currency_code={tx.currency_code!r} "
            f"account.currency={acc.currency!r};web 路径 _normalize_currency 会 upper。"
            "读路径靠 .upper() 兜底 → 侥幸可用,但按原值分组的下游会分成两种币"
        )
    finally:
        teardown()


def test_push_overlong_currency_code_exceeds_column_declaration():
    """ADVERSE FINDING(中危):push 的 currencyCode 无长度校验,可写入远超
    列声明 String(16) 的值(SQLite 不强制 VARCHAR 长度,PostgreSQL **会**报错
    `value too long for type character varying(16)` → 5xx/批失败)。

    同一字段:web 侧 pydantic `currency: str = Field(max_length=16)`,
    push 侧 SyncChangeIn.payload 是 `dict[str, Any]`(无 schema)。
    当前在 sqlite(dev/test)静默通过 → 生产 PG 才炸的「环境相关缺陷」。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n11@adv.test", "d-n11")
        long_ccy = "Z" * 200
        res = push(client, token, device, [
            tx_change("tx-ccy", amount=1, currencyCode=long_ccy),
        ])
        assert res.status_code == 200, res.text
        tx = tx_projection(sf, "tx-ccy")
        stored_len = len(tx.currency_code or "")
        assert stored_len <= 16, (
            "// ADVERSE FINDING: push 的 currencyCode 无长度校验 —— "
            f"落库 {stored_len} 字符(列声明 models.py:String(16))。"
            "SQLite 不强制 → 测试/开发环境静默通过;"
            "PostgreSQL 上 INSERT 会抛值超长错误(批 500 或 savepoint 隔离)。"
            "web 侧同名 payload 由 pydantic max_length=16 拦截。"
        )
    finally:
        teardown()


def test_push_overlong_sync_id_and_entity_sync_id_exceed_columns():
    """ADVERSE FINDING(中危):entity_sync_id / payload.syncId 无长度校验,
    可超过 String(255) 声明 —— 同一 PostgreSQL `value too long` 风险,
    且 `attachment_files` / `read_*_projection` 多表共用该 id 长度假设。

    实测(修复前)sqlite 下 400+ 字符静默落库。web 侧生成的 sync_id 固定
    `tx_<12hex>`(snapshot_mutator._new_sync_id),mobile 侧是 UUID ——
    正常客户端不会超长,但服务端不设防。

    **修复后口径(断言已按 defensive 行为收紧)**:入口按列宽(255)拒绝,
    `rejected++` 且投影无行 —— 这比"静默截断"更安全:截断会让两条不同的
    超长实体塌成同一个 sync_id(数据互覆盖)。因此断言改为「要么无行,
    要么行内 sync_id ≤ 255」,两种 defensive 结果都通过,只有
    「超长值落库」保持红。
    """
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n12@adv.test", "d-n12")
        long_id = "tx-" + "x" * 400
        res = push(client, token, device, [
            tx_change(long_id, amount=1),
        ])
        assert res.status_code == 200, res.text
        row = tx_projection(sf, long_id)
        assert row is None or len(row.sync_id) <= 255, (
            "// ADVERSE FINDING: entity_sync_id 无长度上限 —— "
            f"落库 {len(row.sync_id) if row else 0} 字符(String(255) 声明);"
            "SQLite 静默,PostgreSQL 报 value too long"
        )
        if row is None:
            # 入口拒绝路径:必须是显式 rejected(带可诊断 reason),不是静默丢弃。
            body = res.json()
            assert body["rejected"] == 1 and body["accepted"] == 0, body
            assert body["failed_samples"][0]["reason"] == "entity_sync_id_too_long", body
    finally:
        teardown()


def test_web_overlong_currency_code_via_tx_create_also_unvalidated():
    """对照探针:web 建交易的 currency_code 同样无 max_length(只有 ledger
    的 currency 有)→ 两条路径都缺该校验。"""
    client, sf = make_client()
    try:
        web_token, _, _ = register_login(client, "n13@adv.test", "dev-web", "web")
        web_create_ledger(client, web_token, "W13")
        res = web_create_tx(client, web_token, "W13", 5, currency_code="Z" * 200)
        assert res.status_code == 200, res.text
        row = db_rows(sf, ReadTxProjection)[0]
        assert len(row.currency_code or "") <= 16, (
            "// ADVERSE FINDING: web 建交易的 currency_code 也无长度校验 —— "
            f"落库 {len(row.currency_code or '')} 字符"
            "(WriteTransactionCreateRequest.currency_code: str | None,无 max_length)"
        )
    finally:
        teardown()


# =========================================================================== #
# 4. 预算数值                                                                   #
# =========================================================================== #

def test_push_budget_negative_amount_accepted_while_web_rejects():
    """ADVERSE FINDING(低危):预算金额 web 侧 `Field(gt=0)`,push 侧无校验 →
    mobile 可推负数/0 预算,web 建不出来。读路径不报错(used 按 0 计),
    但 UI 会显示负预算(进度条/剩余额语义崩坏)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n14@adv.test", "d-n14")
        web_token, _, _ = register_login(client, "n14@adv.test", "dev-web", "web")
        res = push(client, token, device, [
            change("budget", "bud-neg", {"syncId": "bud-neg", "type": "total",
                                         "amount": -50, "period": "monthly",
                                         "startDay": 1, "enabled": True},
                   ledger_id="L01"),
        ])
        assert res.json()["accepted"] == 1, res.json()
        bud = db_rows(sf, ReadBudgetProjection, sync_id="bud-neg")[0]
        push_ok_negative = bud.amount == -50.0

        web_create_ledger(client, web_token, "W14")
        web_res = client.post(
            "/api/v1/write/ledgers/W14/budgets",
            json={"base_change_id": 0, "type": "total", "amount": -50,
                  "period": "monthly"},
            headers=auth_headers(web_token),
        )
        assert not (push_ok_negative and web_res.status_code == 422), (
            "// ADVERSE FINDING: 预算金额校验双路径不一致 —— push 接受 -50"
            f"(落库 {bud.amount}),web 拒绝 422;"
            "WriteBudgetCreateRequest.amount: float = Field(gt=0) vs push payload 无校验"
        )
    finally:
        teardown()


def test_push_budget_start_day_out_of_range_not_clamped():
    """HARDENING:budget.startDay 越界(99)原样落库;但读端 `_current_period_range`
    统一 clamp 到 [1,28] 且**改用账本 month_start_day**(D5 决策),故实际无害。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n15@adv.test", "d-n15")
        push(client, token, device, [
            change("budget", "bud-day", {"syncId": "bud-day", "type": "total",
                                         "amount": 100, "period": "monthly",
                                         "startDay": 99, "enabled": True},
                   ledger_id="L01"),
        ])
        bud = db_rows(sf, ReadBudgetProjection, sync_id="bud-day")[0]
        assert bud.start_day == 99, bud.start_day
        assert bud.start_day == 99, (
            "HARDENING: startDay 未 clamp 落库(web 侧 Field(le=28) 会拒);"
            "读端改用 ledger.month_start_day,所以无实际影响"
        )
    finally:
        teardown()


def test_push_budget_amount_string_inf_coerced_to_inf():
    """预算 amount 为字符串 'inf' → _as_float 容错 → inf 落库(同交易额问题)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n16@adv.test", "d-n16")
        push(client, token, device, [
            change("budget", "bud-inf", {"syncId": "bud-inf", "type": "total",
                                         "amount": "inf", "period": "monthly",
                                         "startDay": 1, "enabled": True},
                   ledger_id="L01"),
        ])
        bud = db_rows(sf, ReadBudgetProjection, sync_id="bud-inf")[0]
        assert bud.amount != float("inf"), (
            "// ADVERSE FINDING: 预算 amount 字符串 'inf' 经 _as_float 容错"
            f"落库为 {bud.amount!r};同一 coercion 漏洞在 budget/account/tx 三处复用"
        )
    finally:
        teardown()


# =========================================================================== #
# 5. 非交易实体的数值溢出                                                        #
# =========================================================================== #

def test_account_initial_balance_infinity_accepted():
    """account.initialBalance 用 Infinity → 落库 inf → 净资产/账户余额统计失真。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n17@adv.test", "d-n17")
        web_token, _, _ = register_login(client, "n17@adv.test", "dev-web", "web")
        res = push_raw(
            client, token,
            {"device_id": device, "changes": [
                change("account", "acc-inf", {"syncId": "acc-inf", "name": "Cash",
                                              "type": "cash", "currency": "CNY",
                                              "initialBalance": 1})]},
            lambda raw: raw.replace('"initialBalance": 1', '"initialBalance": Infinity'),
        )
        assert res.status_code == 200, res.text
        acc = db_rows(sf, UserAccountProjection, sync_id="acc-inf")[0]
        assert acc.initial_balance != float("inf"), (
            "// ADVERSE FINDING: account.initialBalance 接受 Infinity → "
            f"落库 {acc.initial_balance!r};净资产/余额统计被污染为不可用值"
        )
    finally:
        teardown()


def test_account_adjustment_balance_infinity():
    """account_adjustment 的 amount 同样接受 Infinity。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n18@adv.test", "d-n18")
        res = push_raw(
            client, token,
            {"device_id": device, "changes": [
                change("account_adjustment", "adj-inf",
                       {"syncId": "adj-inf", "accountId": "acc-1",
                        "accountName": "Cash", "amount": 1,
                        "balanceBefore": 0, "balanceAfter": 1, "happenedAt": iso()},
                       ledger_id="L01")]},
            lambda raw: raw.replace('"amount": 1,', '"amount": Infinity,'),
        )
        assert res.status_code == 200, res.text
        from _adv_helpers import ReadAccountAdjustmentProjection
        rows = db_rows(sf, ReadAccountAdjustmentProjection, sync_id="adj-inf")
        assert rows and rows[0].amount != float("inf"), (
            "// ADVERSE FINDING: account_adjustment.amount 接受 Infinity → "
            f"落库 {rows[0].amount if rows else None!r};"
            "调整记录的审计快照(balanceAfter)也会被污染"
        )
    finally:
        teardown()


def test_exchange_rate_override_rate_is_string_so_inf_possible_but_read_is_guarded():
    """HARDENING:exchange_rate_override.rate 是字符串列(不落 float),
    读端 `_rates_to_base_for_user` 用 `float(...)` + `if r > 0` 过滤,
    inf 会通过判定(inf > 0)→ 汇率表被污染为 inf,换算结果为 0。
    需客户端主动写入非法 rate 才可达(`rate: str = Field(max_length=32)`,
    push 侧无约束)。"""
    client, sf = make_client()
    try:
        token, device, _ = register_login(client, "n19@adv.test", "d-n19")
        web_token, _, _ = register_login(client, "n19@adv.test", "dev-web", "web")
        res = push(client, token, device, [
            change("exchange_rate_override", "rate-1",
                   {"syncId": "rate-1", "baseCurrency": "CNY", "quoteCurrency": "USD",
                    "rate": "inf", "updatedAt": iso()}),
        ])
        assert res.status_code == 200, res.text
        from _adv_helpers import db_rows as _rows
        from src.models import UserExchangeRateProjection
        rows = _rows(sf, UserExchangeRateProjection, sync_id="rate-1")
        assert rows, "override 未落库"
        assert rows[0].rate == "inf", rows[0].rate
        # 读端行为:inf > 0 → 通过 → 汇率 inf
        res = client.get("/api/v1/read/exchange-rate-overrides",
                         headers=auth_headers(web_token))
        assert res.status_code in (200, 404), res.text
    finally:
        teardown()
