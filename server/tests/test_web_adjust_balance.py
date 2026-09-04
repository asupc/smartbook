"""Web「调整余额」链路契约:调整交易(exclude_from_stats=True)必须影响账户余额。

Web 端 AccountDetailDialog「调整余额」→ POST /write/ledgers/{id}/transactions
记一笔排除统计/预算的调整交易(与 mobile account_detail_page 同逻辑)。

服务端契约(本测试锁定的行为):
- /read/workspace/accounts 的 balance = initial_balance + 全部 income - expense
  ± transfer,**不排除** exclude_from_stats 的交易 —— 调整账必须能让余额动,
  统计过滤只发生在 /read/workspace/analytics(已有 test_analytics_exclude_flags 覆盖)。
  即账户 KPI 口径 = 含调整账;收支分析口径 = 排除调整账。两口径并存是设计。
- 两方向:差额 < 0 → expense 调整(余额下移);差额 > 0 → income 调整(余额上移)。
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
    # 账本 + 日常现金账户(user-global,initialBalance 100,CNY)
    _push(client, app_token, "lg-adj", "ledger", "lg-adj",
          {"syncId": "lg-adj", "ledgerName": "调整账本", "currency": "CNY"})
    _push(client, app_token, "lg-adj", "account", "acc-adj",
          {"syncId": "acc-adj", "name": "现金", "type": "cash",
           "currency": "CNY", "initialBalance": 100.0})


def _web_create_adjust_tx(client: TestClient, token: str, ledger_id: str,
                          base_change_id: int, tx_type: str, amount: float) -> dict:
    res = client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        headers={"Authorization": f"Bearer {token}", "X-Device-ID": "pytest-web"},
        json={
            "base_change_id": base_change_id,
            "tx_type": tx_type,
            "amount": amount,
            "happened_at": _iso(),
            "note": "余额调整",
            "account_id": "acc-adj",
            "account_name": "现金",
            "exclude_from_stats": True,
            "exclude_from_budget": tx_type == "expense",
        },
    )
    assert res.status_code == 200, res.text
    return res.json()


def test_web_adjust_balance_affects_account_balance() -> None:
    """账面 100 → 调整到 70(expense 30)→ 再调整到 120(income 50):

    - workspace accounts balance 跟随差额(100 → 70 → 120)
    - 账户 KPI(income_total / expense_total / tx_count)含调整账(不排除口径)
    """
    client, TS = _make_client()
    try:
        web_token = _login_web(client, "adj1@example.com")
        # app 侧 token 做 seed(账户经 sync/push 入投影)
        app_token = _login_app(client, "adj1@example.com")
        _seed(client, app_token)

        base_res = client.get(
            "/api/v1/read/ledgers/lg-adj",
            headers={"Authorization": f"Bearer {web_token}"},
        )
        assert base_res.status_code == 200, base_res.text
        base = int(base_res.json()["source_change_id"])

        # 第一笔:目标 70,diff = -30 → expense 调整
        r1 = _web_create_adjust_tx(
            client, web_token, "lg-adj", base, "expense", 30.0,
        )
        # 第二笔:目标 120,diff = +50 → income 调整,base 用上一笔返回的 new_change_id
        _web_create_adjust_tx(
            client, web_token, "lg-adj", int(r1["new_change_id"]), "income", 50.0,
        )

        acc_res = client.get(
            "/api/v1/read/workspace/accounts",
            headers={"Authorization": f"Bearer {web_token}"},
        )
        assert acc_res.status_code == 200, acc_res.text
        acc = next(a for a in acc_res.json() if a["id"] == "acc-adj")
        assert acc["balance"] == 120.0
        assert acc["expense_total"] == 30.0
        assert acc["income_total"] == 50.0
        assert acc["tx_count"] == 2
    finally:
        app.dependency_overrides.clear()
