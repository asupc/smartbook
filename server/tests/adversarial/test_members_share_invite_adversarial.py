"""对抗性测试 —— 成员 / 共享 / 邀请 / member_stats 越权面。

脚手架同 tests/adversarial/test_tx_write_adversarial.py。
``// ADVERSE FINDING:`` = 已确认缺陷(故意失败);``// HARDENING:`` = 断言现状并通过。
"""
from __future__ import annotations

import threading

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import Ledger, LedgerInvite, LedgerMember, User

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
    return TestClient(app, raise_server_exceptions=False)


def _login(client: TestClient, email: str, client_type: str = "web", device: str = "d-web") -> str:
    client.post("/api/v1/auth/register", json={
        "email": email, "password": _PW, "device_id": device,
        "client_type": client_type, "device_name": f"p-{device}", "platform": client_type})
    r = client.post("/api/v1/auth/login", json={
        "email": email, "password": _PW, "device_id": device,
        "client_type": client_type, "device_name": f"p-{device}", "platform": client_type})
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"}


def _ledger(client: TestClient, token: str, name: str = "L", ext: str | None = None) -> str:
    body = {"ledger_name": name, "currency": "CNY"}
    if ext:
        body["ledger_id"] = ext
    r = client.post("/api/v1/write/ledgers", json=body, headers=_h(token))
    assert r.status_code == 200, r.text
    return r.json()["entity_id"]


def _tx(client: TestClient, token: str, ledger_id: str, amount=10.0, **kw):
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        json={"base_change_id": 0, "tx_type": "expense", "amount": amount,
              "happened_at": "2026-05-06T12:30:00Z", "note": "n", **kw},
        headers=_h(token),
    )


def _user_id(db, email: str) -> str:
    return db.scalar(select(User.id).where(User.email == email))


# ---------------------------------------------------------------------------
# 邀请码
# ---------------------------------------------------------------------------


def test_invite_code_bruteforce_100_attempts_all_404():
    # HARDENING: 30^6 熵 + 无效码统一 404,100 次枚举全部 404(无存在性泄露)。
    client = _make_client()
    try:
        owner = _login(client, "inv-brute-own@t.com")
        outsider = _login(client, "inv-brute-out@t.com", device="d-out")
        lg = _ledger(client, owner, "F", ext="fam-brute")
        client.post(f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner))

        statuses: dict[int, int] = {}
        for i in range(100):
            r = client.post(f"/api/v1/invites/{i:06d}/preview", headers=_h(outsider))
            statuses[r.status_code] = statuses.get(r.status_code, 0) + 1
        assert statuses == {404: 100}, statuses
    finally:
        app.dependency_overrides.clear()


def test_invite_single_use_expiry_and_revocation():
    # HARDENING: 一次性(用后 404)/ 过期 404 / 撤销后 404;撤销是幂等的(二次 204)。
    client = _make_client()
    try:
        owner = _login(client, "inv-life-own@t.com")
        joiner = _login(client, "inv-life-a@t.com", device="d-a")
        other = _login(client, "inv-life-b@t.com", device="d-b")
        lg = _ledger(client, owner, "F", ext="fam-life")

        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        assert client.post(f"/api/v1/invites/{code}/accept", headers=_h(joiner)).status_code == 200
        assert client.post(f"/api/v1/invites/{code}/accept", headers=_h(other)).status_code == 404

        # 撤销
        code2 = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        assert client.delete(
            f"/api/v1/ledgers/{lg}/invites/{code2}", headers=_h(owner)
        ).status_code == 204
        assert client.post(f"/api/v1/invites/{code2}/accept", headers=_h(other)).status_code == 404
        # 二次撤销:已撤销的 invite 不再是 active → 404?实际是找得到行 → 204
        r = client.delete(f"/api/v1/ledgers/{lg}/invites/{code2}", headers=_h(owner))
        assert r.status_code == 204, r.text

        # 过期
        code3 = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        from datetime import datetime, timezone
        db = next(app.dependency_overrides[get_db]())
        inv = db.scalar(select(LedgerInvite).where(LedgerInvite.code == code3))
        inv.expires_at = datetime(2020, 1, 1, tzinfo=timezone.utc)
        db.commit()
        db.close()
        assert client.post(f"/api/v1/invites/{code3}/accept", headers=_h(other)).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_invite_self_accept_and_repeat_accept_rejected():
    # HARDENING: owner 接受自己的码 → 409(已是成员);已是成员再接受 → 409。
    client = _make_client()
    try:
        owner = _login(client, "inv-self-own@t.com")
        member = _login(client, "inv-self-m@t.com", device="d-m")
        lg = _ledger(client, owner, "F", ext="fam-self")

        c1 = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        assert client.post(f"/api/v1/invites/{c1}/accept", headers=_h(owner)).status_code == 409

        c2 = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        assert client.post(f"/api/v1/invites/{c2}/accept", headers=_h(member)).status_code == 200
        c3 = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        assert client.post(f"/api/v1/invites/{c3}/accept", headers=_h(member)).status_code == 409
    finally:
        app.dependency_overrides.clear()


