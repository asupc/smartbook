"""交易级多币种(.docs/multi-currency-ledger,SmartBook 侧)Cloud 端契约:

- read_tx_projection 加 currency_code / native_amount 两列(alembic 0018)
- 迁移回填语义:存量行 native_amount = amount(隐含汇率 1.0),已有值不覆盖
- upsert_tx 落两字段;旧 payload(无字段)保持 NULL —— 统计端 COALESCE 兜底
- merge spec:partial-push 不清掉已有折算;payload 带 amount 不带 nativeAmount
  时按隐含汇率联动缩放(旧 App 改金额,防 amount/native 失配)
- snapshot_mutator.update_transaction 改 amount 时联动 nativeAmount(L14):
  同币种跟随、外币按隐含汇率缩放、存量 item 不产字段、显式传入优先
- 账本维度统计端点按 COALESCE(native_amount, amount) 汇总;账户维度仍 amount

测试基建与 test_analytics_exclude_flags.py 同套:in-memory SQLite +
create_all + 真实 /sync/push 流;迁移回填语义照
test_tx_account_syncid_fallback.py 的「import 迁移模块执行 SQL」风格。
"""
from __future__ import annotations

import importlib.util
from datetime import datetime, timezone
from pathlib import Path

import sqlalchemy as sa
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import Ledger, ReadTxProjection


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


def _register_and_token(
    client: TestClient, email: str, *, device_id: str, client_type: str
) -> str:
    client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": device_id,
            "client_type": client_type,
            "device_name": f"pytest-{client_type}",
            "platform": "test",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": device_id,
            "client_type": client_type,
            "device_name": f"pytest-{client_type}",
            "platform": "test",
        },
    )
    return r.json()["access_token"]


def _two_tokens(client, email):
    app_token = _register_and_token(client, email, device_id="d-app", client_type="app")
    web_token = _register_and_token(client, email, device_id="d-web", client_type="web")
    return app_token, web_token


def _push(client, hdr, ledger_id, entity_type, sync_id, payload, *, action="upsert"):
    body = {
        "ledger_id": ledger_id,
        "entity_type": entity_type,
        "entity_sync_id": sync_id,
        "action": action,
        "updated_at": _iso(),
        "payload": payload,
    }
    r = client.post(
        "/api/v1/sync/push",
        headers=hdr,
        json={"device_id": "d-app", "changes": [body]},
    )
    assert r.status_code == 200, r.text
    return r.json()


def _ledger_internal_id(TS, external_id):
    with TS() as db:
        return db.scalar(select(Ledger.id).where(Ledger.external_id == external_id))


def _get_tx(TS, ledger_internal_id, sync_id):
    with TS() as db:
        return db.scalar(select(ReadTxProjection).where(
            ReadTxProjection.ledger_id == ledger_internal_id,
            ReadTxProjection.sync_id == sync_id,
        ))


