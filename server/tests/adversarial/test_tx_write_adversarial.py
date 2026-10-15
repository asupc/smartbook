"""对抗性测试 —— 交易写路径(金额/日期边界、批量、回收站、更新语义、多币种)。

脚手架照抄 tests/test_sync_concurrency.py / test_tx_batch_delete.py:
sqlite in-memory + StaticPool + dependency_overrides。

约定:
- ``// ADVERSE FINDING:`` 标记的测试 = 已确认缺陷,**故意保持失败**。
- ``// HARDENING:`` 标记的测试 = 当前行为可辩护但脆弱,断言现状并通过。
"""
from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import ReadTxProjection, SyncChange

_PW = "Pa$$word1!"


def _make_client() -> TestClient:
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
    # 500 场景需要拿到响应而不是异常(对抗性测试要看错误面)
    return TestClient(app, raise_server_exceptions=False)


def _register_and_login(client: TestClient, email: str) -> str:
    client.post(
        "/api/v1/auth/register",
        json={
            "email": email, "password": _PW, "device_id": "d-web",
            "client_type": "web", "device_name": "pytest", "platform": "web",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email, "password": _PW, "device_id": "d-web",
            "client_type": "web", "device_name": "pytest", "platform": "web",
        },
    )
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"}


def _h_json(token: str) -> dict:
    return {**_h(token), "Content-Type": "application/json"}


def _create_ledger(client: TestClient, token: str, name: str = "default") -> str:
    r = client.post(
        "/api/v1/write/ledgers",
        json={"ledger_name": name, "currency": "CNY"},
        headers=_h(token),
    )
    assert r.status_code == 200, r.text
    return r.json()["entity_id"]


def _create_tx(client: TestClient, token: str, ledger_id: str, amount=10.0, note="n", **kw):
    body = {
        "base_change_id": 0, "tx_type": "expense", "amount": amount,
        "happened_at": "2026-05-06T12:30:00Z", "note": note, **kw,
    }
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions", json=body, headers=_h(token)
    )


def _raw_create(client: TestClient, token: str, ledger_id: str, raw_body: str):
    """绕过 pydantic 的 json 序列化,直接发原样 body(NaN / 1e309 / str 数字)。"""
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        content=raw_body,
        headers=_h_json(token),
    )


def _list_txs(client: TestClient, token: str, ledger_id: str) -> list[dict]:
    r = client.get(
        f"/api/v1/read/ledgers/{ledger_id}/transactions", headers=_h(token)
    )
    assert r.status_code == 200, r.text
    return r.json()


def _analytics(client: TestClient, token: str, ledger_id: str, scope: str = "all") -> dict:
    r = client.get(
        f"/api/v1/read/workspace/analytics?scope={scope}&ledger_id={ledger_id}",
        headers=_h(token),
    )
    assert r.status_code == 200, r.text
    return r.json()


# ---------------------------------------------------------------------------
# 金额边界
# ---------------------------------------------------------------------------


def test_amount_zero_transaction_is_created():
    # HARDENING: 0 元交易被接受(schema 没有 gt=0,只有预算有)。金额 0 在账本
    # 里无财务意义,但也不会损坏数据;UI 需要自己拦。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-amount-zero@t.com")
        lg = _create_ledger(client, token)
        r = _create_tx(client, token, lg, amount=0)
        assert r.status_code == 200, r.text
        txs = _list_txs(client, token, lg)
        assert txs[0]["amount"] == 0.0
    finally:
        app.dependency_overrides.clear()


def test_negative_expense_amount_poisons_expense_total():
    # ADVERSE FINDING: 负数支出被原样存储,不走符号归一化
    # 证据 src/routers/write/transactions.py:31 (amount: float 无 ge/gt 约束)
    #      src/snapshot_mutator.py:380 _to_float(payload.get("amount")) 原样取负
    # 期望: 负值支出现在支出统计里应被拒绝(或取绝对值), expense_total 不应为负
    # 实际: expense=-100 + expense=+50 → expense_total == -50;分类排行按
    #       `float(values["expense"]) > 0` 过滤(src/routers/read/workspace.py:1265)
    #       会把这类负值分类整条隐藏,报表静默少数据
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-neg@t.com")
        lg = _create_ledger(client, token)
        assert _create_tx(client, token, lg, amount=-100.0, note="neg").status_code == 200
        assert _create_tx(client, token, lg, amount=50.0, note="pos").status_code == 200
        agg = _analytics(client, token, lg)
        assert agg["summary"]["expense_total"] >= 0, agg["summary"]
    finally:
        app.dependency_overrides.clear()