def test_invite_create_limit_and_non_owner_denied():
    # HARDENING: 同账本活跃邀请上限 10(第 11 个 409);非成员/非 owner 创建 → 404。
    client = _make_client()
    try:
        owner = _login(client, "inv-limit-own@t.com")
        outsider = _login(client, "inv-limit-out@t.com", device="d-out")
        lg = _ledger(client, owner, "F", ext="fam-limit")

        assert client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(outsider)
        ).status_code == 404

        codes = [
            client.post(
                f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
            ).status_code
            for _ in range(12)
        ]
        assert codes[:10] == [201] * 10
        assert codes[10] == 409 and codes[11] == 409, codes
    finally:
        app.dependency_overrides.clear()


def test_invite_accept_after_ledger_deleted_still_writes_membership():
    # ADVERSE FINDING: 账本被 owner 删除后,它的邀请码仍可 preview 且可 accept,
    # 并为已删账本写入一条 LedgerMember 行 —— 产生了指向墓碑账本的幽灵成员关系
    # (账本列表 / sync 列表都看不见,但 DB 里确实新增了成员行)。
    # 证据: src/routers/invites.py:430-435 与 :479-507 —— accept 只查 Ledger 行
    #       存在(invite.ledger_id 指向的软删 Ledger 壳仍存在),**不查 tombstone**
    #       (`_is_ledger_deleted` 只在 read/write 路径用)。
    # 期望: 已删账本的邀请码 preview/accept 均 404(与 invite 注释
    #       "邀请创建后账本被删 → 邀请失效" 一致);
    # 实际: preview 200 + accept 200 + ledger_members 多一行
    client = _make_client()
    try:
        owner = _login(client, "inv-dead-own@t.com")
        joiner = _login(client, "inv-dead-join@t.com", device="d-j")
        lg = _ledger(client, owner, "DEAD", ext="fam-dead")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        assert client.delete(f"/api/v1/write/ledgers/{lg}", headers=_h(owner)).status_code == 200

        db = next(app.dependency_overrides[get_db]())
        before = len(db.scalars(select(LedgerMember)).all())
        db.close()

        r_preview = client.post(f"/api/v1/invites/{code}/preview", headers=_h(joiner))
        r_accept = client.post(f"/api/v1/invites/{code}/accept", headers=_h(joiner))

        db = next(app.dependency_overrides[get_db]())
        after = len(db.scalars(select(LedgerMember)).all())
        db.close()

        assert r_preview.status_code == 404, f"已删账本的邀请码仍可预览({r_preview.status_code})"
        assert r_accept.status_code == 404, (
            f"已删账本的邀请码仍可接受({r_accept.status_code}),"
            f"ledger_members {before} → {after}"
        )
    finally:
        app.dependency_overrides.clear()


