"""对抗性测试 —— 账本 / 预算 / 统计报表。

脚手架同 tests/adversarial/test_tx_write_adversarial.py。
``// ADVERSE FINDING:`` = 已确认缺陷(故意失败);``// HARDENING:`` = 断言现状并通过。
"""
from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import Ledger, ReadTxProjection

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


def _register_and_login(client: TestClient, email: str) -> str:
    client.post("/api/v1/auth/register", json={
        "email": email, "password": _PW, "device_id": "d-web",
        "client_type": "web", "device_name": "pytest", "platform": "web"})
    r = client.post("/api/v1/auth/login", json={
        "email": email, "password": _PW, "device_id": "d-web",
        "client_type": "web", "device_name": "pytest", "platform": "web"})
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "X-Device-ID": "d-web"}


def _now_iso() -> str:
    """预算用量按「当前周期」算,所以预算类测试必须用当下时间。"""
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


def _ledger(client: TestClient, token: str, name: str = "L", **kw):
    body = {"ledger_name": name, "currency": "CNY", **kw}
    return client.post("/api/v1/write/ledgers", json=body, headers=_h(token))


def _tx(client: TestClient, token: str, ledger_id: str, amount=10.0, note="n", **kw):
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        json={"base_change_id": 0, "tx_type": "expense", "amount": amount,
              "happened_at": "2026-05-06T12:30:00Z", "note": note, **kw},
        headers=_h(token),
    )


def _analytics(client: TestClient, token: str, ledger_id: str, **params) -> dict:
    """默认 scope=all(测试交易固定在 2026-05,不受"当前月"影响)。"""
    q = {"scope": "all", "ledger_id": ledger_id, **params}
    r = client.get("/api/v1/read/workspace/analytics", params=q, headers=_h(token))
    return {"status": r.status_code, "body": r.json() if r.headers.get("content-type", "").startswith("application/json") else r.text}


# ---------------------------------------------------------------------------
# 账本创建 / 元数据
# ---------------------------------------------------------------------------


def test_ledger_month_start_day_out_of_range_rejected():
    # HARDENING: month_start_day 只接受 1..28(schema 硬约束),0/29/30/31/32/负数
    # 全部 422。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-msd@t.com")
        for msd in (0, 29, 30, 31, 32, -1):
            r = _ledger(client, token, f"x{msd}", month_start_day=msd)
            assert r.status_code == 422, f"msd={msd} → {r.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_ledger_duplicate_name_allowed_different_external_id():
    # HARDENING: 账本名不唯一(只有 (user_id, external_id) 唯一)。同名账本合法,
    # 但 UI 上用户无法区分 —— 属产品取舍不是数据损坏。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-dupname@t.com")
        a = _ledger(client, token, "同名")
        b = _ledger(client, token, "同名")
        assert a.status_code == 200 and b.status_code == 200
        assert a.json()["entity_id"] != b.json()["entity_id"]
    finally:
        app.dependency_overrides.clear()


def test_ledger_invalid_currency_and_overlong_name_rejected():
    # HARDENING: 超长账本名 / 超长币种被 schema max_length 拦住(422)。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-badmeta@t.com")
        assert _ledger(client, token, "A" * 300).status_code == 422
        assert _ledger(
            client, token, "ok", currency="Z" * 30
        ).status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_ledger_emoji_and_weird_currency_accepted_verbatim():
    # HARDENING: emoji 名 / 任意字符币种码只要长度合格就接受,币种码不做
    # ISO 4217 校验(接受 "ZZZ9!")。单用户自部署影响有限。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-emoji@t.com")
        r = _ledger(client, token, "中文😀账本")
        assert r.status_code == 200
        lg = r.json()["entity_id"]
        r = client.patch(
            f"/api/v1/write/ledgers/{lg}/meta",
            json={"base_change_id": 0, "currency": "ZZZ9!"}, headers=_h(token),
        )
        assert r.status_code == 200
        detail = client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(token)).json()
        assert detail["currency"] == "ZZZ9!"
    finally:
        app.dependency_overrides.clear()


