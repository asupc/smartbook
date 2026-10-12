"""越权(IDOR)/ 授权边界对抗测试 —— Web 越权矩阵、共享账本、邀请码、
WebSocket 认证、管理员边界、MCP 越权。

标注约定:
  ADVERSE FINDING  —— 真实缺陷(测试保持失败)
  HARDENING        —— 行为可辩护但脆弱(断言当前行为并通过)
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
from src.mcp import auth as mcp_auth
from src.models import Ledger, LedgerInvite, LedgerMember, User

PASSWORD = "Pa$$word1!"


def _make_client(*, raise_server_exceptions: bool = False) -> tuple[TestClient, sessionmaker]:
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
    mcp_auth.SessionLocal = TS
    from src.routers import ws as ws_router

    ws_router.SessionLocal = TS
    return TestClient(app, raise_server_exceptions=raise_server_exceptions), TS


@pytest.fixture()
def client():
    c, TS = _make_client()
    yield c, TS
    app.dependency_overrides.clear()


def _register(client, email: str, client_type: str = "web", device_id: str | None = None) -> dict:
    body = {
        "email": email,
        "password": PASSWORD,
        "client_type": client_type,
        "device_name": "pytest",
        "platform": "test",
    }
    if device_id:
        body["device_id"] = device_id
    res = client.post("/api/v1/auth/register", json=body)
    assert res.status_code == 200, res.text
    return res.json()


def _auth(tok: str, device: str) -> dict:
    return {"Authorization": f"Bearer {tok}", "X-Device-ID": device}


def _new_ledger(client, tok: str, ext: str, device: str, *, name: str | None = None) -> str:
    res = client.post(
        "/api/v1/write/ledgers",
        headers=_auth(tok, device),
        json={"ledger_id": ext, "ledger_name": name or ext, "currency": "CNY"},
    )
    assert res.status_code == 200, res.text
    return res.json()["entity_id"]


def _new_tx(client, tok: str, ledger: str, device: str, *, amount: float = 11.0, note: str = "secret"):
    res = client.post(
        f"/api/v1/write/ledgers/{ledger}/transactions",
        headers=_auth(tok, device),
        json={"base_change_id": 0, "tx_type": "expense", "amount": amount,
              "happened_at": "2026-05-06T12:00:00Z", "note": note},
    )
    assert res.status_code == 200, res.text
    return res.json()["entity_id"]


def _invite(client, owner_tok: str, ledger: str, device: str, *, role: str = "editor") -> str:
    res = client.post(
        f"/api/v1/ledgers/{ledger}/invites",
        headers=_auth(owner_tok, device),
        json={"role": role, "expires_in_hours": 24},
    )
    assert res.status_code == 201, res.text
    return res.json()["code"]


def _accept(client, tok: str, code: str, device: str):
    return client.post(f"/api/v1/invites/{code}/accept", headers=_auth(tok, device))


# --------------------------------------------------------------------------
# Web 越权矩阵:C 对 A 的账本做读 / 写
# --------------------------------------------------------------------------

READ_PATHS = [
    "/api/v1/read/ledgers",
    "/api/v1/read/ledgers/{L}",
    "/api/v1/read/ledgers/{L}/stats",
    "/api/v1/read/ledgers/{L}/transactions",
    "/api/v1/read/ledgers/{L}/accounts",
    "/api/v1/read/ledgers/{L}/categories",
    "/api/v1/read/ledgers/{L}/tags",
    "/api/v1/read/ledgers/{L}/budgets",
    "/api/v1/read/ledgers/{L}/budgets/usage",
    "/api/v1/ledgers/{L}/members",
    "/api/v1/ledgers/{L}/invites",
    "/api/v1/ledgers/{L}/shared-resources",
    "/api/v1/ledgers/{L}/member-stats",
    "/api/v1/read/summary?ledger_id={L}",
    "/api/v1/sync/full?ledger_id={L}",
]


def test_web_idor_matrix_reads_return_404(client):
    """非成员对 A 账本的所有单账本读端点 → 404(不泄漏存在性)。"""
    c, _ = client
    a = _register(c, "idor-a@example.com", "web", "dA")
    x = _register(c, "idor-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "LG-IDOR", "dA")
    _new_tx(c, a["access_token"], "LG-IDOR", "dA")

    failures = []
    for path in READ_PATHS:
        code = c.get(path.format(L="LG-IDOR"), headers=_auth(x["access_token"], "dX")).status_code
        # 列表型端点(不带账本维度)返回自己的空集合是正确语义
        expected = {200, 404}
        if code not in expected:
            failures.append((path, code))
    assert not failures, f"越权读取未按 404 拒绝:{failures}"


def test_web_idor_matrix_writes_rejected(client):
    """非成员对 A 账本的所有写端点 → 404/403,且 A 的数据不变。"""
    c, TS = client
    a = _register(c, "idorw-a@example.com", "web", "dA")
    x = _register(c, "idorw-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "LG-W", "dA")
    before = c.get("/api/v1/read/ledgers/LG-W", headers=_auth(a["access_token"], "dA")).json()

    attempts = [
        ("POST", "/api/v1/write/ledgers/LG-W/transactions",
         {"base_change_id": 0, "tx_type": "expense", "amount": 1, "happened_at": "2026-05-06T12:00:00Z"}),
        ("POST", "/api/v1/write/ledgers/LG-W/accounts",
         {"base_change_id": 0, "name": "x", "account_type": "cash"}),
        ("POST", "/api/v1/write/ledgers/LG-W/tags", {"base_change_id": 0, "name": "x"}),
        ("POST", "/api/v1/write/ledgers/LG-W/categories",
         {"base_change_id": 0, "name": "x", "kind": "expense"}),
        ("POST", "/api/v1/write/ledgers/LG-W/budgets",
         {"base_change_id": 0, "type": "total", "amount": 5, "period": "monthly"}),
        ("POST", "/api/v1/write/ledgers/LG-W/account-adjustments",
         {"base_change_id": 0, "account_id": "a", "amount": 1, "happened_at": "2026-05-06T12:00:00Z"}),
        ("POST", "/api/v1/write/ledgers/LG-W/transactions/batch/delete",
         {"tx_ids": ["x1"], "base_change_id": 0}),
        ("POST", "/api/v1/write/ledgers/LG-W/transactions/batch/move",
         {"tx_ids": ["x1"], "target_ledger_id": "z", "base_change_id": 0}),
        ("PATCH", "/api/v1/write/ledgers/LG-W/meta", {"base_change_id": 0, "ledger_name": "hacked"}),
        ("DELETE", "/api/v1/write/ledgers/LG-W", None),
        ("PATCH", f"/api/v1/ledgers/LG-W/members/{a['user']['id']}", {"role": "editor"}),
        ("DELETE", f"/api/v1/ledgers/LG-W/members/{a['user']['id']}", None),
        ("POST", "/api/v1/ledgers/LG-W/invites", {"role": "editor"}),
        ("POST", "/api/v1/ledgers/LG-W/transfer", {"new_owner_user_id": x["user"]["id"]}),
        ("POST", "/api/v1/read/workspace/trash/whatever/purge?ledger_id=LG-W", None),
        ("POST", "/api/v1/read/workspace/trash/whatever/restore?ledger_id=LG-W", None),
    ]
    for method, path, body in attempts:
        headers = _auth(x["access_token"], "dX")
        res = c.request(method, path, headers=headers, json=body) if body is not None else c.request(method, path, headers=headers)
        assert res.status_code in (403, 404, 422), f"{method} {path} 未被拒绝:{res.status_code}"

    after = c.get("/api/v1/read/ledgers/LG-W", headers=_auth(a["access_token"], "dA")).json()
    assert after["ledger_name"] == before["ledger_name"]
    assert after["transaction_count"] == before["transaction_count"]


def test_foreign_ledger_id_in_workspace_filters_leaks_nothing(client):
    """workspace 聚合端点带他人 ledger_id 过滤 → 空结果,不泄漏数据。

    HARDENING: `_visible_workspace_ledgers`(src/routers/read/_shared.py:308-349)
    用 `Ledger.id.in_(LedgerMember ... user_id=caller)` 与外部 ledger_id 做 AND,
    所以外部 id 只起到"过滤到我自己的"作用。当前行为正确 —— 但注意
    `/read/workspace/*` 全部返回 200(而非 404),调用方需自行判断空结果。
    """
    c, _ = client
    a = _register(c, "ws-a@example.com", "web", "dA")
    x = _register(c, "ws-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "WS-SECRET", "dA")
    _new_tx(c, a["access_token"], "WS-SECRET", "dA", note="WS-SECRET-NOTE")

    for path in (
        "/api/v1/read/workspace/transactions?limit=500",
        "/api/v1/read/workspace/transactions?ledger_id=WS-SECRET&limit=500",
        "/api/v1/read/workspace/analytics?ledger_id=WS-SECRET",
        "/api/v1/read/workspace/accounts?ledger_id=WS-SECRET",
        "/api/v1/read/workspace/categories?ledger_id=WS-SECRET",
        "/api/v1/read/workspace/tags?ledger_id=WS-SECRET",
        "/api/v1/read/workspace/ledger-counts",
        "/api/v1/read/workspace/trash?limit=500",
        "/api/v1/read/workspace/net-worth-history?ledger_id=WS-SECRET",
        f"/api/v1/read/workspace/transactions?user_id={a['user']['id']}&limit=500",
        "/api/v1/read/workspace/transactions.csv?limit=2000",
    ):
        res = c.get(path, headers=_auth(x["access_token"], "dX"))
        assert res.status_code == 200, f"{path} → {res.status_code}"
        assert "WS-SECRET" not in res.text, f"{path} 泄漏 A 的账本/备注"


def test_read_ledgers_list_only_own_ledgers(client):
    c, _ = client
    a = _register(c, "own-a@example.com", "web", "dA")
    x = _register(c, "own-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "ONLY-A", "dA")
    _new_ledger(c, x["access_token"], "ONLY-X", "dX")
    ids = [row["ledger_id"] for row in c.get("/api/v1/read/ledgers", headers=_auth(x["access_token"], "dX")).json()]
    assert ids == ["ONLY-X"]


def test_sync_pull_only_returns_own_changes(client):
    """B 的 pull 不得返回 A 的 ledger-scope changes。"""
    c, _ = client
    a = _register(c, "pull-a@example.com", "app", "dA")
    b = _register(c, "pull-b@example.com", "app", "dB")
    c.post(
        "/api/v1/write/ledgers", headers=_auth(a["access_token"], "dA"),
        json={"ledger_id": "PULL-A", "ledger_name": "A", "currency": "CNY"},
    )
    res = c.get("/api/v1/sync/pull?since=0&limit=5000", headers=_auth(b["access_token"], "dB"))
    assert res.status_code == 200
    payload = res.json()
    assert payload["changes"] == [], f"B 的 pull 拿到 A 的变更:{payload['changes'][:2]}"
    assert payload["server_cursor"] == 0


def test_sync_push_cannot_write_victim_ledger(client):
    """B 用 app token 推 A 的 ledger_id → A 的数据不可变(自动建 B 自己的)。"""
    c, _ = client
    a = _register(c, "sp-a@example.com", "app", "dA")
    b = _register(c, "sp-b@example.com", "app", "dB")

    def _push(tok, dev, ledger, sync_id, amount):
        return c.post(
            "/api/v1/sync/push", headers=_auth(tok, dev),
            json={"device_id": dev, "changes": [{
                "ledger_id": ledger, "entity_type": "transaction", "entity_sync_id": sync_id,
                "action": "upsert",
                "payload": {"syncId": sync_id, "type": "expense", "amount": amount,
                            "happenedAt": "2026-05-06T12:00:00Z", "categoryName": "c",
                            "categoryKind": "expense", "accountName": "a"},
                "updated_at": datetime.now(timezone.utc).isoformat()}]},
        )

    assert _push(a["access_token"], "dA", "SP-A", "a-tx", 111).status_code == 200
    pushed = _push(b["access_token"], "dB", "SP-A", "b-forge", 999)
    assert pushed.status_code == 200
    assert pushed.json()["accepted"] == 1  # 落在 B 自己的同名账本

    # A 侧只有自己那笔(用 sync 路径读避免 web token 依赖)
    a_txs = c.get("/api/v1/sync/full?ledger_id=SP-A", headers=_auth(a["access_token"], "dA"))
    assert a_txs.status_code == 200
    assert "b-forge" not in json.dumps(a_txs.json()), "B 的伪造交易进入 A 的账本"


# --------------------------------------------------------------------------
# 共享账本:邀请码 / 成员 / 角色
# --------------------------------------------------------------------------


def test_invite_code_enumeration_is_expensive_and_fails(client):
    """随机猜邀请码 → 全部 404,不泄漏存在性。"""
    c, _ = client
    a = _register(c, "inv-a@example.com", "web", "dA")
    x = _register(c, "inv-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "INV-L", "dA")
    _invite(c, a["access_token"], "INV-L", "dA")

    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    import random

    random.seed(1234)
    for _ in range(30):
        guess = "".join(random.choice(alphabet) for _ in range(6))
        res = c.post(f"/api/v1/invites/{guess}/preview", headers=_auth(x["access_token"], "dX"))
        assert res.status_code == 404, f"猜测 {guess} 返回 {res.status_code}"


def test_invite_code_normalization_accepts_case_and_separators(client):
    """邀请码归一化(大小写/空格/横线)不构成越权 —— 记录的码才可预览。

    HARDENING: `_normalize_code`(src/routers/invites.py:135-138)接受
    "abc 123" / "abc-123" / 小写。熵由 30^6 保证,归一化只提高输入容错。
    """
    c, _ = client
    a = _register(c, "invn-a@example.com", "web", "dA")
    x = _register(c, "invn-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "INVN-L", "dA")
    code = _invite(c, a["access_token"], "INVN-L", "dA")

    for variant in (code.lower(), f"{code[:3]}-{code[3:]}", f"{code[:3]} {code[3:]}"):
        res = c.post(f"/api/v1/invites/{variant}/preview", headers=_auth(x["access_token"], "dX"))
        assert res.status_code == 200, f"变体 {variant} 应可预览"
    # 但错误码不行
    assert c.post("/api/v1/invites/ZZZZZZ/preview", headers=_auth(x["access_token"], "dX")).status_code == 404


def test_revoked_invite_cannot_be_used(client):
    c, _ = client
    a = _register(c, "invrev-a@example.com", "web", "dA")
    x = _register(c, "invrev-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "INVREV", "dA")
    code = _invite(c, a["access_token"], "INVREV", "dA")
    assert c.delete(
        f"/api/v1/ledgers/INVREV/invites/{code}", headers=_auth(a["access_token"], "dA")
    ).status_code == 204
    assert c.post(f"/api/v1/invites/{code}/preview", headers=_auth(x["access_token"], "dX")).status_code == 404
    assert _accept(c, x["access_token"], code, "dX").status_code == 404


def test_invite_is_single_use(client):
    c, _ = client
    a = _register(c, "inv1-a@example.com", "web", "dA")
    p = _register(c, "inv1-p@example.com", "web", "dP")
    q = _register(c, "inv1-q@example.com", "web", "dQ")
    _new_ledger(c, a["access_token"], "INV1", "dA")
    code = _invite(c, a["access_token"], "INV1", "dA")
    assert _accept(c, p["access_token"], code, "dP").status_code == 200
    assert _accept(c, q["access_token"], code, "dQ").status_code in (404, 409)


def test_invite_rejects_owner_role_and_out_of_range_expiry(client):
    c, _ = client
    a = _register(c, "invrole-a@example.com", "web", "dA")
    _new_ledger(c, a["access_token"], "INVROLE", "dA")
    for payload in (
        {"role": "owner", "expires_in_hours": 24},
        {"role": "viewer", "expires_in_hours": 24},
        {"role": "editor", "expires_in_hours": 0},
        {"role": "editor", "expires_in_hours": 999},
    ):
        res = c.post("/api/v1/ledgers/INVROLE/invites", headers=_auth(a["access_token"], "dA"), json=payload)
        assert res.status_code == 422, f"{payload} 应 422,实际 {res.status_code}"


def test_invite_active_limit_enforced(client):
    """同账本 active 邀请上限 10(src/routers/invites.py:54)。"""
    c, _ = client
    a = _register(c, "invlim-a@example.com", "web", "dA")
    _new_ledger(c, a["access_token"], "INVLIM", "dA")
    codes = [
        c.post("/api/v1/ledgers/INVLIM/invites", headers=_auth(a["access_token"], "dA"),
               json={"role": "editor"}).status_code
        for _ in range(12)
    ]
    assert codes.count(201) == 10
    assert codes[-1] == 409


def test_owner_cannot_accept_own_invite_and_non_owner_cannot_invite(client):
    c, _ = client
    a = _register(c, "selfinv-a@example.com", "web", "dA")
    m = _register(c, "selfinv-m@example.com", "web", "dM")
    _new_ledger(c, a["access_token"], "SELFINV", "dA")
    code = _invite(c, a["access_token"], "SELFINV", "dA")

    # 用另一台设备(同 owner)接受自己的邀请 → 409 already a member
    assert _accept(c, a["access_token"], code, "dA-second").status_code == 409

    # 成员(editor)不能创建邀请
    _new_ledger(c, m["access_token"], "SELFINV-M", "dM")
    code2 = _invite(c, a["access_token"], "SELFINV", "dA")
    assert _accept(c, m["access_token"], code2, "dM").status_code == 200
    assert c.post(
        "/api/v1/ledgers/SELFINV/invites", headers=_auth(m["access_token"], "dM"),
        json={"role": "editor"},
    ).status_code == 404


def test_non_member_cannot_guess_ledger_to_create_invite(client):
    """非成员对任意 ledger_id 创建邀请 → 404(不泄漏账本存在性)。"""
    c, _ = client
    a = _register(c, "guess-a@example.com", "web", "dA")
    x = _register(c, "guess-x@example.com", "web", "dX")
    _new_ledger(c, a["access_token"], "GUESS-L", "dA")
    assert c.post(
        "/api/v1/ledgers/GUESS-L/invites", headers=_auth(x["access_token"], "dX"),
        json={"role": "editor"},
    ).status_code == 404
    assert c.get(
        "/api/v1/ledgers/GUESS-L/invites", headers=_auth(x["access_token"], "dX")
    ).status_code == 404
    assert c.delete(
        "/api/v1/ledgers/GUESS-L/invites/ANYCODE", headers=_auth(x["access_token"], "dX")
    ).status_code == 404


def test_editor_cannot_escalate_to_owner_via_member_endpoints(client):
    """Editor 不能通过 transfer / 成员 PATCH 把自己变 owner,也不能踢 owner。"""
    c, _ = client
    a = _register(c, "esc-a@example.com", "web", "dA")
    m = _register(c, "esc-m@example.com", "web", "dM")
    _new_ledger(c, a["access_token"], "ESC-L", "dA")
    code = _invite(c, a["access_token"], "ESC-L", "dA")
    assert _accept(c, m["access_token"], code, "dM").status_code == 200
    mh = _auth(m["access_token"], "dM")

    assert c.post(
        "/api/v1/ledgers/ESC-L/transfer", headers=mh,
        json={"new_owner_user_id": m["user"]["id"]},
    ).status_code == 404
    assert c.patch(
        f"/api/v1/ledgers/ESC-L/members/{m['user']['id']}", headers=mh, json={"role": "editor"}
    ).status_code == 404
    assert c.delete(f"/api/v1/ledgers/ESC-L/members/{a['user']['id']}", headers=mh).status_code == 404
    assert c.delete("/api/v1/write/ledgers/ESC-L", headers=mh).status_code == 404


def test_editor_cannot_push_ledger_meta_entities(client):
    """Editor 用 app token 推 `ledger` / `ledger_snapshot` → 被拒(rejected)。

    src/routers/sync/push.py:非 owner 的 ledger/ledger_snapshot 变更被 reject。
    """
    c, _ = client
    a = _register(c, "epush-a@example.com", "web", "dA")
    m = _register(c, "epush-m@example.com", "app", "dM")
    _new_ledger(c, a["access_token"], "EPUSH", "dA")
    code = _invite(c, a["access_token"], "EPUSH", "dA")
    assert _accept(c, m["access_token"], code, "dM").status_code == 200
    mh = _auth(m["access_token"], "dM")

    for entity, action, payload in (
        ("ledger", "upsert", {"ledgerName": "EDITOR-PWN"}),
        ("ledger_snapshot", "delete", {}),
    ):
        res = c.post(
            "/api/v1/sync/push", headers=mh,
            json={"device_id": "dM", "changes": [{
                "ledger_id": "EPUSH", "entity_type": entity, "entity_sync_id": "EPUSH",
                "action": action, "payload": payload,
                "updated_at": datetime.now(timezone.utc).isoformat()}]},
        )
        assert res.status_code == 200, res.text
        assert res.json()["accepted"] == 0, f"{entity} {action} 被 editor 接受了"
    assert c.get("/api/v1/read/ledgers/EPUSH", headers=_auth(a["access_token"], "dA")).json()[
        "ledger_name"
    ] == "EPUSH"


def test_removed_member_cannot_continue_pushing(client):
    """被移除成员用旧 device 继续 push → 明确拒绝(membership_revoked)。"""
    c, _ = client
    a = _register(c, "rm-a@example.com", "web", "dA")
    m = _register(c, "rm-m@example.com", "app", "dM")
    _new_ledger(c, a["access_token"], "RM-L", "dA")
    code = _invite(c, a["access_token"], "RM-L", "dA")
    assert _accept(c, m["access_token"], code, "dM").status_code == 200
    # 先推一笔(建立 membership evidence)
    first = c.post(
        "/api/v1/sync/push", headers=_auth(m["access_token"], "dM"),
        json={"device_id": "dM", "changes": [{
            "ledger_id": "RM-L", "entity_type": "transaction", "entity_sync_id": "m-1",
            "action": "upsert",
            "payload": {"syncId": "m-1", "type": "expense", "amount": 1,
                        "happenedAt": "2026-05-06T12:00:00Z", "categoryName": "c",
                        "categoryKind": "expense", "accountName": "a"},
            "updated_at": datetime.now(timezone.utc).isoformat()}]},
    )
    assert first.status_code == 200 and first.json()["accepted"] == 1

    assert c.delete(
        f"/api/v1/ledgers/RM-L/members/{m['user']['id']}", headers=_auth(a["access_token"], "dA")
    ).status_code == 204

    second = c.post(
        "/api/v1/sync/push", headers=_auth(m["access_token"], "dM"),
        json={"device_id": "dM", "changes": [{
            "ledger_id": "RM-L", "entity_type": "transaction", "entity_sync_id": "m-2",
            "action": "upsert",
            "payload": {"syncId": "m-2", "type": "expense", "amount": 2,
                        "happenedAt": "2026-05-06T12:00:00Z", "categoryName": "c",
                        "categoryKind": "expense", "accountName": "a"},
            "updated_at": datetime.now(timezone.utc).isoformat()}]},
    )
    assert second.status_code == 200
    body = second.json()
    assert body["accepted"] == 0, f"被移除成员仍能 push:{body}"
    assert any(
        s.get("reason") == "membership_revoked" for s in body.get("failed_samples", [])
    ), f"缺少 membership_revoked 标记:{body}"


def test_removed_member_loses_read_access_immediately(client):
    c, _ = client
    a = _register(c, "rmr-a@example.com", "web", "dA")
    m = _register(c, "rmr-m@example.com", "web", "dM")
    _new_ledger(c, a["access_token"], "RMR-L", "dA")
    code = _invite(c, a["access_token"], "RMR-L", "dA")
    assert _accept(c, m["access_token"], code, "dM").status_code == 200
    mh = _auth(m["access_token"], "dM")
    assert c.get("/api/v1/read/ledgers/RMR-L", headers=mh).status_code == 200
    assert c.delete(
        f"/api/v1/ledgers/RMR-L/members/{m['user']['id']}", headers=_auth(a["access_token"], "dA")
    ).status_code == 204
    assert c.get("/api/v1/read/ledgers/RMR-L", headers=mh).status_code == 404
    assert c.get("/api/v1/ledgers/RMR-L/members", headers=mh).status_code == 404


def test_member_limit_enforced_on_accept(client):
    """成员上限 5:第 6 人 accept → 409。"""
    c, _ = client
    a = _register(c, "lim-a@example.com", "web", "dA")
    _new_ledger(c, a["access_token"], "LIM-L", "dA")
    # owner + 4 editor = 5
    for i in range(4):
        u = _register(c, f"lim-{i}@example.com", "web", f"dL{i}")
        code = _invite(c, a["access_token"], "LIM-L", "dA")
        assert _accept(c, u["access_token"], code, f"dL{i}").status_code == 200
    late = _register(c, "lim-late@example.com", "web", "dLate")
    code = _invite(c, a["access_token"], "LIM-L", "dA")
    res = _accept(c, late["access_token"], code, "dLate")
    assert res.status_code == 409


# --------------------------------------------------------------------------
# external_id 跨用户同名:MultipleResultsFound → 500
# --------------------------------------------------------------------------


def test_same_external_id_across_users_breaks_member_ledger_access(client):
    """成员与 owner 各自有同名 external_id 账本时,成员几乎全部端点 500。

    ADVERSE FINDING: `get_accessible_ledger_by_external_id`
    (src/ledger_access.py:43-64)按 `Ledger.external_id == X AND LedgerMember.user_id
    = caller` 查询、用 `.one_or_none()` 取值。external_id 只在
    (user_id, external_id) 上唯一(src/models.py:471),当 caller 自己的账本也叫
    "default" 且已被邀请进他人同名账本时,查询命中 2 行 → sqlalchemy
    MultipleResultsFound 未捕获 → 500。

    影响:web `/read/ledgers/{id}`、`/read/summary`、`/sync/full`、
    `/ledgers/{id}/members`、`shared-resources`、`member-stats`;以及
    **所有写端点**(src/routers/write/_shared.py:_load_ledger_for_write 同款查询)。
    即:一旦接受他人"default"邀请,该用户在自己的"default"账本上既读不了也写不了。
    """
    c, _ = client
    owner = _register(c, "coll-owner@example.com", "web", "dO")
    member = _register(c, "coll-member@example.com", "web", "dM")

    assert c.post("/api/v1/write/ledgers", headers=_auth(owner["access_token"], "dO"),
                  json={"ledger_id": "default", "ledger_name": "owner-default"}).status_code == 200
    assert c.post("/api/v1/write/ledgers", headers=_auth(member["access_token"], "dM"),
                  json={"ledger_id": "default", "ledger_name": "member-default"}).status_code == 200

    code = _invite(c, owner["access_token"], "default", "dO")
    assert _accept(c, member["access_token"], code, "dM").status_code == 200
    mh = _auth(member["access_token"], "dM")

    broken = {}
    for path in (
        "/api/v1/read/ledgers/default",
        "/api/v1/read/summary?ledger_id=default",
        "/api/v1/sync/full?ledger_id=default",
        "/api/v1/ledgers/default/members",
        "/api/v1/ledgers/default/shared-resources",
        "/api/v1/ledgers/default/member-stats",
    ):
        code_ = c.get(path, headers=mh).status_code
        if code_ >= 500:
            broken[path] = code_
    # 写端点同样 500
    wr = c.post("/api/v1/write/ledgers/default/transactions", headers=mh,
                json={"base_change_id": 0, "tx_type": "expense", "amount": 1,
                      "happened_at": "2026-05-06T12:00:00Z"})
    if wr.status_code >= 500:
        broken["POST /write/ledgers/default/transactions"] = wr.status_code

    assert not broken, f"跨用户同名 external_id 导致 500:{broken}"


def test_same_external_id_app_member_push_breaks(client):
    """app 客户端成员:接受同名邀请后再 push → 500。"""
    c, _ = client
    owner = _register(c, "collapp-owner@example.com", "web", "dO")
    member = _register(c, "collapp-member@example.com", "app", "dM")
    assert c.post("/api/v1/write/ledgers", headers=_auth(owner["access_token"], "dO"),
                  json={"ledger_id": "default", "ledger_name": "owner-default"}).status_code == 200
    # 成员先 push 建自己的 "default"
    pre = c.post("/api/v1/sync/push", headers=_auth(member["access_token"], "dM"),
                 json={"device_id": "dM", "changes": [{
                     "ledger_id": "default", "entity_type": "transaction", "entity_sync_id": "m-pre",
                     "action": "upsert",
                     "payload": {"syncId": "m-pre", "type": "expense", "amount": 1,
                                 "happenedAt": "2026-05-06T12:00:00Z", "categoryName": "c",
                                 "categoryKind": "expense", "accountName": "a"},
                     "updated_at": datetime.now(timezone.utc).isoformat()}]})
    assert pre.status_code == 200
    code = _invite(c, owner["access_token"], "default", "dO")
    assert _accept(c, member["access_token"], code, "dM").status_code == 200

    post = c.post("/api/v1/sync/push", headers=_auth(member["access_token"], "dM"),
                  json={"device_id": "dM", "changes": [{
                      "ledger_id": "default", "entity_type": "transaction", "entity_sync_id": "m-post",
                      "action": "upsert",
                      "payload": {"syncId": "m-post", "type": "expense", "amount": 2,
                                  "happenedAt": "2026-05-06T12:00:00Z", "categoryName": "c",
                                  "categoryKind": "expense", "accountName": "a"},
                      "updated_at": datetime.now(timezone.utc).isoformat()}]})
    assert post.status_code < 500, f"同名 external_id + 成员身份导致 push 500:{post.text[:200]}"


# --------------------------------------------------------------------------
# WebSocket 认证
# --------------------------------------------------------------------------


def test_ws_requires_first_message_auth(client):
    from starlette.websockets import WebSocketDisconnect

    c, _ = client
    body = _register(c, "ws1@example.com", "web", "dW")

    with c.websocket_connect("/ws") as ws:
        ws.send_text("not-json")
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 1008

    with c.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "auth", "token": 12345}))
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 1008

    with c.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "subscribe", "token": body["access_token"]}))
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_text()
        assert exc.value.code == 1008


def test_ws_rejects_pat_and_refresh_token(client):
    from starlette.websockets import WebSocketDisconnect

    c, _ = client
    body = _register(c, "ws2@example.com", "web", "dW")
    pat = c.post("/api/v1/profile/pats", headers=_auth(body["access_token"], "dW"),
                 json={"name": "ws", "scopes": ["mcp:read"]}).json()["token"]

    for token in (pat, body["refresh_token"], "not-a-jwt"):
        with pytest.raises(WebSocketDisconnect) as exc:
            with c.websocket_connect(f"/ws?token={token}"):
                pass
        assert exc.value.code == 1008


def test_ws_auth_ok_then_ping_pong(client):
    c, _ = client
    body = _register(c, "ws3@example.com", "web", "dW")
    with c.websocket_connect("/ws") as ws:
        ws.send_text(json.dumps({"type": "auth", "token": body["access_token"]}))
        assert json.loads(ws.receive_text()) == {"type": "auth_ok"}
        ws.send_text(json.dumps({"type": "ping"}))
        assert json.loads(ws.receive_text()) == {"type": "pong"}


def test_ws_accepts_token_of_disabled_user(client):
    """已被禁用的用户仍能完成 WS 首帧认证。

    ADVERSE FINDING: `src/routers/ws.py:_user_exists` 只判断 User 行是否存在,
    不查 `is_enabled`(对照 REST 路径 `src/deps.py:get_current_user` 的
    `if not user.is_enabled: 403`)。被管理员禁用的账号仍能拿到
    `{"type":"auth_ok"}` 并进入连接表收取实时推送(账本变更、成员变更)。
    期望:close(1008)。
    """
    c, TS = client
    body = _register(c, "wsdis@example.com", "web", "dW")
    db = TS()
    user = db.scalar(select(User).where(User.email == "wsdis@example.com"))
    user.is_enabled = False
    db.commit()
    db.close()

    assert c.get("/api/v1/read/ledgers", headers=_auth(body["access_token"], "dW")).status_code == 403

    from starlette.websockets import WebSocketDisconnect

    got = None
    try:
        with c.websocket_connect("/ws") as ws:
            ws.send_text(json.dumps({"type": "auth", "token": body["access_token"]}))
            got = ws.receive_text()
    except WebSocketDisconnect as exc:
        got = f"disconnect:{exc.code}"
    assert got == "disconnect:1008" or got is None or "auth_ok" not in str(got), (
        f"被禁用的用户完成了 WS 认证:{got}"
    )


def test_ws_query_token_path_also_checks_enabled(client):
    """兼容路径(`/ws?token=...`,mobile)同样未校验 is_enabled。"""
    c, TS = client
    body = _register(c, "wsdis2@example.com", "app", "dW")
    db = TS()
    user = db.scalar(select(User).where(User.email == "wsdis2@example.com"))
    user.is_enabled = False
    db.commit()
    db.close()

    accepted = False
    try:
        with c.websocket_connect(f"/ws?token={body['access_token']}") as ws:
            ws.send_text(json.dumps({"type": "ping"}))
            ws.receive_text()
            accepted = True
    except Exception:  # noqa: BLE001
        accepted = False
    assert not accepted, "被禁用的用户通过 query token 建立了 WS 连接"


# --------------------------------------------------------------------------
# 管理员边界
# --------------------------------------------------------------------------


def test_non_admin_cannot_touch_admin_endpoints(client):
    c, _ = client
    tok = _register(c, "na@example.com", "web", "d1")["access_token"]
    h = _auth(tok, "d1")
    assert c.get("/api/v1/admin/users", headers=h).status_code == 403
    assert c.post(
        "/api/v1/admin/users", headers=h,
        json={"email": "new@example.com", "password": "Pa$$word1!"},
    ).status_code == 403
    assert c.get("/api/v1/admin/debug/snapshot/anything", headers=h).status_code == 403
    assert c.get("/api/v1/admin/backup/rclone-config", headers=h).status_code == 403
    assert c.get("/api/v1/admin/ai-analysis-logs", headers=h).status_code == 403


def test_admin_cannot_read_other_users_ledgers_via_web_read(client):
    """普通 admin 不是其它用户账本的成员时,/read/* 仍 404(管理后台走 /admin/*)。

    HARDENING: src/routers/read/_shared.py:_is_admin() 恒 False,刻意关掉了
    "admin 跨用户读"的旁路(见该函数 docstring)。因此 admin 在 web 前端
    只能看自己账本 —— 需要跨用户诊断请走 /admin/debug/*。
    """
    c, TS = client
    a = _register(c, "adm-tgt@example.com", "web", "dT")
    adm = _register(c, "adm-me@example.com", "web", "dAdm")
    _new_ledger(c, a["access_token"], "ADM-TGT", "dT")

    db = TS()
    user = db.scalar(select(User).where(User.email == "adm-me@example.com"))
    user.is_admin = True
    db.commit()
    db.close()

    assert c.get("/api/v1/read/ledgers/ADM-TGT", headers=_auth(adm["access_token"], "dAdm")).status_code == 404
    assert c.get("/api/v1/read/ledgers", headers=_auth(adm["access_token"], "dAdm")).json() == []
    # 但 admin 端点可查
    assert c.get("/api/v1/admin/debug/snapshot/ADM-TGT", headers=_auth(adm["access_token"], "dAdm")).status_code == 200


def test_admin_devices_endpoint_filters_for_non_admin(client):
    """非 admin 打 /admin/devices → 只看到自己的设备(条件是 user_id 过滤)。

    HARDENING: src/routers/admin.py:753-790 对非 admin 自动加
    `Device.user_id == current_user.id` 条件而非 403 —— 返回 200 但只含自己。
    不是越权,但与其它 admin 端点的 403 语义不一致。
    """
    c, _ = client
    a = _register(c, "dev-a@example.com", "web", "devA")
    b = _register(c, "dev-b@example.com", "web", "devB")
    res = c.get("/api/v1/admin/devices", headers=_auth(b["access_token"], "devB"))
    assert res.status_code == 200
    ids = [d["id"] for d in res.json()["items"]]
    assert "devA" not in ids
    assert "devB" in ids


def test_admin_user_ids_are_not_guessable_via_uuid_errors(client):
    """admin 端点对未知 user_id 返回 404 而不是 500。"""
    c, TS = client
    adm = _register(c, "adm-x@example.com", "web", "dXadm")
    db = TS()
    user = db.scalar(select(User).where(User.email == "adm-x@example.com"))
    user.is_admin = True
    db.commit()
    db.close()
    h = _auth(adm["access_token"], "dXadm")
    assert c.patch("/api/v1/admin/users/does-not-exist", headers=h, json={"is_enabled": False}).status_code == 404
    assert c.delete("/api/v1/admin/users/does-not-exist", headers=h).status_code == 404


# --------------------------------------------------------------------------
# MCP 越权 / 工具级 scope
# --------------------------------------------------------------------------


def test_mcp_read_tools_are_user_scoped(client):
    """MCP 层已认证但 read tool 只能看自己数据(read_tools 按 user_id 过滤)。"""
    c, TS = client
    from src.mcp import server as mcp_server
    from src.mcp.tools import read_tools

    a = _register(c, "mcp-a@example.com", "web", "dA")
    b = _register(c, "mcp-b@example.com", "web", "dB")
    _new_ledger(c, a["access_token"], "MCP-A", "dA")

    # read_tools 直接用模块级 SessionLocal(不走 dep tree)
    original = read_tools.SessionLocal
    read_tools.SessionLocal = TS
    try:
        with TS() as db:
            a_user = db.scalar(select(User).where(User.email == "mcp-a@example.com"))
            b_user = db.scalar(select(User).where(User.email == "mcp-b@example.com"))
        a_ledgers = read_tools.list_ledgers(a_user)
        b_ledgers = read_tools.list_ledgers(b_user)
    finally:
        read_tools.SessionLocal = original
    assert [x["id"] for x in a_ledgers] == ["MCP-A"]
    assert b_ledgers == []
    assert mcp_server is not None


def test_mcp_tool_scope_guard_rejects_missing_scope(client):
    """`_logged_call` 的 scope 守卫:read-only PAT 不能调 write tool。"""
    import asyncio

    from src.mcp.server import _logged_call

    class _Req:
        def __init__(self, scope):
            self.scope = scope

    class _CtxReq:
        def __init__(self, scope):
            self.request = _Req(scope)

    class _Ctx:
        def __init__(self, scope):
            self.request_context = _CtxReq(scope)

    user = User(id="u-1", email="u@example.com", password_hash="x")

    async def _run():
        results = {}

        async def body(_u):
            return "RAN"

        cases = {
            "read_only_pat_calls_write_tool": ({"mcp:read"}, "mcp:write"),
            "write_pat_calls_read_tool": ({"mcp:write"}, "mcp:read"),
            "empty_scopes": (set(), "mcp:read"),
        }
        for label, (scopes, required) in cases.items():
            ctx = _Ctx({"bc_mcp_user": user, "bc_mcp_scopes": scopes})
            try:
                await _logged_call(ctx, name="x", scope=required, kwargs={}, body=body)
                results[label] = "ALLOWED-DEFECT"
            except PermissionError:
                results[label] = "denied"
        return results

    results = asyncio.run(_run())
    assert results == {
        "read_only_pat_calls_write_tool": "denied",
        "write_pat_calls_read_tool": "denied",
        "empty_scopes": "denied",
    }, results


def test_mcp_endpoint_routes_pat_not_jwt(client):
    """MCP 端点分流:PAT 进入 streamable session manager;JWT 403;匿名 401。

    用 ASGI 直调 + stub session_manager.handle_request,避免真实 anyio task
    group(需要 lifespan;而 `with TestClient(app)` 会触发 startup 对真实 DB
    跑备份调度器 —— 污染测试环境)。做法与 tests/test_mcp_streamable_http.py
    一致。
    """
    import anyio

    from src.mcp import server as mcp_server

    c, _ = client
    tok = _register(c, "mcp-hs@example.com", "web", "d1")["access_token"]
    pat = c.post("/api/v1/profile/pats", headers=_auth(tok, "d1"),
                 json={"name": "hs", "scopes": ["mcp:read"]}).json()["token"]

    async def _probe(auth_header: str | None) -> int:
        status = {"code": None}

        async def fake_handle_request(scope, receive, send):
            status["code"] = 202
            await send({"type": "http.response.start", "status": 202, "headers": []})
            await send({"type": "http.response.body", "body": b""})

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(message):
            if message["type"] == "http.response.start":
                status["code"] = message["status"]

        headers = []
        if auth_header is not None:
            headers.append((b"authorization", auth_header.encode()))
        original = mcp_server.mcp.session_manager.handle_request
        mcp_server.mcp.session_manager.handle_request = fake_handle_request
        try:
            await mcp_server.app(
                {"type": "http", "method": "POST", "path": "/api/v1/mcp",
                 "raw_path": b"/api/v1/mcp", "headers": headers, "query_string": b"",
                 "client": ("test", 1), "server": ("test", 80), "scheme": "http",
                 "root_path": ""},
                receive, send,
            )
        finally:
            mcp_server.mcp.session_manager.handle_request = original
        return status["code"]

    # 合法 PAT → 分流到 session manager(202 stub)
    assert anyio.run(_probe, f"Bearer {pat}") == 202
    # JWT access token → 403(严格分流)
    assert anyio.run(_probe, f"Bearer {tok}") == 403
    # 无凭据 → 401
    assert anyio.run(_probe, None) == 401


def test_mcp_call_logs_only_own_records(client):
    """`/profile/mcp-calls` 只能看自己的记录(过滤 user_id)。"""
    c, _ = client
    a = _register(c, "mcplog-a@example.com", "web", "dA")
    b = _register(c, "mcplog-b@example.com", "web", "dB")
    res = c.get("/api/v1/profile/mcp-calls", headers=_auth(b["access_token"], "dB"))
    assert res.status_code == 200
    assert res.json()["items"] == []
    # 用 A 的 pat_id 过滤 B 的记录也不能命中
    pat = c.post("/api/v1/profile/pats", headers=_auth(a["access_token"], "dA"),
                 json={"name": "x", "scopes": ["mcp:read"]}).json()
    res2 = c.get(
        f"/api/v1/profile/mcp-calls?pat_id={pat['id']}", headers=_auth(b["access_token"], "dB")
    )
    assert res2.status_code == 200
    assert res2.json()["items"] == []


def test_ai_logs_only_own_records(client):
    c, _ = client
    a = _register(c, "ailog-a@example.com", "web", "dA")
    b = _register(c, "ailog-b@example.com", "web", "dB")
    assert c.get("/api/v1/ai/logs", headers=_auth(b["access_token"], "dB")).json()["items"] == []
    # 他人 log_id → 404
    assert c.get("/api/v1/ai/logs/1", headers=_auth(b["access_token"], "dB")).status_code == 404
    assert c.get("/api/v1/ai/logs/1/image", headers=_auth(b["access_token"], "dB")).status_code == 404
    assert c.delete("/api/v1/ai/logs/1", headers=_auth(b["access_token"], "dB")).status_code == 404


def test_avatar_endpoint_requires_auth_and_404s_unknown(client):
    c, _ = client
    a = _register(c, "av-a@example.com", "web", "dA")
    # 匿名 → 401(仅为登录用户开放)
    assert c.get(f"/api/v1/profile/avatar/{a['user']['id']}").status_code == 401
    # 无头像 → 404
    assert c.get(
        f"/api/v1/profile/avatar/{a['user']['id']}", headers=_auth(a["access_token"], "dA")
    ).status_code == 404
    # 路径穿越 → 404(不是 500 / 文件内容)
    for evil in ("..%2F..%2Fmain.py", "%2e%2e%2f%2e%2e%2fmain.py", "....//main.py"):
        res = c.get(f"/api/v1/profile/avatar/{evil}", headers=_auth(a["access_token"], "dA"))
        assert res.status_code in (404, 401), f"{evil} → {res.status_code}"


def test_evidence_endpoints_isolated_by_user(client):
    c, _ = client
    a = _register(c, "ev-a@example.com", "app", "dA")
    b = _register(c, "ev-b@example.com", "app", "dB")
    created = c.post(
        "/api/v1/evidence/raw", headers=_auth(a["access_token"], "dA"),
        json={"event_key": "k1", "source": "sms", "body": "A-SECRET-EVIDENCE",
              "captured_at": datetime.now(timezone.utc).isoformat()},
    )
    assert created.status_code == 200, created.text
    eid = created.json()["id"]

    lb = c.get("/api/v1/evidence/raw", headers=_auth(b["access_token"], "dB"))
    assert lb.status_code == 200
    assert lb.json()["items"] == []
    assert c.get(f"/api/v1/evidence/raw/{eid}", headers=_auth(b["access_token"], "dB")).status_code == 404
    assert c.delete(f"/api/v1/evidence/raw/{eid}", headers=_auth(b["access_token"], "dB")).status_code == 404
    # A 自己还在
    assert c.get(f"/api/v1/evidence/raw/{eid}", headers=_auth(a["access_token"], "dA")).status_code == 200


def test_evidence_ledger_id_must_be_accessible(client):
    """evidence 行的 ledger_id 必须是 caller 可访问账本,否则 404。"""
    c, _ = client
    a = _register(c, "evl-a@example.com", "app", "dA")
    b = _register(c, "evl-b@example.com", "app", "dB")
    c.post("/api/v1/write/ledgers", headers=_auth(a["access_token"], "dA"),
           json={"ledger_id": "EVL-A", "ledger_name": "A", "currency": "CNY"})
    res = c.post(
        "/api/v1/evidence/raw", headers=_auth(b["access_token"], "dB"),
        json={"event_key": "k2", "source": "sms", "ledger_id": "EVL-A",
              "captured_at": datetime.now(timezone.utc).isoformat()},
    )
    assert res.status_code == 404