def test_amount_bool_true_coerced_to_one():
    # HARDENING: pydantic float 接受 bool → True 变 1.0。JSON 类型撒谎但影响有限。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-bool@t.com")
        lg = _create_ledger(client, token)
        r = _create_tx(client, token, lg, amount=True, note="bool")
        assert r.status_code == 200
        assert _list_txs(client, token, lg)[0]["amount"] == 1.0
    finally:
        app.dependency_overrides.clear()


def test_amount_numeric_string_coerced():
    # HARDENING: "123" / "12.5" 被 pydantic 强转;前端传字符串不报错(宽容客户端),
    # 但空串会 422 —— 行为不一致但可用。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-str@t.com")
        lg = _create_ledger(client, token)
        assert _create_tx(client, token, lg, amount="123", note="s1").status_code == 200
        assert _create_tx(client, token, lg, amount="12.5", note="s2").status_code == 200
        r = _create_tx(client, token, lg, amount="", note="s3")
        assert r.status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_amount_1e309_persists_infinity_and_nulls_ledger_aggregates():
    # ADVERSE FINDING: 1e309 被解析成 inf 并原样落库,随后污染整个账本的
    # JSON 响应 —— 账本 balance / expense_total / 交易 amount 全部变成 null
    # (JSON 规范不允许 Infinity,序列化时被写成 null),前端拿到 null 金额。
    # 证据: src/schemas.py:951 `amount: float`(无 allow_inf_nan=False);
    #       src/snapshot_mutator.py:38 _to_float 直通;
    #       src/projection.py:255 values["amount"] = _as_float(...) 落 ReadTxProjection.amount
    #       聚合端点 src/routers/read/_shared.py:499 COALESCE(native_amount, amount) 求和 → inf
    # 期望: 非有限浮点被 4xx 拒绝(或存成 0)
    # 实际: 200 + 存 inf;随后 /read/ledgers 与 /read/ledgers/{id} 的
    #       expense_total / balance 全变 null
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-inf@t.com")
        lg = _create_ledger(client, token)
        r = _raw_create(
            client, token, lg,
            '{"base_change_id":0,"amount":1e309,"happened_at":"2026-05-06T12:30:00Z","note":"inf"}',
        )
        assert r.status_code in (400, 422), f"inf 金额必须被拒绝,实际 {r.status_code}"

        detail = client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(token)).json()
        assert detail["balance"] is not None, "账本余额被 inf 污染成 null"
        assert detail["expense_total"] is not None, "账本支出被 inf 污染成 null"
    finally:
        app.dependency_overrides.clear()


def test_amount_nan_returns_500_instead_of_4xx():
    # ADVERSE FINDING: amount=NaN → 500 INTERNAL_ERROR(未处理的 sqlite
    # IntegrityError: NOT NULL constraint failed: read_tx_projection.amount)。
    # 证据: src/schemas.py:951 无 allow_inf_nan 限制 →
    #       src/snapshot_mutator.py:292 _to_float(nan) = nan →
    #       src/projection.py:255 写 NaN → NOT NULL 约束炸;
    #       _commit_create_tx_fast(src/routers/write/_shared.py:642)只兜 IntegrityError
    #       的幂等分支,无 NaN 归一化
    # 期望: 4xx(参数非法);实际: 500 + 请求方拿到 INTERNAL_ERROR
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-nan@t.com")
        lg = _create_ledger(client, token)
        r = _raw_create(
            client, token, lg,
            '{"base_change_id":0,"amount":NaN,"happened_at":"2026-05-06T12:30:00Z","note":"nan"}',
        )
        assert r.status_code in (400, 422), f"NaN 金额必须被 4xx 拒绝,实际 {r.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_amount_nan_in_patch_batch_and_adjustment_all_500():
    # ADVERSE FINDING: NaN 在 PATCH / 批量创建 / 余额调整三条路径同样 500。
    # 证据: src/routers/write/_shared.py:751 update_transaction(minimal_snap, ...)
    #       无 NaN 校验;src/routers/write/transactions_batch.py:247 create_transaction;
    #       src/snapshot_mutator.py:991 create_account_adjustment
    # 期望: 三条路径均 4xx;实际: 三条路径均 500
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-nan2@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]

        r_patch = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            content='{"base_change_id":0,"amount":NaN}',
            headers=_h_json(token),
        )
        r_batch = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch",
            content=(
                '{"base_change_id":0,"transactions":[{"tx_type":"expense",'
                '"amount":NaN,"happened_at":"2026-05-06T12:30:00Z"}]}'
            ),
            headers=_h_json(token),
        )
        r_adj = client.post(
            f"/api/v1/write/ledgers/{lg}/account-adjustments",
            content=(
                '{"base_change_id":0,"account_id":"acc_x","amount":NaN,'
                '"happened_at":"2026-05-06T12:30:00Z"}'
            ),
            headers=_h_json(token),
        )
        assert (r_patch.status_code, r_batch.status_code, r_adj.status_code) == (400, 400, 400), (
            f"NaN 应统一 4xx,实际 PATCH={r_patch.status_code} "
            f"batch={r_batch.status_code} adjustment={r_adj.status_code}"
        )
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 更新语义(PATCH)
# ---------------------------------------------------------------------------