def test_ledger_rename_lww_last_write_wins():
    # HARDENING: 连续改名以最后一次为准(LWW),读路径返回最终值。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-rename@t.com")
        lg = _ledger(client, token, "first").json()["entity_id"]
        for name in ("rename-A", "rename-B"):
            r = client.patch(
                f"/api/v1/write/ledgers/{lg}/meta",
                json={"base_change_id": 0, "ledger_name": name}, headers=_h(token),
            )
            assert r.status_code == 200, r.text
        assert client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(token)).json()["ledger_name"] == "rename-B"
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 账本删除
# ---------------------------------------------------------------------------


def test_delete_ledger_clears_projections_and_blocks_recreate():
    # HARDENING: 删账本清 projection + 写 tombstone;同 external_id 重建被 409
    # 拒绝(软删模型下不可复用),写入被 404 挡住(无幽灵交易)。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-del@t.com")
        lg = _ledger(client, token, "D", ledger_id="fixed-del-id").json()["entity_id"]
        assert _tx(client, token, lg).status_code == 200

        assert client.delete(f"/api/v1/write/ledgers/{lg}", headers=_h(token)).status_code == 200
        assert client.get("/api/v1/read/ledgers", headers=_h(token)).json() == []

        db = next(app.dependency_overrides[get_db]())
        lid = db.scalar(select(Ledger.id).where(Ledger.external_id == lg))
        assert db.scalars(select(ReadTxProjection).where(ReadTxProjection.ledger_id == lid)).all() == []
        db.close()

        # 重建同 id → 409
        r = _ledger(client, token, "reborn", ledger_id="fixed-del-id")
        assert r.status_code == 409, r.text
        # 写入 → 404
        assert _tx(client, token, lg).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_double_delete_ledger_is_accepted_and_reports_ok():
    # HARDENING: 重复删账本返回 200(第二次仍是 tombstone 写入 + projection 清空)。
    # 幂等友好,但 new_change_id 前进了 —— 客户端会多收一条无意义事件。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-deldel@t.com")
        lg = _ledger(client, token, "DD", ledger_id="dbl-del").json()["entity_id"]
        r1 = client.delete(f"/api/v1/write/ledgers/{lg}", headers=_h(token))
        r2 = client.delete(f"/api/v1/write/ledgers/{lg}", headers=_h(token))
        assert r1.status_code == 200 and r2.status_code == 200
    finally:
        app.dependency_overrides.clear()


def test_delete_last_remaining_ledger_leaves_empty_state():
    # HARDENING: 删掉最后一个账本后所有读端点退化为空结果而不是 500
    # (ledger_id="" / 空 IN 列表均已覆盖)。
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-last@t.com")
        lg = _ledger(client, token, "only").json()["entity_id"]
        assert client.delete(f"/api/v1/write/ledgers/{lg}", headers=_h(token)).status_code == 200

        assert client.get("/api/v1/read/ledgers", headers=_h(token)).json() == []
        assert client.get("/api/v1/read/workspace/accounts", headers=_h(token)).json() == []
        assert client.get("/api/v1/read/workspace/ledger-counts", headers=_h(token)).json()["tx_count"] == 0
        assert client.get("/api/v1/read/workspace/analytics?scope=all", headers=_h(token)).status_code == 200
        assert client.get("/api/v1/read/workspace/net-worth-history", headers=_h(token)).json()["series"] == []
    finally:
        app.dependency_overrides.clear()


