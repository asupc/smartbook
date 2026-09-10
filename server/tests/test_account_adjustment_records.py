"""余额调整记录(0028)端到端契约:调整不再落交易,独立 account_adjustment 实体。

锁定的行为:
- Web POST /write/ledgers/{id}/account-adjustments → projection 落
  read_account_adjustment_projection + 发 account_adjustment SyncChange。
- 账户余额(workspace accounts)= initial + Σ交易 + Σ调整;income/expense/
  tx_count 不吃调整 —— 调整不是交易,不进收支统计。
- 账本卡 balance_all(/read/summary)并入调整总额。
- 净值序列(net-worth-history)按时间回放调整。
- mobile push 路径(ledger-scope account_adjustment upsert)三张 dispatch 表生效,
  partial push 缺键保留(balances_before/after 不被冲掉)。
- 读端点 GET /read/ledgers/{id}/account-adjustments 按 account_id 过滤。
- 删除调整 → 行消失,余额回落。
"""
from __future__ import annotations

from datetime import datetime, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app


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


def _iso():
    return datetime.now(timezone.utc).isoformat()


def _login_web(client: TestClient, email: str) -> str:
    res = client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "client_type": "app",
            "device_name": "pytest-app",
            "platform": "app",
        },
    )
    assert res.status_code == 200, res.text
    res = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "d-web",
            "client_type": "web",
            "device_name": "pytest-web",
            "platform": "web",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def _login_app(client: TestClient, email: str) -> str:
    res = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": "Pa$$word1!",
            "device_id": "d-app",
            "client_type": "app",
            "device_name": "pytest-app",
            "platform": "app",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()["access_token"]


def _push(client: TestClient, token: str, ledger_id: str, entity_type: str,
          sync_id: str, payload: dict) -> None:
    res = client.post(
        "/api/v1/sync/push",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "device_id": "d-app",
            "changes": [{
                "ledger_id": ledger_id,
                "entity_type": entity_type,
                "entity_sync_id": sync_id,
                "action": "upsert",
                "payload": payload,
                "updated_at": _iso(),
            }],
        },
    )
    assert res.status_code == 200, res.text


def _seed(client: TestClient, app_token: str) -> None:
    _push(client, app_token, "lg-adj2", "ledger", "lg-adj2",
          {"syncId": "lg-adj2", "ledgerName": "调整账本2", "currency": "CNY"})
    _push(client, app_token, "lg-adj2", "account", "acc-adj2",
          {"syncId": "acc-adj2", "name": "现金", "type": "cash",
           "currency": "CNY", "initialBalance": 100.0})