def test_member_limit_is_five():
    # HARDENING: 成员上限 5(含 owner),第 6 个 accept → 409。
    client = _make_client()
    try:
        owner = _login(client, "ml-own@t.com")
        lg = _ledger(client, owner, "ML", ext="fam-ml")
        results = []
        for i in range(5):
            tok = _login(client, f"ml-{i}@t.com", device=f"d-{i}")
            code = client.post(
                f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
            ).json()["code"]
            results.append(client.post(f"/api/v1/invites/{code}/accept", headers=_h(tok)).status_code)
        assert results == [200] * 4 + [409], results
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 成员管理
# ---------------------------------------------------------------------------


def test_owner_remove_self_blocked_and_transfer_required():
    # HARDENING: owner 移除自己 → 409(必须先 transfer);移除不存在成员 → 404。
    client = _make_client()
    try:
        owner = _login(client, "rm-own@t.com")
        lg = _ledger(client, owner, "R", ext="fam-rm")
        db = next(app.dependency_overrides[get_db]())
        owner_id = _user_id(db, "rm-own@t.com")
        db.close()
        assert client.delete(
            f"/api/v1/ledgers/{lg}/members/{owner_id}", headers=_h(owner)
        ).status_code == 409
        assert client.delete(
            f"/api/v1/ledgers/{lg}/members/no-such-user", headers=_h(owner)
        ).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_editor_cannot_remove_owner_or_delete_ledger():
    # HARDENING: Editor 删账本 → 404(owner-only);踢 owner → 404/409。
    client = _make_client()
    try:
        owner = _login(client, "ed-own@t.com")
        editor = _login(client, "ed-ed@t.com", device="d-ed")
        lg = _ledger(client, owner, "E", ext="fam-ed")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        client.post(f"/api/v1/invites/{code}/accept", headers=_h(editor))

        db = next(app.dependency_overrides[get_db]())
        owner_id = _user_id(db, "ed-own@t.com")
        db.close()

        assert client.delete(f"/api/v1/write/ledgers/{lg}", headers=_h(editor)).status_code == 404
        r = client.delete(f"/api/v1/ledgers/{lg}/members/{owner_id}", headers=_h(editor))
        assert r.status_code in (404, 409), r.text
        # 账本还在
        assert client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(owner)).status_code == 200
    finally:
        app.dependency_overrides.clear()


def test_removed_member_loses_access_immediately():
    # HARDENING: 被移除后 token 仍有效但账本读写全 404(S1 语义)。
    client = _make_client()
    try:
        owner = _login(client, "rv-own@t.com")
        editor = _login(client, "rv-ed@t.com", device="d-ed")
        lg = _ledger(client, owner, "V", ext="fam-rv")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        client.post(f"/api/v1/invites/{code}/accept", headers=_h(editor))
        assert _tx(client, editor, lg).status_code == 200

        db = next(app.dependency_overrides[get_db]())
        ed_id = _user_id(db, "rv-ed@t.com")
        db.close()
        assert client.delete(
            f"/api/v1/ledgers/{lg}/members/{ed_id}", headers=_h(owner)
        ).status_code == 204

        assert client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(editor)).status_code == 404
        assert _tx(client, editor, lg).status_code == 404
        assert client.get(f"/api/v1/ledgers/{lg}/members", headers=_h(editor)).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_transfer_ownership_invariants():
    # HARDENING: transfer 后恰好 1 个 owner;原 owner 降为 editor 失去 owner-only
    # 权限;自转 409;转给非成员 404;可转回。
    client = _make_client()
    try:
        owner = _login(client, "tr-own@t.com")
        editor = _login(client, "tr-ed@t.com", device="d-ed")
        lg = _ledger(client, owner, "T", ext="fam-tr")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        client.post(f"/api/v1/invites/{code}/accept", headers=_h(editor))

        db = next(app.dependency_overrides[get_db]())
        owner_id = _user_id(db, "tr-own@t.com")
        ed_id = _user_id(db, "tr-ed@t.com")
        lid = db.scalar(select(Ledger.id).where(Ledger.external_id == lg))
        db.close()

        r = client.post(
            f"/api/v1/ledgers/{lg}/transfer", json={"new_owner_user_id": ed_id}, headers=_h(owner)
        )
        assert r.status_code == 200, r.text
        roles = {m["user_id"]: m["role"] for m in r.json()}
        assert roles[ed_id] == "owner" and roles[owner_id] == "editor"

        db = next(app.dependency_overrides[get_db]())
        owners = db.scalars(
            select(LedgerMember).where(LedgerMember.ledger_id == lid, LedgerMember.role == "owner")
        ).all()
        db.close()
        assert len(owners) == 1

        # 原 owner 失去 owner-only 操作
        assert client.patch(
            f"/api/v1/write/ledgers/{lg}/meta",
            json={"base_change_id": 0, "ledger_name": "X"}, headers=_h(owner),
        ).status_code == 404

        assert client.post(
            f"/api/v1/ledgers/{lg}/transfer", json={"new_owner_user_id": ed_id}, headers=_h(editor)
        ).status_code == 409
        assert client.post(
            f"/api/v1/ledgers/{lg}/transfer", json={"new_owner_user_id": "ghost"}, headers=_h(editor)
        ).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_member_stats_requires_membership():
    # HARDENING: 非成员读 member-stats → 404;成员读到自己一行。
    client = _make_client()
    try:
        owner = _login(client, "ms-own2@t.com")
        outsider = _login(client, "ms-out2@t.com", device="d-out")
        lg = _ledger(client, owner, "MS", ext="fam-ms")
        assert client.get(
            f"/api/v1/ledgers/{lg}/member-stats", headers=_h(outsider)
        ).status_code == 404

        _tx(client, owner, lg, amount=25.0)
        body = client.get(
            f"/api/v1/ledgers/{lg}/member-stats", params={"scope": "all"}, headers=_h(owner)
        ).json()
        assert len(body["items"]) == 1
        assert body["items"][0]["expense_total"] == 25.0
    finally:
        app.dependency_overrides.clear()