def test_ledger_stats_counts_trashed_rows():
    # ADVERSE FINDING: /read/ledgers/{id}/stats 的 transaction_count **不过滤
    # 软删行**,与 /read/ledgers/{id}(已过滤)对不上,mobile 的"深度同步检测"
    # 会一直判定服务端比本地多 → 反复全量同步。
    # 证据: src/routers/read/ledgers.py:150-155 `_count(ReadTxProjection)` 只按
    #       ledger_id COUNT;对比 src/routers/read/_shared.py:521-525
    #       _projection_totals 带 `deleted_at.is_(None)`。
    # 期望: 删除一笔后 transaction_count 由 3 变 2(与 /read/ledgers 一致);
    # 实际: 保持 3,而 /read/ledgers/{id}.transaction_count 已是 2
    client = _make_client()
    try:
        token = _register_and_login(client, "lg-stats@t.com")
        lg = _ledger(client, token, "S").json()["entity_id"]
        ids = [_tx(client, token, lg, note=f"t{i}").json()["entity_id"] for i in range(3)]
        assert client.get(f"/api/v1/read/ledgers/{lg}/stats", headers=_h(token)).json()["transaction_count"] == 3

        client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{ids[0]}",
            json={"base_change_id": 0}, headers=_h(token),
        )
        detail_count = client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(token)).json()["transaction_count"]
        stats_count = client.get(f"/api/v1/read/ledgers/{lg}/stats", headers=_h(token)).json()["transaction_count"]
        assert stats_count == detail_count, (
            f"stats.transaction_count={stats_count} 与 detail.transaction_count={detail_count} 不一致"
            f"(回收站行被计入 stats)"
        )
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 预算
# ---------------------------------------------------------------------------


def test_budget_amount_and_period_edges():
    # HARDENING: 预算 amount 必须 > 0(0 / 负数 422);非法 period 422;
    # start_day 越界 422。预算侧比交易侧严格。
    client = _make_client()
    try:
        token = _register_and_login(client, "bg-edges@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        bad = [
            {"type": "total", "amount": 0},
            {"type": "total", "amount": -5},
            {"type": "total", "amount": 10, "period": "quarterly"},
            {"type": "total", "amount": 10, "start_day": 0},
            {"type": "total", "amount": 10, "start_day": 29},
        ]
        for body in bad:
            r = client.post(
                f"/api/v1/write/ledgers/{lg}/budgets",
                json={"base_change_id": 0, **body}, headers=_h(token),
            )
            assert r.status_code == 422, f"{body} → {r.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_budget_total_uniqueness_enforced():
    # HARDENING: total 预算每账本只允许一条(第二条 400)。
    client = _make_client()
    try:
        token = _register_and_login(client, "bg-uniq@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        first = client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "total", "amount": 100}, headers=_h(token),
        )
        assert first.status_code == 200
        second = client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "total", "amount": 200}, headers=_h(token),
        )
        assert second.status_code == 400
    finally:
        app.dependency_overrides.clear()


def test_budget_usage_empty_and_no_budgets():
    # HARDENING: 没有预算时 usage 返回空 items;有预算但无交易 used=0。
    client = _make_client()
    try:
        token = _register_and_login(client, "bg-empty@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        assert client.get(f"/api/v1/read/ledgers/{lg}/budgets/usage", headers=_h(token)).json() == {"items": []}
        client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "total", "amount": 100}, headers=_h(token),
        )
        items = client.get(f"/api/v1/read/ledgers/{lg}/budgets/usage", headers=_h(token)).json()["items"]
        assert [i["used"] for i in items] == [0.0]
    finally:
        app.dependency_overrides.clear()


def test_budget_for_nonexistent_category_is_accepted():
    # ADVERSE FINDING: category 类型预算不校验 category_id 是否存在 ——
    # 传一个幽灵 id 也能建成功,列表里 category_name 为 null,预算永远 used=0
    # (孤儿预算无 UI 入口清理,只能靠删账本)。
    # 证据: src/snapshot_mutator.py:894-902 create_budget 只查 category_id 非空
    #       与 (type, categoryId) 去重,不查 UserCategoryProjection 存在性。
    # 期望: 400("分类不存在");实际: 200 且 budget 永久孤儿
    client = _make_client()
    try:
        token = _register_and_login(client, "bg-ghost@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        r = client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "category", "amount": 100,
                  "category_id": "cat_does_not_exist"},
            headers=_h(token),
        )
        assert r.status_code == 400, f"幽灵分类预算应被拒绝,实际 {r.status_code}"
        budgets = client.get(f"/api/v1/read/ledgers/{lg}/budgets", headers=_h(token)).json()
        assert budgets == [], f"幽灵分类预算落库了: {budgets}"
    finally:
        app.dependency_overrides.clear()