def _load_migration_0018():
    path = (
        Path(__file__).parent.parent
        / "alembic" / "versions" / "0018_tx_multi_currency.py"
    )
    spec = importlib.util.spec_from_file_location("migration_0018", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------------------- #
# Task 1: models 两列 + 迁移回填语义                                           #
# --------------------------------------------------------------------------- #


def test_projection_has_currency_columns():
    """模型(→ create_all 建的表)带 currency_code / native_amount 两列,可空。"""
    client, TS = _make_client()
    try:
        db = TS()
        insp = sa.inspect(db.get_bind())
        cols = {c["name"]: c for c in insp.get_columns("read_tx_projection")}
        assert "currency_code" in cols
        assert "native_amount" in cols
        assert cols["currency_code"]["nullable"]
        assert cols["native_amount"]["nullable"]
        db.close()
    finally:
        app.dependency_overrides.clear()


def test_backfill_statement_semantics():
    """迁移 0018 的回填语义(照 0015 的 import-迁移-SQL 测试风格):
      - native_amount IS NULL 的存量行 → 回填 = amount
      - 已有 native_amount 的行 → 不改写
    """
    mod = _load_migration_0018()
    client, TS = _make_client()
    try:
        db = TS()
        # 两行:一行 NULL(待回填)、一行已折算(不许覆盖)。
        # in-memory SQLite 不强制外键,无需先插 ledgers/users 行。
        db.execute(sa.text(
            "INSERT INTO read_tx_projection"
            " (ledger_id, sync_id, user_id, tx_type, amount, happened_at,"
            "  native_amount, tx_index, source_change_id,"
            "  exclude_from_stats, exclude_from_budget)"
            " VALUES ('lg1', 'tx-null', 'u1', 'expense', 12.0, '2026-06-01',"
            "         NULL, 0, 0, 0, 0)"
        ))
        db.execute(sa.text(
            "INSERT INTO read_tx_projection"
            " (ledger_id, sync_id, user_id, tx_type, amount, happened_at,"
            "  native_amount, tx_index, source_change_id,"
            "  exclude_from_stats, exclude_from_budget)"
            " VALUES ('lg1', 'tx-set', 'u1', 'expense', 12.0, '2026-06-02',"
            "         86.4, 0, 0, 0, 0)"
        ))
        db.commit()

        db.execute(sa.text(mod.BACKFILL_STATEMENT))
        db.commit()

        rows = {
            r[0]: r[1]
            for r in db.execute(sa.text(
                "SELECT sync_id, native_amount FROM read_tx_projection"
            ))
        }
        assert rows["tx-null"] == 12.0   # 回填 = amount
        assert rows["tx-set"] == 86.4    # 已有折算不被覆盖
        db.close()
    finally:
        app.dependency_overrides.clear()


# --------------------------------------------------------------------------- #
# Task 2: upsert_tx 落字段 + merge spec 契约 + push 路径 amount 联动           #
# --------------------------------------------------------------------------- #


def _push_at(client, hdr, ledger_id, sync_id, payload, *, updated_at):
    """带显式 updated_at 的 push(LWW 需要第二次 push 时间戳更新)。"""
    r = client.post(
        "/api/v1/sync/push",
        headers=hdr,
        json={"device_id": "d-app", "changes": [{
            "ledger_id": ledger_id,
            "entity_type": "transaction",
            "entity_sync_id": sync_id,
            "action": "upsert",
            "updated_at": updated_at,
            "payload": payload,
        }]},
    )
    assert r.status_code == 200, r.text
    return r.json()


def test_upsert_tx_writes_currency_fields():
    """新 App push 带 currencyCode/nativeAmount → 投影两列落值。"""
    client, TS = _make_client()
    try:
        app_token, _ = _two_tokens(client, "mc-write@t.com")
        hdr = {"Authorization": f"Bearer {app_token}"}
        _push(client, hdr, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "多币账本", "currency": "CNY"})
        _push(client, hdr, "lg1", "transaction", "tx1",
              {"syncId": "tx1", "type": "expense", "amount": 12.0,
               "currencyCode": "USD", "nativeAmount": 86.4,
               "happenedAt": "2026-06-22T00:00:00+00:00"})
        lid = _ledger_internal_id(TS, "lg1")
        tx = _get_tx(TS, lid, "tx1")
        assert tx.currency_code == "USD"
        assert tx.native_amount == 86.4
        assert tx.amount == 12.0
    finally:
        app.dependency_overrides.clear()


def test_upsert_tx_legacy_payload_leaves_null():
    """旧 App payload 无两字段 → 落 NULL(统计端 COALESCE 兜底),
    不能被 _as_float 默认值变成 0.0。"""
    client, TS = _make_client()
    try:
        app_token, _ = _two_tokens(client, "mc-legacy@t.com")
        hdr = {"Authorization": f"Bearer {app_token}"}
        _push(client, hdr, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "旧账本", "currency": "CNY"})
        _push(client, hdr, "lg1", "transaction", "tx2",
              {"syncId": "tx2", "type": "expense", "amount": 5.0,
               "happenedAt": "2026-06-22T00:00:00+00:00"})
        lid = _ledger_internal_id(TS, "lg1")
        tx = _get_tx(TS, lid, "tx2")
        assert tx.currency_code is None
        assert tx.native_amount is None
        assert tx.amount == 5.0
    finally:
        app.dependency_overrides.clear()