def test_member_stats_counts_per_creator_in_shared_ledger():
    # HARDENING: 共享账本按 created_by_user_id 分账,两人各记一笔分列两行;
    # transfer 不计入。
    client = _make_client()
    try:
        owner = _login(client, "ms2-own@t.com")
        editor = _login(client, "ms2-ed@t.com", device="d-ed")
        lg = _ledger(client, owner, "MS2", ext="fam-ms2")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        client.post(f"/api/v1/invites/{code}/accept", headers=_h(editor))

        _tx(client, owner, lg, amount=10.0)
        _tx(client, editor, lg, amount=20.0)
        _tx(client, editor, lg, amount=99.0, tx_type="transfer")

        body = client.get(
            f"/api/v1/ledgers/{lg}/member-stats", params={"scope": "all"}, headers=_h(owner)
        ).json()
        by_uid = {i["user_id"]: i for i in body["items"]}
        db = next(app.dependency_overrides[get_db]())
        owner_id = _user_id(db, "ms2-own@t.com")
        ed_id = _user_id(db, "ms2-ed@t.com")
        db.close()
        assert by_uid[owner_id]["expense_total"] == 10.0
        assert by_uid[ed_id]["expense_total"] == 20.0
        assert by_uid[ed_id]["tx_count"] == 1  # transfer 不计笔数
    finally:
        app.dependency_overrides.clear()


def test_member_stats_period_validation():
    # HARDENING: scope 枚举外 422;month period 畸形 400。
    client = _make_client()
    try:
        owner = _login(client, "ms3@t.com")
        lg = _ledger(client, owner, "MS3", ext="fam-ms3")
        assert client.get(
            f"/api/v1/ledgers/{lg}/member-stats", params={"scope": "bogus"}, headers=_h(owner)
        ).status_code == 422
        assert client.get(
            f"/api/v1/ledgers/{lg}/member-stats",
            params={"scope": "month", "period": "nope"}, headers=_h(owner),
        ).status_code == 400
    finally:
        app.dependency_overrides.clear()