def test_patch_amount_null_silently_zeroes_the_amount():
    # ADVERSE FINDING: PATCH {"amount": null} 把金额静默改成 0,交易金额丢失。
    # 证据: src/routers/write/transactions.py:82 `exclude_unset=True` 让
    #       amount=None 进入 payload;src/snapshot_mutator.py:379 `if "amount" in payload`
    #       命中 → _to_float(None) == 0.0(src/snapshot_mutator.py:38-46)
    # 期望: null 视为"不变"(与 note/category 等字段的 `value is None → 不动` 语义一致)
    #       或 400;实际: 200 且金额归零
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-nullamt@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg, amount=100.0).json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "amount": None},
            headers=_h(token),
        )
        assert r.status_code == 200, r.text
        after = _list_txs(client, token, lg)[0]
        assert after["amount"] == 100.0, (
            f"amount=null 必须被忽略(保持 100.0),实际被写成 {after['amount']}"
        )
    finally:
        app.dependency_overrides.clear()


def test_patch_happened_at_null_resets_to_now():
    # ADVERSE FINDING: PATCH {"happened_at": null} 把交易时间静默改成"服务器当前时间"。
    # 证据: src/snapshot_mutator.py:401 `if "happened_at" in payload` →
    #       _to_iso8601(None) 走 fallback 分支返回 datetime.now()(:35)
    # 期望: null 视为"不变"或 4xx;实际: 200 且时间跳到今天(跨月/跨年错账)
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-nulldate@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "happened_at": None},
            headers=_h(token),
        )
        assert r.status_code == 200, r.text
        after = _list_txs(client, token, lg)[0]
        assert str(after["happened_at"]).startswith("2026-05-06"), (
            f"happened_at=null 必须被忽略,实际变成 {after['happened_at']}"
        )
    finally:
        app.dependency_overrides.clear()


def test_patch_tx_type_null_returns_500():
    # ADVERSE FINDING: PATCH {"tx_type": null} → 500。
    # 证据: src/schemas.py:976 `tx_type: Literal[...] | None` 放行 null;
    #       src/snapshot_mutator.py:373-376 把 None 变 "" → ValueError(业务校验失败);
    #       但快路径 src/routers/write/_shared.py:751 调 update_transaction 时
    #       **没有** try/except ValueError(全量路径 _commit_write:1360 有)→ 冒泡成 500
    # 期望: 400 WRITE_VALIDATION_FAILED;实际: 500 INTERNAL_ERROR
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-nulltype@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "tx_type": None},
            headers=_h(token),
        )
        assert r.status_code == 400, f"tx_type=null 应 400,实际 {r.status_code} {r.text[:160]}"
    finally:
        app.dependency_overrides.clear()