def test_mobile_push_transaction_partial_update_keeps_native_amount():
    """merge 契约(照 budget 同款):partial push 只改 note(amount 未变),
    已有的 currency_code / native_amount 必须保留 —— 旧 App 改备注不能
    抹掉折算快照。"""
    client, TS = _make_client()
    try:
        app_token, _ = _two_tokens(client, "mc-partial@t.com")
        hdr = {"Authorization": f"Bearer {app_token}"}
        _push(client, hdr, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "L", "currency": "CNY"})
        _push_at(client, hdr, "lg1", "tx3",
                 {"syncId": "tx3", "type": "expense", "amount": 12.0,
                  "currencyCode": "USD", "nativeAmount": 86.4,
                  "happenedAt": "2026-06-22T00:00:00+00:00"},
                 updated_at="2026-07-12T00:00:00+00:00")
        # 旧 App 只改备注:payload 不带两字段、amount 原值
        _push_at(client, hdr, "lg1", "tx3",
                 {"syncId": "tx3", "amount": 12.0, "note": "改个备注"},
                 updated_at="2026-07-12T00:01:00+00:00")
        lid = _ledger_internal_id(TS, "lg1")
        tx = _get_tx(TS, lid, "tx3")
        assert tx.note == "改个备注"
        assert tx.currency_code == "USD", "partial update 抹掉了 currency_code"
        assert tx.native_amount == 86.4, "partial update 抹掉了折算快照"
    finally:
        app.dependency_overrides.clear()


def test_merge_scales_native_on_amount_change_foreign():
    """旧 App 改金额(payload 带 amount 不带 nativeAmount):外币交易按该笔
    隐含汇率等比缩放,防 amount/native 失配(12→24 则 86.4→172.8)。"""
    client, TS = _make_client()
    try:
        app_token, _ = _two_tokens(client, "mc-scale@t.com")
        hdr = {"Authorization": f"Bearer {app_token}"}
        _push(client, hdr, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "L", "currency": "CNY"})
        _push_at(client, hdr, "lg1", "tx4",
                 {"syncId": "tx4", "type": "expense", "amount": 12.0,
                  "currencyCode": "USD", "nativeAmount": 86.4,
                  "happenedAt": "2026-06-22T00:00:00+00:00"},
                 updated_at="2026-07-12T00:00:00+00:00")
        _push_at(client, hdr, "lg1", "tx4",
                 {"syncId": "tx4", "amount": 24.0},
                 updated_at="2026-07-12T00:01:00+00:00")
        lid = _ledger_internal_id(TS, "lg1")
        tx = _get_tx(TS, lid, "tx4")
        assert tx.amount == 24.0
        assert tx.native_amount is not None
        assert abs(tx.native_amount - 172.8) < 1e-9, (
            f"外币改金额应按隐含汇率缩放,got {tx.native_amount}"
        )
        assert tx.currency_code == "USD"
    finally:
        app.dependency_overrides.clear()


# --------------------------------------------------------------------------- #
# Task 2.5: snapshot_mutator amount 联动 nativeAmount(L14)                    #
# --------------------------------------------------------------------------- #


def _mutate_tx(item: dict, payload: dict) -> dict:
    """构造单交易 snapshot,跑 update_transaction,返回改后的 item。"""
    from src.snapshot_mutator import update_transaction

    snapshot = {"ledgerName": "L", "currency": "CNY", "items": [dict(item)]}
    out = update_transaction(snapshot, item["syncId"], payload)
    return out["items"][0]


def test_mutator_amount_change_syncs_native_same_currency():
    """同币种(native==amount,隐含汇率 1)→ Web 改 amount 后 native 跟随新值。
    不联动的话账本统计(COALESCE 读 native)会一直显示旧金额 —— L14 的核心场景。"""
    item = {"syncId": "tx-1", "type": "expense", "amount": 10.0,
            "nativeAmount": 10.0, "happenedAt": "2026-06-22T00:00:00+00:00"}
    out = _mutate_tx(item, {"amount": 25.0})
    assert out["amount"] == 25.0
    assert out["nativeAmount"] == 25.0


def test_mutator_amount_change_scales_native_foreign():
    """外币(隐含汇率 7.2)→ 按隐含汇率等比缩放,保持该笔记账时汇率。"""
    item = {"syncId": "tx-2", "type": "expense", "amount": 12.0,
            "currencyCode": "USD", "nativeAmount": 86.4,
            "happenedAt": "2026-06-22T00:00:00+00:00"}
    out = _mutate_tx(item, {"amount": 24.0})
    assert out["amount"] == 24.0
    assert abs(out["nativeAmount"] - 172.8) < 1e-9