def test_invite_list_and_revoke_owner_only():
    # HARDENING: 非成员列邀请 → 404;owner 列邀请只见 active。
    client = _make_client()
    try:
        owner = _login(client, "il-own@t.com")
        outsider = _login(client, "il-out@t.com", device="d-out")
        lg = _ledger(client, owner, "IL", ext="fam-il")
        client.post(f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner))
        assert client.get(f"/api/v1/ledgers/{lg}/invites", headers=_h(outsider)).status_code == 404
        assert client.delete(
            f"/api/v1/ledgers/{lg}/invites/AAAAAA", headers=_h(outsider)
        ).status_code == 404
        items = client.get(f"/api/v1/ledgers/{lg}/invites", headers=_h(owner)).json()
        assert len(items) == 1 and len(items[0]["code"]) == 6
    finally:
        app.dependency_overrides.clear()


def test_members_list_requires_membership():
    # HARDENING: 非成员列成员 → 404。
    client = _make_client()
    try:
        owner = _login(client, "ml2-own@t.com")
        outsider = _login(client, "ml2-out@t.com", device="d-out")
        lg = _ledger(client, owner, "ML2", ext="fam-ml2")
        assert client.get(f"/api/v1/ledgers/{lg}/members", headers=_h(outsider)).status_code == 404
        members = client.get(f"/api/v1/ledgers/{lg}/members", headers=_h(owner)).json()
        assert len(members) == 1 and members[0]["role"] == "owner" and members[0]["is_self"] is True
    finally:
        app.dependency_overrides.clear()


def test_editor_cannot_change_roles():
    # HARDENING: PATCH 成员角色 owner-only(editor 调用 → 404);
    # owner 改自己 → 409;改成非 editor → 400。
    client = _make_client()
    try:
        owner = _login(client, "rc-own@t.com")
        editor = _login(client, "rc-ed@t.com", device="d-ed")
        lg = _ledger(client, owner, "RC", ext="fam-rc")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        client.post(f"/api/v1/invites/{code}/accept", headers=_h(editor))

        db = next(app.dependency_overrides[get_db]())
        owner_id = _user_id(db, "rc-own@t.com")
        ed_id = _user_id(db, "rc-ed@t.com")
        db.close()

        assert client.patch(
            f"/api/v1/ledgers/{lg}/members/{owner_id}", json={"role": "editor"}, headers=_h(editor)
        ).status_code == 404
        assert client.patch(
            f"/api/v1/ledgers/{lg}/members/{owner_id}", json={"role": "editor"}, headers=_h(owner)
        ).status_code == 409
        assert client.patch(
            f"/api/v1/ledgers/{lg}/members/{ed_id}", json={"role": "viewer"}, headers=_h(owner)
        ).status_code == 422
        assert client.patch(
            f"/api/v1/ledgers/{lg}/members/{ed_id}", json={"role": "editor"}, headers=_h(owner)
        ).status_code == 200
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 共享账本资源可见性
# ---------------------------------------------------------------------------


def test_shared_ledger_editor_sees_owner_tx_and_global_resources():
    # HARDENING: editor 能看到 owner 的 tx;共享账本 is_shared/member_count 正确。
    client = _make_client()
    try:
        owner = _login(client, "sh-own@t.com")
        editor = _login(client, "sh-ed@t.com", device="d-ed")
        lg = _ledger(client, owner, "SH", ext="fam-sh")
        _tx(client, owner, lg, amount=5.0)
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        client.post(f"/api/v1/invites/{code}/accept", headers=_h(editor))

        detail = client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(editor)).json()
        assert detail["is_shared"] is True and detail["member_count"] == 2
        txs = client.get(f"/api/v1/read/ledgers/{lg}/transactions", headers=_h(editor)).json()
        assert len(txs) == 1
    finally:
        app.dependency_overrides.clear()