def test_patch_tx_type_invalid_returns_422():
    # HARDENING: 非法枚举值被 pydantic 挡在 422(与 null 的 500 形成不一致的反差)。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-badtype@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "tx_type": "bogus"},
            headers=_h(token),
        )
        assert r.status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_patch_empty_body_still_bumps_change_id_and_editor():
    # HARDENING: PATCH {} 不是真 no-op —— _mark_entity_actor 会写 updatedByUserId,
    # diff 因此认为实体变了,发一条 upsert SyncChange(change_id 前进)。
    # 移动端会多收到一条无意义 change;"最后编辑人"被改成调用者。
    # 证据: src/snapshot_mutator.py:465 _mark_entity_actor(item, payload, create=False)
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-emptypatch@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]

        db = next(app.dependency_overrides[get_db]())
        before = db.scalar(select(SyncChange.change_id).order_by(SyncChange.change_id.desc()))
        db.close()

        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0},
            headers=_h(token),
        )
        assert r.status_code == 200, r.text

        db = next(app.dependency_overrides[get_db]())
        after = db.scalar(select(SyncChange.change_id).order_by(SyncChange.change_id.desc()))
        db.close()
        assert after > before, "空 PATCH 推进了 change_id(确认的现状)"
    finally:
        app.dependency_overrides.clear()


def test_patch_unknown_fields_are_silently_ignored():
    # HARDENING: body 里未知字段(含试图跨账本搬移的 ledger_id)被静默丢弃,
    # 不报 422。宽容但容易掩盖客户端拼错字段名。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-unknown@t.com")
        lg = _create_ledger(client, token)
        lg2 = _create_ledger(client, token, name="other")
        tx = _create_tx(client, token, lg).json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "ledger_id": lg2, "evil": True},
            headers=_h(token),
        )
        assert r.status_code == 200, r.text
        # 交易仍在原账本
        assert len(_list_txs(client, token, lg)) == 1
        assert len(_list_txs(client, token, lg2)) == 0
    finally:
        app.dependency_overrides.clear()


def test_patch_currency_code_without_native_amount_mixes_units():
    # HARDENING: PATCH currency_code=JPY 而 native_amount 缺省 → 账本统计
    # COALESCE 回退用 amount(把 JPY 数值当 CNY 加)。契约允许(NULL 回退),
    # 但 web 端只改币种不改折算会静默错账。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-ccy@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg, amount=100.0).json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "currency_code": "JPY"},
            headers=_h(token),
        )
        assert r.status_code == 200, r.text
        row = _list_txs(client, token, lg)[0]
        assert row["currency_code"] == "JPY" and row["native_amount"] is None
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 日期边界
# ---------------------------------------------------------------------------


def test_1970_and_9999_and_future_dates_accepted():
    # HARDENING: happened_at 无合理区间校验,1970 / 2999 / 9999 全部接受
    # (mobile 端同款宽松)。配合 leadly 影响的 days_since_first_tx 见下一测试。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-date@t.com")
        lg = _create_ledger(client, token)
        for note, at in (
            ("epoch", "1970-01-01T00:00:00Z"),
            ("y9999", "9999-12-31T23:59:59Z"),
            ("future", "2999-01-01T00:00:00Z"),
        ):
            r = _create_tx(client, token, lg, amount=1.0, note=note, happened_at=at)
            assert r.status_code == 200, f"{note}: {r.text}"
        assert len(_list_txs(client, token, lg)) == 3
    finally:
        app.dependency_overrides.clear()


def test_future_transaction_yields_negative_days_since_first_tx():
    # ADVERSE FINDING: 未来时间的交易让 /read/workspace/ledger-counts 的
    # days_since_first_tx 变成大负数(-355097),首页"记账天数"直接崩坏。
    # 证据: src/routers/read/workspace.py:1029-1034
    #       days_since_first_tx = (today_utc - first_day).days + 1,无 clamp
    # 期望: 负数被 clamp 到 0(或拒绝未来交易);实际: 返回 -355097
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-futd@t.com")
        lg = _create_ledger(client, token)
        assert _create_tx(
            client, token, lg, note="future", happened_at="2999-01-01T00:00:00Z"
        ).status_code == 200
        r = client.get("/api/v1/read/workspace/ledger-counts", headers=_h(token))
        assert r.status_code == 200
        assert r.json()["days_since_first_tx"] >= 0, r.json()
    finally:
        app.dependency_overrides.clear()