def test_mutator_amount_change_ignores_legacy_item():
    """存量 item(无 nativeAmount key,旧 App 记的)→ 不产生该字段;
    upsert 落 NULL,统计 COALESCE 回退新 amount,天然正确。"""
    item = {"syncId": "tx-3", "type": "expense", "amount": 10.0,
            "happenedAt": "2026-06-22T00:00:00+00:00"}
    out = _mutate_tx(item, {"amount": 25.0})
    assert out["amount"] == 25.0
    assert "nativeAmount" not in out


def test_mutator_explicit_native_amount_wins():
    """payload 显式带 native_amount(未来 Web 折算录入)→ 尊重传入值,
    不做联动计算。"""
    item = {"syncId": "tx-4", "type": "expense", "amount": 12.0,
            "currencyCode": "USD", "nativeAmount": 86.4,
            "happenedAt": "2026-06-22T00:00:00+00:00"}
    out = _mutate_tx(item, {"amount": 24.0, "native_amount": 168.0})
    assert out["amount"] == 24.0
    assert out["nativeAmount"] == 168.0


def test_mutator_amount_unchanged_keeps_native():
    """amount 没变(只改备注)→ 折算快照不动。"""
    item = {"syncId": "tx-5", "type": "expense", "amount": 12.0,
            "currencyCode": "USD", "nativeAmount": 86.4,
            "happenedAt": "2026-06-22T00:00:00+00:00"}
    out = _mutate_tx(item, {"note": "只改备注"})
    assert out["note"] == "只改备注"
    assert out["nativeAmount"] == 86.4


def test_merge_follows_amount_same_currency():
    """旧 App 改金额:同币种交易(native==amount,隐含汇率 1)native 跟随新值,
    否则账本统计会显示旧金额。"""
    client, TS = _make_client()
    try:
        app_token, _ = _two_tokens(client, "mc-follow@t.com")
        hdr = {"Authorization": f"Bearer {app_token}"}
        _push(client, hdr, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "L", "currency": "CNY"})
        _push_at(client, hdr, "lg1", "tx5",
                 {"syncId": "tx5", "type": "expense", "amount": 10.0,
                  "currencyCode": "CNY", "nativeAmount": 10.0,
                  "happenedAt": "2026-06-22T00:00:00+00:00"},
                 updated_at="2026-07-12T00:00:00+00:00")
        _push_at(client, hdr, "lg1", "tx5",
                 {"syncId": "tx5", "amount": 25.0},
                 updated_at="2026-07-12T00:01:00+00:00")
        lid = _ledger_internal_id(TS, "lg1")
        tx = _get_tx(TS, lid, "tx5")
        assert tx.amount == 25.0
        assert tx.native_amount == 25.0, (
            f"同币种改金额 native 应跟随,got {tx.native_amount}"
        )
    finally:
        app.dependency_overrides.clear()


# --------------------------------------------------------------------------- #
# Task 3: 账本维度统计端点折 native_amount;账户维度回归锁                      #
# --------------------------------------------------------------------------- #


def _seed_mixed_currency_ledger(client, hdr):
    """CNY 本位币账本:USD 账户外币支出(amount=12, native=86.4)+
    本位币支出(amount=100, native=100)。happenedAt 用当前时间,
    落在预算「当前周期」内。"""
    _push(client, hdr, "lg1", "ledger", "lg1",
          {"syncId": "lg1", "ledgerName": "多币账本", "currency": "CNY"})
    _push(client, hdr, "lg1", "account", "acc-usd",
          {"syncId": "acc-usd", "name": "Chase", "type": "bank",
           "currency": "USD"})
    _push(client, hdr, "lg1", "transaction", "tx-usd",
          {"syncId": "tx-usd", "type": "expense", "amount": 12.0,
           "currencyCode": "USD", "nativeAmount": 86.4,
           "accountId": "acc-usd", "accountName": "Chase",
           "categoryName": "餐饮", "happenedAt": _iso()})
    _push(client, hdr, "lg1", "transaction", "tx-cny",
          {"syncId": "tx-cny", "type": "expense", "amount": 100.0,
           "currencyCode": "CNY", "nativeAmount": 100.0,
           "categoryName": "餐饮", "happenedAt": _iso()})