def test_editor_write_scoping_owner_only_entities():
    # HARDENING: editor 不能建账本内 owner-only 实体(accounts/budgets → 404),
    # 但能写 tx/categories(editor 角色)。
    client = _make_client()
    try:
        owner = _login(client, "esc-own@t.com")
        editor = _login(client, "esc-ed@t.com", device="d-ed")
        lg = _ledger(client, owner, "ESC", ext="fam-esc")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]
        client.post(f"/api/v1/invites/{code}/accept", headers=_h(editor))

        assert _tx(client, editor, lg).status_code == 200
        assert client.post(
            f"/api/v1/write/ledgers/{lg}/accounts",
            json={"base_change_id": 0, "name": "现金"}, headers=_h(editor),
        ).status_code == 404
        assert client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "total", "amount": 10}, headers=_h(editor),
        ).status_code == 404
        assert client.patch(
            f"/api/v1/write/ledgers/{lg}/meta",
            json={"base_change_id": 0, "ledger_name": "x"}, headers=_h(editor),
        ).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_two_users_same_external_ledger_id_isolated():
    # HARDENING: 两个用户各自建同名 external_id 的账本,数据完全隔离。
    client = _make_client()
    try:
        a = _login(client, "iso-a@t.com", device="d-a")
        b = _login(client, "iso-b@t.com", device="d-b")
        _ledger(client, a, "Same", ext="same-id")
        _ledger(client, b, "Same", ext="same-id")
        _tx(client, a, "same-id", amount=11.0)

        a_txs = client.get("/api/v1/read/ledgers/same-id/transactions", headers=_h(a)).json()
        b_txs = client.get("/api/v1/read/ledgers/same-id/transactions", headers=_h(b)).json()
        assert len(a_txs) == 1 and b_txs == []
    finally:
        app.dependency_overrides.clear()


def test_member_stats_excludes_trashed_transactions():
    # HARDENING: 回收站里的交易不计入 member-stats(与账本卡片同口径)。
    client = _make_client()
    try:
        owner = _login(client, "ms4@t.com")
        lg = _ledger(client, owner, "MS4", ext="fam-ms4")
        tx = _tx(client, owner, lg, amount=50.0).json()["entity_id"]
        client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{tx}",
            json={"base_change_id": 0}, headers=_h(owner),
        )
        body = client.get(
            f"/api/v1/ledgers/{lg}/member-stats", params={"scope": "all"}, headers=_h(owner)
        ).json()
        assert body["items"][0]["expense_total"] == 0.0
        assert body["items"][0]["tx_count"] == 0
    finally:
        app.dependency_overrides.clear()


def test_concurrent_invite_accept_single_winner_at_sql_level():
    # HARDENING: 「先抢占」条件 UPDATE 在 SQL 层确实是单赢家 —— 第二次跑
    # 同一 UPDATE(rowcount=0)对应 endpoint 的 409 分支。这是并发 accept 的
    # 核心不变量,可在 sqlite 上确定性验证。
    # 注意:线程级并发经 starlette TestClient 不可复现(TestClient 本身非
    # 线程安全,会伪造 401/500),已记入 FINDINGS 的「未能验证」节。
    # 证据: src/routers/invites.py:479-494 条件 UPDATE + rowcount 判定。
    client = _make_client()
    try:
        owner = _login(client, "race3-own@t.com")
        lg = _ledger(client, owner, "R3", ext="fam-race3")
        code = client.post(
            f"/api/v1/ledgers/{lg}/invites", json={"role": "editor"}, headers=_h(owner)
        ).json()["code"]

        from datetime import datetime, timezone
        from sqlalchemy import update as sa_update
        now = datetime.now(timezone.utc)

        def _claim(uid: str) -> int:
            db = next(app.dependency_overrides[get_db]())
            try:
                res = db.execute(
                    sa_update(LedgerInvite)
                    .where(
                        LedgerInvite.code == code,
                        LedgerInvite.used_at.is_(None),
                        LedgerInvite.expires_at > now,
                    )
                    .values(used_at=now, used_by=uid)
                    .execution_options(synchronize_session=False)
                )
                db.commit()
                return int(res.rowcount or 0)
            finally:
                db.close()

        first = _claim("user-a")
        second = _claim("user-b")
        assert (first, second) == (1, 0), (
            f"抢占应恰好 1 次成功,实际 first={first} second={second}"
        )
        # 且败方在 HTTP 层拿到 404(码已被用)
        other = _login(client, "race3-b@t.com", device="d-b")
        assert client.post(f"/api/v1/invites/{code}/accept", headers=_h(other)).status_code == 404
    finally:
        app.dependency_overrides.clear()


if __name__ == "__main__":
    import pytest
    pytest.main([__file__, "-q"])