def test_budget_usage_counts_parent_children_by_sync_id():
    # HARDENING: 父分类预算覆盖子分类支出(sync_id 维度),与 mobile 语义一致。
    client = _make_client()
    try:
        token = _register_and_login(client, "bg-tree@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        client.post(
            f"/api/v1/write/ledgers/{lg}/categories",
            json={"base_change_id": 0, "name": "餐饮", "kind": "expense", "level": 1}, headers=_h(token),
        )
        cats = client.get(f"/api/v1/read/ledgers/{lg}/categories", headers=_h(token)).json()
        parent = next(c for c in cats if c["name"] == "餐饮")
        # 子分类用 push 设置 parentSyncId（web create 只带 parent_name）
        import datetime as _dt
        app_tok = client.post("/api/v1/auth/login", json={
            "email": "bg-tree@t.com", "password": _PW, "device_id": "d-app",
            "client_type": "app", "device_name": "p", "platform": "app"}).json()["access_token"]
        client.post("/api/v1/sync/push", headers={"Authorization": f"Bearer {app_tok}"}, json={
            "device_id": "d-app", "changes": [{
                "ledger_id": lg, "entity_type": "category", "entity_sync_id": "cat-child-1",
                "action": "upsert", "updated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
                "payload": {"syncId": "cat-child-1", "name": "午餐", "kind": "expense",
                            "level": 2, "parentName": "餐饮", "parentSyncId": parent["id"]},
            }]})
        client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "category", "amount": 500, "category_id": parent["id"]},
            headers=_h(token),
        )
        _tx(client, token, lg, amount=30.0, note="child spend", happened_at=_now_iso(),
            category_name="午餐", category_kind="expense", category_id="cat-child-1")
        items = client.get(f"/api/v1/read/ledgers/{lg}/budgets/usage", headers=_h(token)).json()["items"]
        assert [i["used"] for i in items] == [30.0], items
    finally:
        app.dependency_overrides.clear()


def test_budget_usage_exclude_from_budget_flag():
    # HARDENING: exclude_from_budget=True 的交易不计入预算用量(total 与 category 共用)。
    client = _make_client()
    try:
        token = _register_and_login(client, "bg-flag@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "total", "amount": 100}, headers=_h(token),
        )
        _tx(client, token, lg, amount=30.0, note="counted", happened_at=_now_iso())
        _tx(client, token, lg, amount=50.0, note="excluded",
            exclude_from_budget=True, happened_at=_now_iso())
        items = client.get(f"/api/v1/read/ledgers/{lg}/budgets/usage", headers=_h(token)).json()["items"]
        assert [i["used"] for i in items] == [30.0], items
    finally:
        app.dependency_overrides.clear()


def test_budget_survives_category_delete_as_orphan():
    # HARDENING: 分类被删后它的 category 预算留在 projection 里(category_name
    # 变 null),usage 仍返回该 budget 行。孤儿预算不会自动清理但也不会 500。
    client = _make_client()
    try:
        token = _register_and_login(client, "bg-orphan@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        client.post(
            f"/api/v1/write/ledgers/{lg}/categories",
            json={"base_change_id": 0, "name": "临时", "kind": "expense", "level": 1}, headers=_h(token),
        )
        cats = client.get(f"/api/v1/read/ledgers/{lg}/categories", headers=_h(token)).json()
        cid = next(c["id"] for c in cats if c["name"] == "临时")
        client.post(
            f"/api/v1/write/ledgers/{lg}/budgets",
            json={"base_change_id": 0, "type": "category", "amount": 50, "category_id": cid},
            headers=_h(token),
        )
        assert client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/categories/{cid}",
            json={"base_change_id": 0}, headers=_h(token),
        ).status_code == 200

        budgets = client.get(f"/api/v1/read/ledgers/{lg}/budgets", headers=_h(token)).json()
        assert len(budgets) == 1 and budgets[0]["category_name"] is None, budgets
        usage = client.get(f"/api/v1/read/ledgers/{lg}/budgets/usage", headers=_h(token)).json()
        assert len(usage["items"]) == 1
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 统计 / 报表
# ---------------------------------------------------------------------------