def test_ledger_totals_use_native_amount():
    """账本级 income/expense(_projection_totals → /read/ledgers)按
    COALESCE(native_amount, amount) 汇总:86.4 + 100 = 186.4,不是 112。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-totals@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _seed_mixed_currency_ledger(client, hdr_app)

        r = client.get("/api/v1/read/ledgers", headers=hdr_web)
        assert r.status_code == 200, r.text
        row = next(x for x in r.json() if x["ledger_id"] == "lg1")
        assert abs(row["expense_total"] - 186.4) < 1e-6, (
            f"账本支出应折本位币 186.4,got {row['expense_total']}"
        )
    finally:
        app.dependency_overrides.clear()


def test_single_currency_ledger_totals_unchanged():
    """纯本位币账本(native==amount,迁移回填态)汇总与旧口径一致(回归锁)。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-single@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _push(client, hdr_app, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "单币账本", "currency": "CNY"})
        _push(client, hdr_app, "lg1", "transaction", "t1",
              {"syncId": "t1", "type": "expense", "amount": 30.0,
               "currencyCode": "CNY", "nativeAmount": 30.0,
               "happenedAt": _iso()})
        _push(client, hdr_app, "lg1", "transaction", "t2",
              {"syncId": "t2", "type": "income", "amount": 50.0,
               "currencyCode": "CNY", "nativeAmount": 50.0,
               "happenedAt": _iso()})
        r = client.get("/api/v1/read/ledgers", headers=hdr_web)
        row = next(x for x in r.json() if x["ledger_id"] == "lg1")
        assert row["expense_total"] == 30.0
        assert row["income_total"] == 50.0
    finally:
        app.dependency_overrides.clear()


def test_coalesce_fallback_for_null_native():
    """native_amount 为 NULL 的行(旧 App 推的)统计回退 amount,不为 0。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-null@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _push(client, hdr_app, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "旧账本", "currency": "CNY"})
        _push(client, hdr_app, "lg1", "transaction", "t1",
              {"syncId": "t1", "type": "expense", "amount": 42.0,
               "happenedAt": _iso()})   # 旧 payload:无两字段 → NULL
        r = client.get("/api/v1/read/ledgers", headers=hdr_web)
        row = next(x for x in r.json() if x["ledger_id"] == "lg1")
        assert row["expense_total"] == 42.0
    finally:
        app.dependency_overrides.clear()


def test_analytics_use_native_amount():
    """workspace/analytics(账本/跨账本趋势)按 native ?? amount 累加:
    支出汇总 186.4;分类排行同口径。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-ana@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _seed_mixed_currency_ledger(client, hdr_app)

        r = client.get(
            "/api/v1/read/workspace/analytics",
            headers=hdr_web,
            params={"scope": "all", "metric": "expense"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert abs(body["summary"]["expense_total"] - 186.4) < 1e-6
        ranks = {row["category_name"]: row["total"] for row in body["category_ranks"]}
        assert abs(ranks["餐饮"] - 186.4) < 1e-6
    finally:
        app.dependency_overrides.clear()


def test_budget_usage_uses_native_amount():
    """预算用量按 COALESCE(native_amount, amount):预算金额本身是账本本位币,
    用量必须同计量单位(86.4 + 100 = 186.4,不是 112)。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-bud@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _seed_mixed_currency_ledger(client, hdr_app)
        _push(client, hdr_app, "lg1", "budget", "bud1",
              {"syncId": "bud1", "type": "total", "amount": 1000.0,
               "period": "monthly", "startDay": 1, "enabled": True})

        r = client.get("/api/v1/read/ledgers/lg1/budgets/usage", headers=hdr_web)
        assert r.status_code == 200, r.text
        items = {x["budget_id"]: x["used"] for x in r.json()["items"]}
        assert abs(items["bud1"] - 186.4) < 1e-6, (
            f"预算用量应折本位币 186.4,got {items.get('bud1')}"
        )
    finally:
        app.dependency_overrides.clear()


# --------------------------------------------------------------------------- #
# Web 写路径:create/update 显式带两字段(Web 币种录入)                          #
# --------------------------------------------------------------------------- #


def test_mutator_create_with_currency_fields():
    """Web 新建交易显式带 currency_code/native_amount → snapshot item 落
    camelCase 两字段(不带则不产生 key,旧行为)。"""
    from src.snapshot_mutator import create_transaction

    out, tx_id = create_transaction(
        {"items": []},
        {"tx_type": "expense", "amount": 12.0,
         "happened_at": "2026-07-12T00:00:00Z",
         "currency_code": "USD", "native_amount": 86.4},
    )
    item = next(it for it in out["items"] if it["syncId"] == tx_id)
    assert item["currencyCode"] == "USD"
    assert item["nativeAmount"] == 86.4

    out2, tx_id2 = create_transaction(
        {"items": []},
        {"tx_type": "expense", "amount": 5.0,
         "happened_at": "2026-07-12T00:00:00Z"},
    )
    item2 = next(it for it in out2["items"] if it["syncId"] == tx_id2)
    assert "currencyCode" not in item2
    assert "nativeAmount" not in item2


def test_web_create_tx_with_currency_lands_in_projection():
    """POST /write/ledgers/{id}/transactions 带两字段 → 投影两列落值
    (schema 白名单不放行的话 pydantic 会静默丢字段,这条测试锁住白名单)。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-webwrite@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}",
                   "X-Device-ID": "d-web"}
        _push(client, hdr_app, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "L", "currency": "CNY"})

        r = client.post(
            "/api/v1/write/ledgers/lg1/transactions",
            headers=hdr_web,
            json={"base_change_id": 0, "tx_type": "expense", "amount": 12.0,
                  "happened_at": "2026-07-12T00:00:00+00:00",
                  "currency_code": "USD", "native_amount": 86.4},
        )
        assert r.status_code == 200, r.text
        lid = _ledger_internal_id(TS, "lg1")
        with TS() as db:
            row = db.scalar(select(ReadTxProjection).where(
                ReadTxProjection.ledger_id == lid))
            assert row.currency_code == "USD"
            assert abs(row.native_amount - 86.4) < 1e-9
    finally:
        app.dependency_overrides.clear()


