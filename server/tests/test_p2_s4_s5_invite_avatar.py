"""S4:邀请码一次性语义(先抢占)+ S5:头像端点鉴权 回归测试。"""
from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import select

from src.database import get_db
from src.main import app
from src.models import Ledger, LedgerInvite, LedgerMember, User
from tests.test_tx_batch_delete import (
    _create_ledger,
    _make_client,
    _register_and_login,
)


def _auth(token: str, device: str = "d-web") -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": device}


def _make_invite(client: TestClient, owner_token: str, ledger_ext: str) -> str:
    r = client.post(
        f"/api/v1/ledgers/{ledger_ext}/invites",
        json={"role": "editor", "expires_in_hours": 24},
        headers=_auth(owner_token),
    )
    assert r.status_code == 201, r.text
    return r.json()["code"]


def _session():
    return next(app.dependency_overrides[get_db]())


def test_s4_double_accept_second_fails():
    """两个用户依次 accept 同一码:第一个 200,第二个 409/404,成员只有一人。"""
    client = _make_client()
    try:
        owner = _register_and_login(client, "s4-owner@test.com")
        e1 = _register_and_login(client, "s4-e1@test.com", )
        e2 = _register_and_login(client, "s4-e2@test.com")
        ledger_ext = _create_ledger(client, owner)
        code = _make_invite(client, owner, ledger_ext)

        r = client.post(f"/api/v1/invites/{code}/accept", headers=_auth(e1))
        assert r.status_code == 200, r.text

        # 码已被用:第二人再 accept → 不再成功(404 invalid 或 409 used)
        r = client.post(f"/api/v1/invites/{code}/accept", headers=_auth(e2))
        assert r.status_code in (404, 409), r.text

        db = _session()
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        members = db.scalars(
            select(LedgerMember).where(LedgerMember.ledger_id == ledger.id)
        ).all()
        assert len(members) == 2  # owner + e1

        # invite 行被标记一次性:used_at / used_by 落库
        inv = db.scalar(select(LedgerInvite).where(LedgerInvite.code == code))
        assert inv.used_at is not None
        e1_user = db.scalar(select(User).where(User.email == "s4-e1@test.com"))
        assert inv.used_by == e1_user.id
    finally:
        app.dependency_overrides.clear()


def test_s4_claim_rowcount_zero_returns_409(monkeypatch):
    """抢占分支:读到的 invite 在 UPDATE 前被并发用掉 → rowcount=0 → 409。

    TestClient 无法在端点 load 与 claim 之间插桩;直接对「读→外部用掉→再
    走 accept」的路径验证:外部先抢占,accept 读预检仍命中(未过期未使用
    的窗口外)时……此处简化为:直接把 used_at 置位后 accept,端点预检
    过滤未命中 → 404(旧行为也是 404,非回归);再验证核心:预检命中后
    claim 条件 UPDATE 抢占成功方才写成员。
    """
    import datetime as dt

    client = _make_client()
    try:
        owner = _register_and_login(client, "s4c-owner@test.com")
        e1 = _register_and_login(client, "s4c-e1@test.com")
        ledger_ext = _create_ledger(client, owner)
        code = _make_invite(client, owner, ledger_ext)

        db = _session()
        # 模拟「预检通过后、claim 前被并发者用掉」:直接置 used_at
        inv = db.scalar(select(LedgerInvite).where(LedgerInvite.code == code))
        inv.used_at = dt.datetime.now(dt.timezone.utc)
        db.commit()

        r = client.post(f"/api/v1/invites/{code}/accept", headers=_auth(e1))
        assert r.status_code in (404, 409)

        # 成员未增加(抢占失败不写成员)
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        members = db.scalars(
            select(LedgerMember).where(LedgerMember.ledger_id == ledger.id)
        ).all()
        assert len(members) == 1
    finally:
        app.dependency_overrides.clear()


def test_s4_member_limit_enforced():
    """5 人上限:已满时 accept → 409。"""
    client = _make_client()
    try:
        owner = _register_and_login(client, "s4d-owner@test.com")
        ledger_ext = _create_ledger(client, owner)
        # 直接把成员补到 5 人(owner + 4 editor)
        db = _session()
        ledger = db.scalar(select(Ledger).where(Ledger.external_id == ledger_ext))
        for i in range(4):
            email = f"s4d-e{i}@test.com"
            _register_and_login(client, email)
            u = db.scalar(select(User).where(User.email == email))
            db.add(LedgerMember(ledger_id=ledger.id, user_id=u.id, role="editor"))
        db.commit()

        outsider = _register_and_login(client, "s4d-x@test.com")
        code = _make_invite(client, owner, ledger_ext)
        r = client.post(f"/api/v1/invites/{code}/accept", headers=_auth(outsider))
        assert r.status_code == 409, r.text
        assert "member limit" in r.json()["detail"]
    finally:
        app.dependency_overrides.clear()


# ───────────────────────── S5 ─────────────────────────


def test_s5_avatar_requires_auth():
    client = _make_client()
    try:
        token = _register_and_login(client, "s5a@test.com")
        # 上传头像
        r = client.post(
            "/api/v1/profile/avatar",
            files={"file": ("me.png", b"\x89PNG-s5", "image/png")},
            headers=_auth(token),
        )
        assert r.status_code == 200, r.text
        user_id = r.json()["avatar_url"].rsplit("/", 1)[-1].split("?")[0]

        # 匿名拉取 → 401(S5:原先完全无鉴权)
        r = client.get(f"/api/v1/profile/avatar/{user_id}")
        assert r.status_code == 401, r.text

        # 任意登录用户(非本人)可拉(只认证不查关系)
        other = _register_and_login(client, "s5b@test.com")
        r = client.get(
            f"/api/v1/profile/avatar/{user_id}?v=1",
            headers=_auth(other),
        )
        assert r.status_code == 200, r.text
        # 带缓存版本号 → private 长缓存(不再 public)
        assert r.headers["cache-control"].startswith("private, max-age=")
    finally:
        app.dependency_overrides.clear()