def test_analytics_period_validation_month_scope():
    # HARDENING: month scope 的 period 非数字 / 月越界 → 400。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-month@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        for bad in ("2026-13", "0", "abc"):
            r = client.get(
                "/api/v1/read/workspace/analytics",
                params={"scope": "month", "period": bad, "ledger_id": lg}, headers=_h(token),
            )
            assert r.status_code == 400, f"period={bad} → {r.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_analytics_year_scope_out_of_range_period_returns_500():
    # ADVERSE FINDING: scope=year 的 period 只做 int() 转换,**不做范围校验**,
    # 于是 period=0 / -1 / 99999 / 0000 触发 datetime(year, ...) 的
    # "year must be in 1..9999" ValueError → 500 INTERNAL_ERROR。
    # 证据: src/routers/read/_shared.py:647-651(对比 month 分支 :625-626 有
    #       `if month < 1 or month > 12: raise HTTPException(400)`)。
    #       同一 helper 被 /workspace/analytics 与 /ledgers/{id}/member-stats 共用。
    # 期望: 400 Invalid analytics period;实际: 500
    client = _make_client()
    try:
        token = _register_and_login(client, "an-year@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        for bad in ("0", "-1", "99999", "0000"):
            r = client.get(
                "/api/v1/read/workspace/analytics",
                params={"scope": "year", "period": bad, "ledger_id": lg}, headers=_h(token),
            )
            assert r.status_code == 400, f"scope=year period={bad} 应 400,实际 {r.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_member_stats_year_scope_out_of_range_period_returns_500():
    # ADVERSE FINDING: 同上的 helper 复用,让 member-stats 也 500。
    # 证据: src/routers/member_stats.py:83 调 _analytics_range(scope, period, ...)。
    client = _make_client()
    try:
        token = _register_and_login(client, "ms-year@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        for bad in ("0", "9999"):
            r = client.get(
                f"/api/v1/ledgers/{lg}/member-stats",
                params={"scope": "year", "period": bad}, headers=_h(token),
            )
            assert r.status_code == 400, f"member-stats scope=year period={bad} 应 400,实际 {r.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_analytics_month_start_day_boundary_28_february():
    # HARDENING: msd=28 时 2 月周期为 [2/28, 3/28) —— 不撞 2 月无 29-31 日的坑,
    # range 正确返回(截图对照 2026-02)。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-msd28@t.com")
        lg = _ledger(client, token, "M", month_start_day=28).json()["entity_id"]
        r = client.get(
            "/api/v1/read/workspace/analytics",
            params={"scope": "month", "period": "2026-02", "ledger_id": lg}, headers=_h(token),
        )
        assert r.status_code == 200, r.text
        rng = r.json()["range"]
        assert rng["start_at"].startswith("2026-02-28"), rng
    finally:
        app.dependency_overrides.clear()


def test_analytics_empty_ledger_and_single_tx():
    # HARDENING: 空账本 analytics 全 0;单条交易数字正确。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-tiny@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        empty = _analytics(client, token, lg, scope="all")
        assert empty["status"] == 200
        assert empty["body"]["summary"]["transaction_count"] == 0
        assert empty["body"]["series"] == []

        _tx(client, token, lg, amount=42.5)
        one = _analytics(client, token, lg, scope="all")
        assert one["body"]["summary"]["expense_total"] == 42.5
        assert one["body"]["summary"]["transaction_count"] == 1
        assert one["body"]["series"][0]["expense"] == 42.5
    finally:
        app.dependency_overrides.clear()


def test_analytics_exclude_from_stats_flag_combinations():
    # HARDENING: exclude_from_stats=True 不进 analytics;exclude_from_budget=True
    # 仍进 analytics(两者独立),账本 balance 两者都吃(「余额=钱的位置」口径)。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-flags@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        _tx(client, token, lg, amount=10.0, note="normal")
        _tx(client, token, lg, amount=20.0, note="no-stats", exclude_from_stats=True)
        _tx(client, token, lg, amount=30.0, note="no-budget", exclude_from_budget=True)

        agg = _analytics(client, token, lg, scope="all")
        assert agg["body"]["summary"]["expense_total"] == 40.0, agg["body"]["summary"]
        detail = client.get(f"/api/v1/read/ledgers/{lg}", headers=_h(token)).json()
        assert detail["balance"] == -60.0, detail
        assert detail["expense_total"] == 40.0
    finally:
        app.dependency_overrides.clear()


def test_analytics_huge_amounts_aggregate_without_overflow():
    # HARDENING: 大额(1e11,仍在上限内)聚合不抛异常(浮点精度损失可接受)。
    # round-3 中-2 起 web 写路径 |amount| >= 1e12 → 422(与 mobile 对齐),
    # 原 2^53 fixture 改用上限内的最大量级;上限本身的锁见
    # tests/test_round3_functional_fixes.py。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-big@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        _tx(client, token, lg, amount=1e11, note="big")
        agg = _analytics(client, token, lg, scope="all")
        assert agg["status"] == 200
        assert agg["body"]["summary"]["expense_total"] == 1e11
    finally:
        app.dependency_overrides.clear()


def test_analytics_series_balances_are_income_minus_expense():
    # HARDENING: series[].balance == income - expense,summary.balance 同口径。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-bal@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        _tx(client, token, lg, amount=100.0, note="out")
        client.post(
            f"/api/v1/write/ledgers/{lg}/transactions",
            json={"base_change_id": 0, "tx_type": "income", "amount": 250.0,
                  "happened_at": "2026-05-06T12:30:00Z", "note": "in"},
            headers=_h(token),
        )
        agg = _analytics(client, token, lg, scope="all")
        s = agg["body"]["summary"]
        assert s["balance"] == s["income_total"] - s["expense_total"] == 150.0
        assert agg["body"]["series"][0]["balance"] == 150.0
    finally:
        app.dependency_overrides.clear()


def test_analytics_limit_like_params_rejected():
    # HARDENING: 畸形查询参数(负数 / 非数字 limit 等)由 FastAPI 校验成 422。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-badq@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        for params in (
            {"ledger_id": lg, "limit": -1},
            {"ledger_id": lg, "limit": "abc"},
            {"ledger_id": lg, "offset": -1},
            {"ledger_id": lg, "sort_by": "evil"},
            {"ledger_id": lg, "sort_order": "sideways"},
        ):
            r = client.get("/api/v1/read/workspace/transactions", params=params, headers=_h(token))
            assert r.status_code == 422, f"{params} → {r.status_code}"
    finally:
        app.dependency_overrides.clear()


def test_workspace_pagination_and_sort_whitelist():
    # HARDENING: sort_by 白名单外一律 422;正常排序生效。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-sort@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        for amt in (5.0, 50.0, 0.5):
            _tx(client, token, lg, amount=amt, note=str(amt))
        r = client.get(
            "/api/v1/read/workspace/transactions",
            params={"ledger_id": lg, "sort_by": "amount", "sort_order": "asc", "limit": 10},
            headers=_h(token),
        )
        assert r.status_code == 200
        assert [i["amount"] for i in r.json()["items"]] == [0.5, 5.0, 50.0]
    finally:
        app.dependency_overrides.clear()


def test_analytics_tz_offset_out_of_range_rejected():
    # HARDENING: tz_offset_minutes 限制 [-720, 840](UTC-12 .. UTC+14),越界 422。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-tz@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        assert client.get(
            "/api/v1/read/workspace/analytics",
            params={"ledger_id": lg, "tz_offset_minutes": 99999}, headers=_h(token),
        ).status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_net_worth_history_multicurrency_missing_rate():
    # HARDENING: 多币种账户且未设主币种 → net_worth 全 0 且 multi_currency=True
    # (绝不按 1.0 裸加);设了主币种后 CNY 账户计入、USD 账户因缺汇率被剔除。
    client = _make_client()
    try:
        app_tok = _register_and_login(client, "nw-adv@t.com")
        # 需要 app scope 才能 push
        r = client.post("/api/v1/auth/login", json={
            "email": "nw-adv@t.com", "password": _PW, "device_id": "d-app",
            "client_type": "app", "device_name": "p", "platform": "app"})
        app_tok = r.json()["access_token"]
        import datetime as _dt
        now = _dt.datetime.now(_dt.timezone.utc).isoformat()
        client.post("/api/v1/sync/push", headers={"Authorization": f"Bearer {app_tok}"}, json={
            "device_id": "d-app", "changes": [
                {"ledger_id": "lg-nw", "entity_type": "ledger", "entity_sync_id": "lg-nw",
                 "action": "upsert", "updated_at": now,
                 "payload": {"syncId": "lg-nw", "ledgerName": "N", "currency": "CNY"}},
                {"ledger_id": "lg-nw", "entity_type": "account", "entity_sync_id": "acc-cny",
                 "action": "upsert", "updated_at": now,
                 "payload": {"syncId": "acc-cny", "name": "现金", "type": "cash",
                             "currency": "CNY", "initialBalance": 1000}},
                {"ledger_id": "lg-nw", "entity_type": "account", "entity_sync_id": "acc-usd",
                 "action": "upsert", "updated_at": now,
                 "payload": {"syncId": "acc-usd", "name": "USD卡", "type": "cash",
                             "currency": "USD", "initialBalance": 500}},
            ]})

        web_tok = client.post("/api/v1/auth/login", json={
            "email": "nw-adv@t.com", "password": _PW, "device_id": "d-web",
            "client_type": "web", "device_name": "p", "platform": "web"}).json()["access_token"]

        nw = client.get("/api/v1/read/workspace/net-worth-history", headers=_h(web_tok)).json()
        assert nw["multi_currency"] is True
        # 未设主币种 + 缺汇率 → 折算不了 → 净值 0(不裸加)
        assert nw["series"][-1]["net_worth"] == 0.0, nw["series"][-1]

        client.patch("/api/v1/profile/me", json={"primary_currency": "CNY"}, headers=_h(web_tok))
        nw2 = client.get("/api/v1/read/workspace/net-worth-history", headers=_h(web_tok)).json()
        # CNY=1:1 计入 1000;USD 无汇率被剔除
        assert nw2["series"][-1]["net_worth"] == 1000.0, nw2["series"][-1]
    finally:
        app.dependency_overrides.clear()