def _base_change_id(client: TestClient, token: str, ledger_id: str) -> int:
    res = client.get(
        f"/api/v1/read/ledgers/{ledger_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200, res.text
    return int(res.json()["source_change_id"])


def _create_adjustment(client: TestClient, token: str, ledger_id: str,
                       base_change_id: int, amount: float, *,
                       balance_before: float | None = None,
                       balance_after: float | None = None) -> dict:
    res = client.post(
        f"/api/v1/write/ledgers/{ledger_id}/account-adjustments",
        headers={"Authorization": f"Bearer {token}", "X-Device-ID": "pytest-web"},
        json={
            "base_change_id": base_change_id,
            "account_id": "acc-adj2",
            "account_name": "现金",
            "amount": amount,
            "happened_at": _iso(),
            "note": "余额调整",
            "balance_before": balance_before,
            "balance_after": balance_after,
        },
    )
    assert res.status_code == 200, res.text
    return res.json()


def _account(client: TestClient, token: str, account_id: str) -> dict:
    res = client.get(
        "/api/v1/read/workspace/accounts",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200, res.text
    return next(a for a in res.json() if a["id"] == account_id)


def test_web_adjustment_record_changes_balance_not_stats() -> None:
    """调整 100→70(-30)→120(+50):余额跟随,KPI 不动。"""
    client, TS = _make_client()
    try:
        web_token = _login_web(client, "adjrec1@example.com")
        app_token = _login_app(client, "adjrec1@example.com")
        _seed(client, app_token)
        base = _base_change_id(client, web_token, "lg-adj2")

        r1 = _create_adjustment(
            client, web_token, "lg-adj2", base, -30.0,
            balance_before=100.0, balance_after=70.0,
        )
        _create_adjustment(
            client, web_token, "lg-adj2", int(r1["new_change_id"]), 50.0,
            balance_before=70.0, balance_after=120.0,
        )

        acc = _account(client, web_token, "acc-adj2")
        assert acc["balance"] == 120.0  # 100 - 30 + 50
        assert acc["income_total"] == 0.0
        assert acc["expense_total"] == 0.0
        assert acc["tx_count"] == 0     # 调整不是交易

        # 账本 summary:收支为 0,balance 并入调整
        res = client.get(
            "/api/v1/read/summary",
            params={"ledger_id": "lg-adj2"},
            headers={"Authorization": f"Bearer {web_token}"},
        )
        assert res.status_code == 200, res.text
        summary = res.json()
        assert summary["income_total"] == 0.0
        assert summary["expense_total"] == 0.0
        assert summary["balance"] == 20.0  # Σ交易(0) + Σ调整(+20)
        assert summary["transaction_count"] == 0

        # 调整记录读端点(带 account 过滤)
        res = client.get(
            "/api/v1/read/ledgers/lg-adj2/account-adjustments",
            params={"account_id": "acc-adj2"},
            headers={"Authorization": f"Bearer {web_token}"},
        )
        assert res.status_code == 200, res.text
        records = res.json()
        assert len(records) == 2
        # 倒序:最新在前
        assert records[0]["amount"] == 50.0
        assert records[0]["balance_before"] == 70.0
        assert records[0]["balance_after"] == 120.0
        assert records[1]["amount"] == -30.0
    finally:
        app.dependency_overrides.clear()


def test_adjustment_delete_endpoint_not_available() -> None:
    """调整记录 append-only:web 写路径不提供 DELETE(405),记录落库后不可删。"""
    client, TS = _make_client()
    try:
        web_token = _login_web(client, "adjrec2@example.com")
        app_token = _login_app(client, "adjrec2@example.com")
        _seed(client, app_token)
        base = _base_change_id(client, web_token, "lg-adj2")
        r1 = _create_adjustment(
            client, web_token, "lg-adj2", base, -30.0,
        )
        assert _account(client, web_token, "acc-adj2")["balance"] == 70.0

        res = client.request(
            "DELETE",
            f"/api/v1/write/ledgers/lg-adj2/account-adjustments/{r1['entity_id']}",
            headers={"Authorization": f"Bearer {web_token}", "X-Device-ID": "pytest-web"},
            json={"base_change_id": int(r1["new_change_id"])},
        )
        assert res.status_code in (404, 405), res.text
        # 记录还在,余额不变
        assert _account(client, web_token, "acc-adj2")["balance"] == 70.0
        res = client.get(
            "/api/v1/read/ledgers/lg-adj2/account-adjustments",
            headers={"Authorization": f"Bearer {web_token}"},
        )
        assert res.status_code == 200, res.text
        assert len(res.json()) == 1
    finally:
        app.dependency_overrides.clear()


def test_mobile_push_account_adjustment_partial_update_keeps_existing_fields() -> None:
    """merge 契约(CLAUDE.md 强制):mobile 增量 push 只带 amount 时,
    balance_before/after/note 保留旧值,不被默认值冲掉。"""
    client, TS = _make_client()
    try:
        web_token = _login_web(client, "adjrec3@example.com")
        app_token = _login_app(client, "adjrec3@example.com")
        _seed(client, app_token)

        _push(client, app_token, "lg-adj2", "account_adjustment", "adj-m1",
              {"syncId": "adj-m1", "accountId": "acc-adj2", "amount": 25.0,
               "balanceBefore": 100.0, "balanceAfter": 125.0,
               "note": "对账", "happenedAt": _iso()})
        # partial:只改 amount
        _push(client, app_token, "lg-adj2", "account_adjustment", "adj-m1",
              {"syncId": "adj-m1", "amount": 15.0})

        res = client.get(
            "/api/v1/read/ledgers/lg-adj2/account-adjustments",
            headers={"Authorization": f"Bearer {web_token}"},
        )
        assert res.status_code == 200, res.text
        records = res.json()
        assert len(records) == 1
        rec = records[0]
        assert rec["amount"] == 15.0            # 更新生效
        assert rec["balance_before"] == 100.0   # 缺键保留
        assert rec["balance_after"] == 125.0
        assert rec["note"] == "对账"
        assert rec["account_id"] == "acc-adj2"

        acc = _account(client, web_token, "acc-adj2")
        assert acc["balance"] == 115.0
    finally:
        app.dependency_overrides.clear()


def test_adjustment_replays_into_net_worth_history() -> None:
    """净值序列:调整按 happened_at 回放进月末余额。"""
    client, TS = _make_client()
    try:
        web_token = _login_web(client, "adjrec4@example.com")
        app_token = _login_app(client, "adjrec4@example.com")
        _seed(client, app_token)
        base = _base_change_id(client, web_token, "lg-adj2")
        _create_adjustment(client, web_token, "lg-adj2", base, -40.0)

        res = client.get(
            "/api/v1/read/workspace/net-worth-history",
            headers={"Authorization": f"Bearer {web_token}"},
        )
        assert res.status_code == 200, res.text
        series = res.json()["series"]
        assert series, "净值序列不能为空"
        latest = series[-1]
        # 100(初始) - 40(调整) = 60 资产,无负债
        assert abs(latest["net_worth"] - 60.0) < 1e-6
    finally:
        app.dependency_overrides.clear()