def test_ledger_totals_exclude_flagged_transactions():
    """账本卡片(_projection_totals)的收支排除 exclude_from_stats 标记笔
    (#340 D1;此前只有 analytics 过滤 → 两处统计对不上,反馈18)。
    笔数不过滤(标记笔仍计入账单列表)。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-excl@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _push(client, hdr_app, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "L", "currency": "CNY"})
        _push(client, hdr_app, "lg1", "transaction", "t1",
              {"syncId": "t1", "type": "expense", "amount": 100.0,
               "happenedAt": _iso()})
        _push(client, hdr_app, "lg1", "transaction", "t2",
              {"syncId": "t2", "type": "income", "amount": 1.0,
               "excludeFromStats": True, "happenedAt": _iso()})

        r = client.get("/api/v1/read/ledgers", headers=hdr_web)
        row = next(x for x in r.json() if x["ledger_id"] == "lg1")
        assert row["expense_total"] == 100.0
        assert row["income_total"] == 0.0, "标记笔不得计入收入"
        assert row["transaction_count"] == 2, "笔数不过滤(D1)"
        # D5:余额=钱的位置,标记笔仍计入(+1 收入 -100 支出 = -99)
        assert row["balance"] == -99.0, "余额必须含标记笔(D5,对齐 App)"
    finally:
        app.dependency_overrides.clear()


def test_projection_row_to_tx_dict_carries_currency_fields():
    """web PATCH update_tx 快路径的 prev_item 序列化器必须带 currencyCode/
    nativeAmount(反馈:审计发现的 write-path 漏字段)。漏了它 → mutator 的
    rescale 守卫永不触发 → 编辑外币交易时投影两字段被写 NULL、折算被抹掉。"""
    from src.routers.write._shared import _projection_row_to_tx_dict

    row = ReadTxProjection(
        ledger_id="lg1", sync_id="tx1", user_id="u1",
        tx_type="expense", amount=100.0,
        happened_at=datetime(2026, 7, 12, tzinfo=timezone.utc),
        currency_code="USD", native_amount=720.0,
    )
    item = _projection_row_to_tx_dict(row)
    assert item["currencyCode"] == "USD"
    assert item["nativeAmount"] == 720.0

    # 本位币(NULL)行不产生 key(统计端 COALESCE 兜底)
    row2 = ReadTxProjection(
        ledger_id="lg1", sync_id="tx2", user_id="u1",
        tx_type="expense", amount=5.0,
        happened_at=datetime(2026, 7, 12, tzinfo=timezone.utc),
    )
    item2 = _projection_row_to_tx_dict(row2)
    assert "currencyCode" not in item2
    assert "nativeAmount" not in item2


def test_web_ledger_currency_change_recalcs_projection(monkeypatch):
    """Web 改主币种(反馈20):mutate 重算 snapshot.items 折算 → diff 基建自动
    生成每笔 tx change + 更新投影。旧本位币(NULL/CNY)交易按新本位币折算,
    NULL currencyCode 显式落旧币种;缺汇率退化 =amount。"""
    from src.services.exchange_rate import fetcher as rate_fetcher

    class _FakeRow:
        payload_json = {"cny": 20.0, "usd": 0.14}  # 1 JPY = 20 CNY? 方向:1 base(JPY)=x quote

    async def fake_get_rates(db, base):
        assert base == "JPY"
        return _FakeRow(), False

    monkeypatch.setattr(rate_fetcher, "get_rates", fake_get_rates)

    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-webccy@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}",
                   "X-Device-ID": "d-web"}
        _push(client, hdr_app, "lg1", "ledger", "lg1",
              {"syncId": "lg1", "ledgerName": "L", "currency": "CNY"})
        # 一笔 CNY 交易(currencyCode 显式)
        _push(client, hdr_app, "lg1", "transaction", "t-cny",
              {"syncId": "t-cny", "type": "expense", "amount": 100.0,
               "currencyCode": "CNY", "nativeAmount": 100.0,
               "happenedAt": _iso()})

        r = client.patch(
            "/api/v1/write/ledgers/lg1/meta",
            headers=hdr_web,
            json={"base_change_id": 0, "currency": "JPY"},
        )
        assert r.status_code == 200, r.text

        lid = _ledger_internal_id(TS, "lg1")
        tx = _get_tx(TS, lid, "t-cny")
        # 1 JPY = 20 CNY → 100 CNY 折 JPY = 100/20*... 等等:rates[cny]=20
        # 表示 1 JPY = 20 CNY?fetcher payload 是 base→quote:1 JPY = 20 CNY
        # 不现实但作为测试值:100 CNY / 20 = 5 JPY
        assert tx.currency_code == "CNY"
        assert abs(tx.native_amount - 5.0) < 1e-9, tx.native_amount
        # 生成了该笔的 change(App pull 后本地同步重算)
        from src.models import SyncChange
        with TS() as db:
            n = db.query(SyncChange).filter_by(
                entity_type="transaction", entity_sync_id="t-cny").count()
            assert n >= 2, "改主币种应为受影响交易生成新 change"
    finally:
        app.dependency_overrides.clear()


# --------------------------------------------------------------------------- #
# CSV 导出/导入:币种列(反馈10)                                                 #
# --------------------------------------------------------------------------- #


def test_csv_export_includes_currency_column():
    """transactions.csv 12 列含「币种」;外币交易导出其 currencyCode,
    历史 NULL 行按账本本位币兜底。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-csv@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _seed_mixed_currency_ledger(client, hdr_app)
        _push(client, hdr_app, "lg1", "transaction", "tx-legacy",
              {"syncId": "tx-legacy", "type": "expense", "amount": 5.0,
               "happenedAt": _iso()})  # NULL currency → 本位币兜底

        r = client.get(
            "/api/v1/read/workspace/transactions.csv",
            headers=hdr_web, params={"lang": "zh-CN"},
        )
        assert r.status_code == 200, r.text
        lines = r.text.lstrip("\ufeff").splitlines()
        header = lines[0].split(",")
        assert header[4] == "币种", header
        body = "\n".join(lines[1:])
        assert "USD" in body
        assert "CNY" in body  # 本位币交易 + legacy 兜底
    finally:
        app.dependency_overrides.clear()