def test_workspace_ledger_counts_with_future_and_epoch_tx():
    # HARDENING: 1970 交易让 days_since_first_tx 变 2 万天(真实但荒谬),不做 clamp。
    client = _make_client()
    try:
        token = _register_and_login(client, "cnt-epoch@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        _tx(client, token, lg, note="epoch", happened_at="1970-01-01T00:00:00Z")
        r = client.get("/api/v1/read/workspace/ledger-counts", headers=_h(token))
        assert r.status_code == 200
        assert r.json()["days_since_first_tx"] > 20_000
    finally:
        app.dependency_overrides.clear()


def test_analytics_multi_ledger_aggregates_across_ledgers():
    # HARDENING: 多账本 analytics 汇总两个账本;单账本 month_start_day 在多账本
    # 视图下强制自然月(不能对齐各账本周期)。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-multi@t.com")
        lg1 = _ledger(client, token, "A").json()["entity_id"]
        lg2 = _ledger(client, token, "B").json()["entity_id"]
        _tx(client, token, lg1, amount=10.0, note="a")
        _tx(client, token, lg2, amount=20.0, note="b")
        r = client.get("/api/v1/read/workspace/analytics", params={"scope": "all"}, headers=_h(token))
        assert r.status_code == 200
        assert r.json()["summary"]["expense_total"] == 30.0
        assert r.json()["summary"]["transaction_count"] == 2
    finally:
        app.dependency_overrides.clear()


def test_analytics_anomaly_months_requires_three_occurred_months():
    # HARDENING: 已发生月份 < 3 时 anomaly_months 返回空(baseline 不稳)。
    client = _make_client()
    try:
        token = _register_and_login(client, "an-anom@t.com")
        lg = _ledger(client, token).json()["entity_id"]
        for month, amt in (("2026-01", 100.0), ("2026-02", 2000.0)):
            _tx(client, token, lg, amount=amt, note=f"m{month}",
                happened_at=f"{month}-15T12:00:00Z")
        r = client.get(
            "/api/v1/read/workspace/analytics",
            params={"scope": "year", "period": "2026"}, headers=_h(token),
        )
        assert r.status_code == 200
        assert r.json()["anomaly_months"] == []
    finally:
        app.dependency_overrides.clear()


if __name__ == "__main__":
    import pytest
    pytest.main([__file__, "-q"])