def test_naive_happened_at_is_treated_as_utc():
    # HARDENING: 不带时区的 happened_at 被当 UTC(_to_iso8601 补 UTC),与文档一致。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-naive@t.com")
        lg = _create_ledger(client, token)
        r = _create_tx(client, token, lg, note="naive", happened_at="2026-05-06T12:30:00")
        assert r.status_code == 200
        assert str(_list_txs(client, token, lg)[0]["happened_at"]).startswith("2026-05-06T12:30:00")
    finally:
        app.dependency_overrides.clear()


def test_invalid_date_format_rejected():
    # HARDENING: 非法日期字符串 pydantic 直接 422。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-baddate@t.com")
        lg = _create_ledger(client, token)
        r = _create_tx(client, token, lg, note="bad", happened_at="not-a-date")
        assert r.status_code == 422
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 文本字段
# ---------------------------------------------------------------------------


def test_nul_byte_in_note_survives_roundtrip():
    # HARDENING: note 里的 \x00 原样存取,没有清洗。前端渲染时可能截断,
    # 但服务端不炸(不是崩溃点)。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-nul@t.com")
        lg = _create_ledger(client, token)
        assert _create_tx(client, token, lg, note="a\x00b").status_code == 200
        assert _list_txs(client, token, lg)[0]["note"] == "a\x00b"
    finally:
        app.dependency_overrides.clear()


def test_very_long_note_accepted_without_limit():
    # HARDENING: note 是 Text 列,无长度上限 —— 10 万字符照收。单用户自部署
    # 场景风险有限,但缺一个上限就是无界存储。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-longnote@t.com")
        lg = _create_ledger(client, token)
        assert _create_tx(client, token, lg, note="X" * 100_000).status_code == 200
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 批量操作
# ---------------------------------------------------------------------------


def test_batch_delete_boundaries_and_dedup():
    # HARDENING: 空数组 422;200 条上限恰好通过;201 条 422;重复 id 去重。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-bd@t.com")
        lg = _create_ledger(client, token)
        ids = [_create_tx(client, token, lg, note=f"t{i}").json()["entity_id"] for i in range(3)]

        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch/delete",
            json={"tx_ids": [], "base_change_id": 0}, headers=_h(token),
        )
        assert r.status_code == 422

        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch/delete",
            json={"tx_ids": [ids[0], ids[0], ids[0]], "base_change_id": 0}, headers=_h(token),
        )
        assert r.status_code == 200, r.text
        assert r.json()["deleted_tx_ids"] == [ids[0]]

        many = [ids[1]] + [f"tx_fake_{i}" for i in range(199)]
        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch/delete",
            json={"tx_ids": many, "base_change_id": 0}, headers=_h(token),
        )
        assert r.status_code == 200, r.text
        assert len(r.json()["deleted_tx_ids"]) == 1
        assert len(r.json()["failed"]) == 199

        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch/delete",
            json={"tx_ids": [f"tx_{i}" for i in range(201)], "base_change_id": 0}, headers=_h(token),
        )
        assert r.status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_batch_delete_cross_ledger_ids_are_inert():
    # HARDENING: 跨账本 sync_id 记 not_found,目标账本数据不动。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-bdx@t.com")
        a = _create_ledger(client, token, name="A")
        b = _create_ledger(client, token, name="B")
        ids_b = [_create_tx(client, token, b, note=f"b{i}").json()["entity_id"] for i in range(2)]
        r = client.post(
            f"/api/v1/write/ledgers/{a}/transactions/batch/delete",
            json={"tx_ids": ids_b, "base_change_id": 0}, headers=_h(token),
        )
        assert r.status_code == 200
        assert r.json()["deleted_tx_ids"] == []
        assert len(_list_txs(client, token, b)) == 2
    finally:
        app.dependency_overrides.clear()


def test_batch_create_atomicity_bad_row_rolls_back_whole_batch():
    # HARDENING: 批量创建里任一行非法 → 整批 400 且一行都不落(事务原子性正确)。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-bca@t.com")
        lg = _create_ledger(client, token)
        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch",
            json={
                "base_change_id": 0, "auto_ai_tag": False,
                "transactions": [
                    {"tx_type": "expense", "amount": 1, "happened_at": "2026-05-06T12:30:00Z", "note": "ok"},
                    {"tx_type": "bogus", "amount": 2, "happened_at": "2026-05-06T12:30:00Z", "note": "bad"},
                ],
            },
            headers=_h(token),
        )
        assert r.status_code == 400, r.text
        assert _list_txs(client, token, lg) == []
    finally:
        app.dependency_overrides.clear()