def test_import_recognizes_currency_column():
    """导入:表头「币种」被自动识别进 mapping;transformer 落
    ImportTransaction.currency_code(脏值回退 None)。"""
    from src.services.import_data.parser import parse_csv_text
    from src.services.import_data.transformer import apply_mapping

    csv_text = (
        "类型,金额,币种,时间,分类\n"
        "支出,1000,JPY,2026-07-01 12:00:00,餐饮\n"
        "支出,50,,2026-07-02 12:00:00,餐饮\n"
        "支出,20,不是币种,2026-07-03 12:00:00,餐饮\n"
    )
    data = parse_csv_text(raw_text=csv_text)
    assert data.suggested_mapping.currency == "币种"
    txs, errors, _warnings = apply_mapping(
        rows=data.rows, mapping=data.suggested_mapping)
    assert not errors, errors
    assert txs[0].currency_code == "JPY"
    assert txs[1].currency_code is None   # 空值 → 本位币语义
    assert txs[2].currency_code is None   # 脏值回退


# --------------------------------------------------------------------------- #
# snapshot_builder:full pull 重建的 item 必须带两字段                          #
# --------------------------------------------------------------------------- #


def test_snapshot_builder_keeps_currency_fields():
    """/sync/full 的 snapshot 从 projection 懒构建(snapshot_builder.build):
    tx item 必须带 currencyCode/nativeAmount,否则新 App full pull 后所有
    外币交易折算丢失(App 端 apply 缺省 nativeAmount=amount 退化 1:1),
    且 Web 写路径拿到的 prev snapshot 缺字段会让 mutator L14 联动失效。
    旧数据(NULL)不产生 key,payload 保持干净。"""
    from src.snapshot_builder import build

    client, TS = _make_client()
    try:
        app_token, _ = _two_tokens(client, "mc-snap@t.com")
        hdr = {"Authorization": f"Bearer {app_token}"}
        _seed_mixed_currency_ledger(client, hdr)
        _push(client, hdr, "lg1", "transaction", "tx-legacy",
              {"syncId": "tx-legacy", "type": "expense", "amount": 5.0,
               "happenedAt": _iso()})   # 旧 payload → 投影 NULL

        with TS() as db:
            ledger = db.scalar(select(Ledger).where(Ledger.external_id == "lg1"))
            snap = build(db, ledger)
        by_id = {it["syncId"]: it for it in snap["items"]}
        assert by_id["tx-usd"]["currencyCode"] == "USD"
        assert abs(by_id["tx-usd"]["nativeAmount"] - 86.4) < 1e-9
        assert "nativeAmount" not in by_id["tx-legacy"]
        assert "currencyCode" not in by_id["tx-legacy"]
    finally:
        app.dependency_overrides.clear()


