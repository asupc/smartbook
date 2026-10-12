"""对抗性测试共享脚手架(同步 / 数据一致性域)。

scaffold 照抄 tests/test_sync_concurrency.py(sqlite in-memory + StaticPool +
dependency_overrides);并发写法参考 tests/test_p2_s7_s8_write_race.py。

约定:
- 本目录测试**只读取** src/**,不改任何生产代码。
- `// ADVERSE FINDING: <标题>` = 已确认缺陷,测试保持激活并失败。
- `// HARDENING: <说明>` = 行为可辩护但脆弱,断言当前行为并通过。
- 无法确定性复现的项写进 FINDINGS-sync-consistency.md 的「未能验证」节。
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone

# conftest.py 在 pytest 下已设;直接 python 运行脚本时需要同样的 env。
os.environ.setdefault("ALLOW_APP_RW_SCOPES", "false")
os.environ.setdefault("REGISTRATION_ENABLED", "true")

from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine, select  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402
from sqlalchemy.pool import StaticPool  # noqa: E402

from src.database import Base, get_db  # noqa: E402
from src.main import app  # noqa: E402
from src.models import (  # noqa: E402
    Ledger,
    LedgerMember,
    ReadAccountAdjustmentProjection,
    ReadBudgetProjection,
    ReadTxProjection,
    SyncChange,
    UserAccountProjection,
    UserCategoryProjection,
    UserTagProjection,
)

PASSWORD = "Pa$$word1!"


# --------------------------------------------------------------------------- #
# client / auth 脚手架                                                          #
# --------------------------------------------------------------------------- #

def make_client():
    """sqlite in-memory + StaticPool + dependency_overrides(返回 client, SF)。"""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    SessionFactory = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override_get_db():
        db = SessionFactory()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app), SessionFactory


def teardown():
    app.dependency_overrides.clear()


def iso(dt=None) -> str:
    return (dt or datetime.now(timezone.utc)).isoformat()


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def register_login(
    client: TestClient,
    email: str,
    device: str,
    client_type: str = "app",
) -> tuple[str, str, str]:
    """注册 + 登录;返回 (token, device_id, user_id)。"""
    client.post("/api/v1/auth/register", json={"email": email, "password": PASSWORD})
    res = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": PASSWORD,
            "device_id": device,
            "client_type": client_type,
            "device_name": f"pytest-{device}",
            "platform": client_type,
        },
    )
    assert res.status_code == 200, res.text
    body = res.json()
    return body["access_token"], body.get("device_id", device), body["user"]["id"]


def auth_headers(token: str, device_id: str = "dev-web") -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": device_id}


# --------------------------------------------------------------------------- #
# push / change 构造                                                            #
# --------------------------------------------------------------------------- #

def change(
    entity_type: str,
    entity_sync_id: str,
    payload: dict | None = None,
    *,
    action: str = "upsert",
    ledger_id: str | None = None,
    updated_at: str | None = None,
    scope: str | None = None,
) -> dict:
    out: dict = {
        "entity_type": entity_type,
        "entity_sync_id": entity_sync_id,
        "action": action,
        "payload": payload if payload is not None else {},
        "updated_at": updated_at or iso(),
    }
    if ledger_id is not None:
        out["ledger_id"] = ledger_id
    if scope is not None:
        out["scope"] = scope
    return out


def push(client: TestClient, token: str, device_id: str, changes: list[dict]):
    return client.post(
        "/api/v1/sync/push",
        headers=auth_headers(token, device_id),
        json={"device_id": device_id, "changes": changes},
    )


def push_body(client: TestClient, token: str, body: dict):
    """绕过 pydantic 的 json 序列化,允许 Infinity / NaN 等非标准字面量。"""
    raw = json.dumps(body)
    return client.post(
        "/api/v1/sync/push",
        headers={**auth_headers(token), "Content-Type": "application/json"},
        content=raw.encode(),
    )


def push_raw(client: TestClient, token: str, body: dict, mutate):
    """mutate(json_str) -> json_str,用于注入 Infinity / NaN 字面量。"""
    raw = mutate(json.dumps(body))
    return client.post(
        "/api/v1/sync/push",
        headers={**auth_headers(token), "Content-Type": "application/json"},
        content=raw.encode(),
    )


def tx_change(
    sync_id: str,
    *,
    ledger_id: str = "L01",
    amount: float = 10,
    ts: str | None = None,
    **extra,
) -> dict:
    payload = {
        "syncId": sync_id,
        "type": "expense",
        "amount": amount,
        "happenedAt": iso(),
    }
    payload.update(extra)
    return change("transaction", sync_id, payload, ledger_id=ledger_id, updated_at=ts)


def read_txs(client: TestClient, token: str, ledger_id: str, query: str = "") -> list[dict]:
    res = client.get(
        f"/api/v1/read/ledgers/{ledger_id}/transactions?limit=1000{query}",
        headers=auth_headers(token),
    )
    assert res.status_code == 200, res.text
    return res.json()


# --------------------------------------------------------------------------- #
# DB 直读 helper(断言投影 / 事件流)                                             #
# --------------------------------------------------------------------------- #

def db_rows(SessionFactory, model, **filters) -> list:
    with SessionFactory() as db:
        stmt = select(model)
        for key, value in filters.items():
            stmt = stmt.where(getattr(model, key) == value)
        return list(db.scalars(stmt).all())


def db_scalar(SessionFactory, stmt):
    with SessionFactory() as db:
        return db.scalar(stmt)


def tx_projection(SessionFactory, sync_id: str, ledger_id: str | None = None):
    with SessionFactory() as db:
        stmt = select(ReadTxProjection).where(ReadTxProjection.sync_id == sync_id)
        if ledger_id is not None:
            stmt = stmt.where(ReadTxProjection.ledger_id == ledger_id)
        return db.scalars(stmt).first()


def sync_changes(SessionFactory, **filters) -> list[SyncChange]:
    with SessionFactory() as db:
        stmt = select(SyncChange).order_by(SyncChange.change_id)
        for key, value in filters.items():
            stmt = stmt.where(getattr(SyncChange, key) == value)
        return list(db.scalars(stmt).all())


def ledger_internal_id(SessionFactory, external_id: str) -> str | None:
    with SessionFactory() as db:
        return db.scalar(select(Ledger.id).where(Ledger.external_id == external_id))


def replay_projection_state(changes: list[SyncChange]) -> dict[str, dict]:
    """按 change_id 升序重放 transaction 事件 → {sync_id: payload}(delete 移除)。

    模拟 mobile `_applyPullPage` 的语义:upsert 覆盖,delete 删本地行。
    用于「read 投影 vs 事件重放」一致性对照(authoritative 是投影)。
    """
    state: dict[str, dict] = {}
    for chg in changes:
        if chg.entity_type != "transaction":
            continue
        if chg.action == "delete":
            state.pop(chg.entity_sync_id, None)
        else:
            payload = chg.payload_json
            if isinstance(payload, str):
                try:
                    payload = json.loads(payload)
                except json.JSONDecodeError:
                    payload = {}
            state[chg.entity_sync_id] = payload if isinstance(payload, dict) else {}
    return state


# --------------------------------------------------------------------------- #
# 共享账本脚手架                                                                 #
# --------------------------------------------------------------------------- #

def add_app_device(client: TestClient, email: str, device: str) -> tuple[str, str]:
    """给已存在的用户加一个 app 设备(拿 app_write scope 的 token)。

    /sync/push 要求 SCOPE_APP_WRITE(web token 只有 web_read/web_write/ops_write),
    所以共享账本里 owner 想走 push 通道必须另开 app 设备。
    返回 (token, device_id)。
    """
    res = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": PASSWORD,
            "device_id": device,
            "client_type": "app",
            "device_name": f"pytest-{device}",
            "platform": "app",
        },
    )
    assert res.status_code == 200, res.text
    body = res.json()
    return body["access_token"], body.get("device_id", device)


def setup_shared_ledger(client: TestClient, tag: str = "x"):
    """owner(web + app 双设备) + editor(app) + 已接受的共享账本。

    返回 (owner_ctx, editor_ctx, ledger_external_id),
    ctx = (token, device_id, user_id);owner_ctx 是 **web** token
    (写路径用),owner_app_ctx 是 app token(push 路径用)——
    通过 `setup_shared_ledger_full` 获取后者。
    """
    owner_ext = f"SH{tag}"
    owner = register_login(client, f"{tag}-owner@adv.test", f"dev-{tag}-own", "web")
    editor = register_login(client, f"{tag}-editor@adv.test", f"dev-{tag}-ed", "app")

    res = client.post(
        "/api/v1/write/ledgers",
        json={"ledger_id": owner_ext, "ledger_name": "Shared", "currency": "CNY"},
        headers=auth_headers(owner[0]),
    )
    assert res.status_code == 200, res.text

    res = client.post(
        f"/api/v1/ledgers/{owner_ext}/invites",
        json={"role": "editor", "expires_in_hours": 24},
        headers=auth_headers(owner[0]),
    )
    assert res.status_code == 201, res.text
    code = res.json()["code"]

    res = client.post(
        f"/api/v1/invites/{code}/accept",
        headers=auth_headers(editor[0], editor[1]),
    )
    assert res.status_code == 200, res.text
    return owner, editor, owner_ext


def setup_shared_ledger_full(client: TestClient, tag: str = "x"):
    """同 setup_shared_ledger,但额外返回 owner 的 app 设备 ctx(可走 /sync/push)。

    返回 (owner_web_ctx, owner_app_ctx, editor_ctx, ledger_external_id)。
    """
    owner, editor, owner_ext = setup_shared_ledger(client, tag)
    owner_email = f"{tag}-owner@adv.test"
    app_token, app_device = add_app_device(client, owner_email, f"dev-{tag}-own-app")
    owner_app = (app_token, app_device, owner[2])
    return owner, owner_app, editor, owner_ext


def web_create_ledger(client: TestClient, token: str, external_id: str, name: str = "Ledger") -> str:
    res = client.post(
        "/api/v1/write/ledgers",
        json={"ledger_id": external_id, "ledger_name": name, "currency": "CNY"},
        headers=auth_headers(token),
    )
    assert res.status_code == 200, res.text
    return res.json()["entity_id"]


def web_create_tx(client: TestClient, token: str, ledger_id: str, amount: float, **extra):
    body = {
        "base_change_id": 0,
        "tx_type": "expense",
        "amount": amount,
        "happened_at": "2026-05-06T12:30:00Z",
    }
    body.update(extra)
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        json=body,
        headers=auth_headers(token),
    )


def web_create_category(client: TestClient, token: str, ledger_id: str, name: str, kind: str = "expense"):
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/categories",
        json={"base_change_id": 0, "name": name, "kind": kind},
        headers=auth_headers(token),
    )


def days_ago(seconds: int) -> datetime:
    return datetime.now(timezone.utc) - timedelta(seconds=seconds)


__all__ = [
    "PASSWORD", "make_client", "teardown", "iso", "now_utc", "register_login",
    "add_app_device", "auth_headers", "change", "push", "push_body", "push_raw",
    "tx_change", "read_txs", "db_rows", "db_scalar", "tx_projection",
    "sync_changes", "ledger_internal_id", "replay_projection_state",
    "setup_shared_ledger", "setup_shared_ledger_full", "web_create_ledger",
    "web_create_tx", "web_create_category", "days_ago", "Ledger", "LedgerMember",
    "ReadAccountAdjustmentProjection", "ReadBudgetProjection",
    "ReadTxProjection", "SyncChange", "UserAccountProjection",
    "UserCategoryProjection", "UserTagProjection", "select", "timedelta",
    "timezone", "datetime", "json",
]