def test_batch_move_resurrects_trashed_transaction():
    # ADVERSE FINDING: 已被删除(回收站)的交易可以通过 batch/move 直接改分类
    # 并"复活" —— delete_transaction 的软删标记被 upsert 清空
    # (src/projection.py:295 deleted_at=None)。
    # 证据: src/routers/write/transactions_batch_move.py:170-175 点查目标行时
    #       **没有** deleted_at.is_(None) 过滤(对比 batch_delete:140-146 有过滤),
    #       于是已回收站的行被喂进 mutator → _emit_entity_diffs → upsert_tx 清软删。
    # 期望: 已软删交易在批量移动里报 not_found(与 batch_delete 一致);
    # 实际: 200 moved_tx_ids=[...],交易重新出现在账本列表,回收站清空
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-bmrevive@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg, note="victim").json()["entity_id"]
        client.post(
            f"/api/v1/write/ledgers/{lg}/categories",
            json={"base_change_id": 0, "name": "交通", "kind": "expense", "level": 1},
            headers=_h(token),
        )
        cat = next(
            c for c in client.get(
                f"/api/v1/read/ledgers/{lg}/categories", headers=_h(token)
            ).json() if c["name"] == "交通"
        )
        # 软删
        r = client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0}, headers=_h(token),
        )
        assert r.status_code == 200
        assert client.get("/api/v1/read/workspace/trash", headers=_h(token)).json()["total"] == 1

        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch/move",
            json={"tx_ids": [tx], "target_category_id": cat["id"], "base_change_id": 0},
            headers=_h(token),
        )
        assert r.status_code == 200, r.text
        assert r.json()["moved_tx_ids"] == [], (
            f"回收站里的交易不应被移动成功,实际 moved={r.json()['moved_tx_ids']} failed={r.json()['failed']}"
        )
        # 交易不得回到活跃列表,回收站也不得被清空
        assert _list_txs(client, token, lg) == [], "回收站里的交易被复活到账本列表"
        assert client.get("/api/v1/read/workspace/trash", headers=_h(token)).json()["total"] == 1
    finally:
        app.dependency_overrides.clear()


def test_patch_resurrects_trashed_transaction():
    # ADVERSE FINDING: 已被删除(回收站)的交易可以 PATCH 改字段并复活 ——
    # 单笔 update 快路径同样不过滤 deleted_at。
    # 证据: src/routers/write/_shared.py:710-715
    #       select(ReadTxProjection).where(ledger_id, sync_id) 无软删过滤。
    # 期望: 已删交易 404(回收站需要先 restore);实际: 200 且交易回到账本列表、
    #       回收站条目消失 —— "删除安全网"被静默绕过
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-previve@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg, amount=50.0, note="victim").json()["entity_id"]
        client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0}, headers=_h(token),
        )
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "note": "edited-in-trash"},
            headers=_h(token),
        )
        assert r.status_code == 404, (
            f"回收站中的交易不应可 PATCH,实际 {r.status_code};"
            f"回收站剩余 {client.get('/api/v1/read/workspace/trash', headers=_h(token)).json()['total']}"
        )
    finally:
        app.dependency_overrides.clear()


def test_batch_create_51_items_rejected():
    # HARDENING: 批量创建上限 50(schema),51 → 422。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-bc51@t.com")
        lg = _create_ledger(client, token)
        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch",
            json={
                "base_change_id": 0, "auto_ai_tag": False,
                "transactions": [
                    {"tx_type": "expense", "amount": 1, "happened_at": "2026-05-06T12:30:00Z"}
                    for _ in range(51)
                ],
            },
            headers=_h(token),
        )
        assert r.status_code == 422
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 回收站
# ---------------------------------------------------------------------------