# --------------------------------------------------------------------------- #
# Task 4(server 侧):读端点吐出两字段(Web 单笔展示的数据来源)                    #
# --------------------------------------------------------------------------- #


def test_read_transactions_expose_currency_fields():
    """/read/ledgers/{id}/transactions 与 /read/workspace/transactions 返回
    currency_code / native_amount(Web 单笔展示原币 + ≈ 本位币行的数据来源);
    旧数据(NULL)返回 null 不炸。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-read@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _seed_mixed_currency_ledger(client, hdr_app)

        r = client.get("/api/v1/read/ledgers/lg1/transactions", headers=hdr_web)
        assert r.status_code == 200, r.text
        by_id = {x["id"]: x for x in r.json()}
        assert by_id["tx-usd"]["currency_code"] == "USD"
        assert abs(by_id["tx-usd"]["native_amount"] - 86.4) < 1e-9
        assert by_id["tx-cny"]["currency_code"] == "CNY"

        r2 = client.get("/api/v1/read/workspace/transactions", headers=hdr_web)
        assert r2.status_code == 200, r2.text
        items = {x["id"]: x for x in r2.json()["items"]}
        assert items["tx-usd"]["currency_code"] == "USD"
        assert abs(items["tx-usd"]["native_amount"] - 86.4) < 1e-9
    finally:
        app.dependency_overrides.clear()


def test_account_dimension_keeps_amount():
    """账户维度(workspace/accounts 按 account_sync_id 聚合)仍用 amount 原币
    (回归锁,防误改):USD 账户支出 = $12,不是折算后的 86.4。"""
    client, TS = _make_client()
    try:
        app_token, web_token = _two_tokens(client, "mc-acc@t.com")
        hdr_app = {"Authorization": f"Bearer {app_token}"}
        hdr_web = {"Authorization": f"Bearer {web_token}"}
        _seed_mixed_currency_ledger(client, hdr_app)

        r = client.get("/api/v1/read/workspace/accounts", headers=hdr_web)
        assert r.status_code == 200, r.text
        acc = next(x for x in r.json() if x["name"] == "Chase")
        assert acc["expense_total"] == 12.0, (
            f"账户维度必须保持原币 12.0,got {acc['expense_total']}"
        )
    finally:
        app.dependency_overrides.clear()