def test_trash_purge_and_restore_guards():
    # HARDENING: 存活交易 purge/restore → 404;purge 不存在 → 404;purge 幂等。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-trash@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]

        assert client.post(
            f"/api/v1/read/workspace/trash/{tx}/purge", headers=_h(token)
        ).status_code == 404
        assert client.post(
            f"/api/v1/read/workspace/trash/{tx}/restore", headers=_h(token)
        ).status_code == 404
        assert client.post(
            "/api/v1/read/workspace/trash/tx_nope/purge", headers=_h(token)
        ).status_code == 404

        client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0}, headers=_h(token),
        )
        assert client.post(
            f"/api/v1/read/workspace/trash/{tx}/purge", headers=_h(token)
        ).status_code == 200
        assert client.post(
            f"/api/v1/read/workspace/trash/{tx}/purge", headers=_h(token)
        ).status_code == 404
        # purge 后读写该 id 均 404
        assert client.patch(
            f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0, "amount": 1.0}, headers=_h(token),
        ).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_trash_restore_then_batch_delete_again():
    # HARDENING: restore → 再批量删 → 再次进回收站(状态机自洽)。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-tr2@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]
        client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0}, headers=_h(token),
        )
        assert client.post(
            f"/api/v1/read/workspace/trash/{tx}/restore", headers=_h(token)
        ).json()["ok"] is True
        assert client.get("/api/v1/read/workspace/trash", headers=_h(token)).json()["total"] == 0
        r = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions/batch/delete",
            json={"tx_ids": [tx], "base_change_id": 0}, headers=_h(token),
        )
        assert r.status_code == 200
        assert client.get("/api/v1/read/workspace/trash", headers=_h(token)).json()["total"] == 1
    finally:
        app.dependency_overrides.clear()


def test_trash_response_has_no_days_left():
    # HARDENING: 回收站永久保留,响应不再含 days_left 字段。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-days@t.com")
        lg = _create_ledger(client, token)
        tx = _create_tx(client, token, lg).json()["entity_id"]
        client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0}, headers=_h(token),
        )
        item = client.get("/api/v1/read/workspace/trash", headers=_h(token)).json()["items"][0]
        assert "days_left" not in item
        assert item["sync_id"] == tx
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 多币种 / 余额调整
# ---------------------------------------------------------------------------


def test_tx_level_currency_without_rate_is_summed_one_to_one_without_flag():
    # ADVERSE FINDING: 交易级多币种(currencyCode != 账本币种)且 native_amount
    # 缺失时,统计把它按 1:1 直接加进账本本位币合计,且多币种标记
    # multi_currency_incomplete 保持 False(只有"账本"维度多币种才检查汇率)。
    # 证据: src/routers/read/workspace.py:1090 COALESCE(native_amount, amount)
    #       无 currency_code 检查;:1180 analytics_missing_rate 只看 ledger.currency。
    # 期望: 缺汇率的交易级外币要么被标记 multi_currency_incomplete=True,要么不计 1:1
    # 实际: 5 笔 100 元(其中 3 笔外币无折算)→ expense_total=901 且 incomplete=False
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-ccyrate@t.com")
        lg = _create_ledger(client, token)
        assert _create_tx(client, token, lg, amount=100.0, note="fx700",
                          currency_code="USD", native_amount=700.0).status_code == 200
        assert _create_tx(client, token, lg, amount=100.0, note="fxnone",
                          currency_code="USD").status_code == 200
        agg = _analytics(client, token, lg)
        assert agg["multi_currency_incomplete"] is True, (
            f"存在无汇率的外币交易却未标记折算不完整: expense_total={agg['summary']['expense_total']}"
        )
    finally:
        app.dependency_overrides.clear()


def test_ghost_account_adjustment_moves_ledger_balance():
    # ADVERSE FINDING: 余额调整记录只校验 account_id 非空字符串,不校验账户存在。
    # 用一个不存在的 account_id 调整 -12345 → 账本 balance 从 -100 变 -12445,
    # 而 /read/workspace/accounts 里根本没有这个账户 → 账本维度与账户维度对不上
    # ("钱从哪来"对不出账)。
    # 证据: src/snapshot_mutator.py:988-993 create_account_adjustment
    #       只查 account_id 非空;src/routers/read/_shared.py:530-539
    #       _projection_totals 无条件并入 adjustment 合计
    # 期望: 账户不存在 → 400/404(或调整被忽略);实际: 200 且账本余额被改动
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-ghostadj@t.com")
        lg = _create_ledger(client, token)
        assert _create_tx(client, token, lg, amount=100.0).status_code == 200
        before = client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(token)).json()["balance"]
        assert before == -100.0

        r = client.post(
            f"/api/v1/write/ledgers/{lg}/account-adjustments",
            json={
                "base_change_id": 0, "account_id": "acc_does_not_exist",
                "amount": -12345.0, "happened_at": "2026-05-06T12:30:00Z",
            },
            headers=_h(token),
        )
        assert r.status_code in (400, 404), f"幽灵账户调整应被拒绝,实际 {r.status_code}"

        after = client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(token)).json()["balance"]
        assert after == before, f"幽灵账户调整改动了账本余额: {before} → {after}"
    finally:
        app.dependency_overrides.clear()


def test_adjustment_amount_below_half_cent_rejected():
    # HARDENING: < 0.005 的调整被拒(schema 外的 mutator 校验)。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-tinyadj@t.com")
        lg = _create_ledger(client, token)
        r = client.post(
            f"/api/v1/write/ledgers/{lg}/account-adjustments",
            json={
                "base_change_id": 0, "account_id": "acc_a",
                "amount": 0.001, "happened_at": "2026-05-06T12:30:00Z",
            },
            headers=_h(token),
        )
        assert r.status_code == 400
    finally:
        app.dependency_overrides.clear()


def test_transfer_between_same_account_accepted():
    # HARDENING: from == to 的转账被接受(净额 0,余额口径自洽)。无校验是
    # 现状;真正会出问题的是缺 from/to 的转账(见下)。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-trsame@t.com")
        lg = _create_ledger(client, token)
        r = _create_tx(
            client, token, lg, amount=100.0, note="same", tx_type="transfer",
            from_account_id="acc_a", to_account_id="acc_a",
        )
        assert r.status_code == 200
    finally:
        app.dependency_overrides.clear()


def test_transfer_without_accounts_is_accepted():
    # HARDENING: 转账没有任何 from/to 账户也能建 —— 净值历史里这笔钱的
    # 流向彻底丢失(账户维度两个 SUM 都 miss),但账本余额口径仍吃 -amount。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-trnone@t.com")
        lg = _create_ledger(client, token)
        r = _create_tx(client, token, lg, amount=100.0, note="noacc", tx_type="transfer")
        assert r.status_code == 200, r.text
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 幂等
# ---------------------------------------------------------------------------


def test_idempotency_key_replay_and_payload_reuse_conflict():
    # HARDENING: 同 key 同 payload → replay(new_change_id 不变);
    # 同 key 不同 payload → 409 IDEMPOTENCY_KEY_REUSED。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-idem@t.com")
        lg = _create_ledger(client, token)
        body = {
            "base_change_id": 0, "tx_type": "expense", "amount": 7.0,
            "happened_at": "2026-05-06T12:30:00Z", "note": "idem",
        }
        hz = {**_h(token), "Idempotency-Key": "K1"}
        r1 = client.post(f"/api/v1/write/ledgers/{lg}/transactions", json=body, headers=hz)
        r2 = client.post(f"/api/v1/write/ledgers/{lg}/transactions", json=body, headers=hz)
        assert r1.status_code == r2.status_code == 200
        assert r2.json()["idempotency_replayed"] is True
        assert r2.json()["new_change_id"] == r1.json()["new_change_id"]
        assert len(_list_txs(client, token, lg)) == 1

        r3 = client.post(
            f"/api/v1/write/ledgers/{lg}/transactions",
            json={**body, "amount": 8.0}, headers=hz,
        )
        assert r3.status_code == 409, r3.text
    finally:
        app.dependency_overrides.clear()


def test_no_idempotency_key_double_submit_creates_two_transactions():
    # HARDENING: 不带 Idempotency-Key 时重复提交不去重(文档行为:客户端自己负责)。
    # 网络重试场景会静默多出一笔 —— 属契约而非缺陷。
    client = _make_client()
    try:
        token = _register_and_login(client, "adv-noidem@t.com")
        lg = _create_ledger(client, token)
        body = {
            "base_change_id": 0, "tx_type": "expense", "amount": 7.0,
            "happened_at": "2026-05-06T12:30:00Z", "note": "dup",
        }
        assert client.post(
            f"/api/v1/write/ledgers/{lg}/transactions", json=body, headers=_h(token)
        ).status_code == 200
        assert client.post(
            f"/api/v1/write/ledgers/{lg}/transactions", json=body, headers=_h(token)
        ).status_code == 200
        assert len(_list_txs(client, token, lg)) == 2
    finally:
        app.dependency_overrides.clear()


if __name__ == "__main__":
    pytest.main([__file__, "-q"])
