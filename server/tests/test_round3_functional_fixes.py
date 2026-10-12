"""round-3 功能审查缺陷回归(2026-10-11)—— 5 个缺陷的护栏测试。

每个用例对应一个经公开 HTTP API / 单元复现确认、本轮修复的缺陷;
docstring 记录修复前的红。

- **D1 (P2)**:CSV 导出→导入 round-trip 改写备注。导出侧 `_csv_field` 对
  `=+-@\t\r` 起始单元格前置 `'`(公式注入中和),导入侧(transformer 的
  `opt()`)不剥 → "-5 received from Alice" 往返成 "'-5 received..."。
- **D2 (P2)**:`PATCH /profile/me` 不带 providers 段时,存量超限 ai_config
  合并结果(≤ 存量字节数)被 422 `AI_CONFIG_TOO_LARGE` —— 缩容豁免
  (`stored_bytes`)只接进了 `/ai/providers`,没接 profile 路径;移动端
  `snapshotForSync()` 恰好就是「不带 providers」的调用形态。
- **D3 (低)**:push 的五个新拒绝分支(`ledger_deleted` / `membership_revoked`
  / `unknown_ledger` / `sync_id_mismatch` / `entity_sync_id_too_long`)只加
  `failed_samples` 不加 `failed_count` → 客户端对账桶错位。
- **D4 (低)**:`entity_sync_id_too_long` 的 sample 把 `entitySyncId` 截到
  255 字符,客户端拿全长本地 syncId 比对永不命中 → 整批 markPushed 保护
  生效,健康同批 change 永远重推。
- **D5 (中-2)**:web / CSV 导入放行 `amount >= 1e12`,mobile pull 守卫
  (`exceeds_magnitude`)把该行永远跳过 → web 有、手机无的静默分叉。
  现源头收窄(create / batch / import);sync push 刻意不动。

可用 `python -m pytest tests/test_round3_functional_fixes.py -q` 单跑。
"""
from __future__ import annotations

import json
import os

os.environ.setdefault("REGISTRATION_ENABLED", "true")

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import UserProfile
from src.routers.read._shared import _csv_field
from src.services.import_data import apply_mapping, parse_csv_text

_PW = "Pa$$word1!"


def _make_client() -> tuple[TestClient, sessionmaker]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    def override_get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app), Session


def _register(client: TestClient, email: str, *, client_type: str = "web",
              device_id: str | None = None) -> dict:
    payload = {
        "email": email,
        "password": _PW,
        "client_type": client_type,
        "device_name": f"pytest-{email}",
        "platform": "test",
    }
    if device_id:
        payload["device_id"] = device_id
    res = client.post("/api/v1/auth/register", json=payload)
    assert res.status_code == 200, res.text
    body = res.json()
    body["device_id"] = device_id or body.get("device_id", "")
    return body


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _iso(dt=None) -> str:
    return (dt or datetime.now(timezone.utc)).isoformat()


# ══════════════════════════════════════════════════════════════════════
# D1 —— CSV round-trip 的公式中和 `'` 必须在导入侧剥掉
# ══════════════════════════════════════════════════════════════════════


def _provider(pid: str, *, api_key: str = "") -> dict:
    return {
        "id": pid,
        "name": f"P-{pid}",
        "isBuiltIn": False,
        "apiKey": api_key,
        "baseUrl": "https://api.example.com/v1",
        "textModel": "m",
        "visionModel": "m",
        "audioModel": "m",
        "protocol": "openai",
        "visionConcurrency": 3,
    }


@pytest.mark.parametrize("note", [
    "-5 received from Alice",   # `-` 触发(最常见的金额上下文备注)
    "=cmd|'/C calc'!A0",        # `=` 触发(DDE 串,导出侧必须中和)
    "+100 bonus",               # `+`
    "@mention from bob",        # `@`
])
def test_csv_export_import_roundtrip_preserves_formula_prefixed_note(note: str):
    """D1:导出单元格 → 再导入,note 必须与原值逐字一致。

    修复前:导入侧不剥导出加的 `'`,note 变成 `"'` + 原值(数据被改写)。
    """
    exported_cell = _csv_field(note)
    assert exported_cell.startswith("'"), "fixture 须命中导出侧中和分支"
    csv = (
        "类型,金额,时间,分类,备注\n"
        f"支出,35.00,2024-05-01 12:30,餐饮,{exported_cell}\n"
    )
    data = parse_csv_text(raw_text=csv)
    txs, errors, _ = apply_mapping(rows=data.rows, mapping=data.suggested_mapping)
    assert errors == []
    assert len(txs) == 1
    assert txs[0].note == note, f"round-trip mangled: {txs[0].note!r} != {note!r}"


def test_csv_import_standalone_quote_not_stripped():
    """D1 边界:用户**本来**以 `'` 开头且第二字符不在触发集的备注,原样保留
    (un-escaping 只剥导出语义的那一个前缀,不做无差别剥 `'`)。"""
    csv = "类型,金额,时间,分类,备注\n支出,35.00,2024-05-01 12:30,餐饮,'quoted\n"
    data = parse_csv_text(raw_text=csv)
    txs, errors, _ = apply_mapping(rows=data.rows, mapping=data.suggested_mapping)
    assert errors == []
    assert txs[0].note == "'quoted"


def test_csv_import_roundtrip_category_and_account_names():
    """D1:其它自由文本列(分类 / 账户)同样剥前缀 —— 分类名 "-餐饮" 在
    web 导出里会被中和,再导入必须还原。"""
    csv = (
        "类型,金额,时间,分类,账户,备注\n"
        f"支出,35.00,2024-05-01 12:30,{_csv_field('-餐饮')},{_csv_field('@招行')},{_csv_field('=note')}\n"
    )
    data = parse_csv_text(raw_text=csv)
    txs, errors, _ = apply_mapping(rows=data.rows, mapping=data.suggested_mapping)
    assert errors == []
    assert txs[0].category_name == "-餐饮"
    assert txs[0].account_name == "@招行"
    assert txs[0].note == "=note"


def test_csv_export_import_roundtrip_via_http():
    """D1 端到端:web 建 tx(`-` 开头备注)→ CSV 导出 → 再 parse+apply,
    note 一致(不出现可见的 `'`)。"""
    client, _TS = _make_client()
    try:
        auth = _register(client, "d1-http@t.com")
        headers = {**_auth(auth["access_token"]), "X-Device-ID": "dev-web"}
        r = client.post("/api/v1/write/ledgers",
                        json={"ledger_name": "L", "currency": "CNY"}, headers=headers)
        ledger_id = r.json()["entity_id"]
        note = "-5 received from Alice"
        r = client.post(f"/api/v1/write/ledgers/{ledger_id}/transactions", headers=headers, json={
            "base_change_id": 0, "tx_type": "expense", "amount": 5,
            "happened_at": _iso(), "note": note, "category_name": "餐饮",
        })
        assert r.status_code == 200, r.text

        r = client.get(
            f"/api/v1/read/workspace/transactions.csv",
            headers=headers, params={"ledger_id": ledger_id, "lang": "zh-CN"},
        )
        assert r.status_code == 200, r.text
        body = r.text
        assert "\ufeff" in body  # BOM
        data = parse_csv_text(raw_text=body)
        txs, errors, _ = apply_mapping(rows=data.rows, mapping=data.suggested_mapping)
        assert errors == []
        assert len(txs) == 1
        assert txs[0].note == note, f"HTTP round-trip mangled: {txs[0].note!r}"
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# D2 —— PATCH /profile/me 的缩容豁免接线
# ══════════════════════════════════════════════════════════════════════


def _over_limit_cfg(n: int = 24) -> dict:
    """n 个 CJK 满配 provider —— 序列化后 ≈300 KB,超 256 KB 上限
    (与 test_cross_review_defects_2026_10_11 的 fixture 同构)。"""
    big = "密" * 4096
    return {"providers": [_provider(f"p{i}", api_key=big) for i in range(n)],
            "binding": {}, "customPromptTemplate": "old-template"}


def test_profile_patch_prefs_only_passes_on_over_limit_config():
    """D2 端到端:存量超限 ai_config + 只带 prefs(不带 providers,移动端
    `snapshotForSync()` 的真实形态)的 PATCH → 200;等价/更小的合并结果
    靠 `stored_bytes` 豁免放行。

    修复前:profile 路径没接豁免 → 422 `AI_CONFIG_TOO_LARGE`,超限用户的
    app 端 AI 偏好永远同步不上来。
    """
    client, Session = _make_client()
    try:
        auth = _register(client, "d2-prefs@t.com", client_type="app", device_id="dev-d2")
        headers = _auth(auth["access_token"])
        stored = json.dumps(_over_limit_cfg(), ensure_ascii=False, sort_keys=True)
        assert len(stored.encode("utf-8")) > 262144
        with Session() as db:
            db.add(UserProfile(user_id=auth["user"]["id"],
                               ai_config_json=stored, ai_config_version=1))
            db.commit()

        # prefs-only(替换等长偏短模板 → 合并结果 ≤ 存量)→ 200
        res = client.patch("/api/v1/profile/me", headers=headers,
                           json={"ai_config": {"customPromptTemplate": "t"}})
        assert res.status_code == 200, f"修复前 422: {res.status_code} {res.text[:200]}"
        # providers 段整体保留(merge 语义没被本次修复改变)
        with Session() as db:
            row = db.scalar(select(UserProfile).where(
                UserProfile.user_id == auth["user"]["id"]))
            cfg = json.loads(row.ai_config_json)
            assert len(cfg["providers"]) == 24
    finally:
        app.dependency_overrides.clear()


def test_profile_patch_growing_write_still_422():
    """D2 边界:豁免只覆盖「不比存量更大」;真增长(把 prefs 换成巨串)→
    仍 422,豁免不能变成「超限账户随便写」的后门。"""
    client, Session = _make_client()
    try:
        auth = _register(client, "d2-grow@t.com")
        headers = _auth(auth["access_token"])
        stored = json.dumps(_over_limit_cfg(), ensure_ascii=False, sort_keys=True)
        with Session() as db:
            db.add(UserProfile(user_id=auth["user"]["id"],
                               ai_config_json=stored, ai_config_version=1))
            db.commit()

        res = client.patch("/api/v1/profile/me", headers=headers,
                           json={"ai_config": {"customPromptTemplate": "x" * 5000}})
        assert res.status_code == 422, (
            f"增长写入必须仍被拒: {res.status_code} {res.text[:200]}"
        )
        assert res.json().get("error", {}).get("code") == "VALIDATION_ERROR"
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# D3 + D4 —— push 拒绝分支的 failed_count / 完整 sample
# ══════════════════════════════════════════════════════════════════════


def _push(client: TestClient, headers: dict, device: str, changes: list[dict]) -> dict:
    r = client.post("/api/v1/sync/push", headers=headers,
                    json={"device_id": device, "changes": changes})
    assert r.status_code == 200, r.text
    return r.json()


def _change(entity_type: str, sync_id: str, payload: dict, *, action: str = "upsert",
            ledger_id: str | None = None, updated_at: str | None = None) -> dict:
    body = {
        "entity_type": entity_type,
        "entity_sync_id": sync_id,
        "action": action,
        "updated_at": updated_at or _iso(),
        "payload": payload,
    }
    if ledger_id is not None:
        body["ledger_id"] = ledger_id
    return body


def test_push_entity_sync_id_too_long_counts_failed_and_keeps_full_sample():
    """D3+D4:超长 entity_sync_id 的拒绝分支必须 `failed_count=1`,且
    sample 里的 `entitySyncId` 是**完整**值(客户端比对依赖全长)。

    修复前:`failed_count=0`(只有 rejected=1)+ sample 截到 255 字符。
    """
    client, _TS = _make_client()
    try:
        auth = _register(client, "d34@t.com", client_type="app", device_id="dev-d34")
        headers = _auth(auth["access_token"])
        long_id = "tx-" + "x" * 400
        resp = _push(client, headers, "dev-d34", [
            _change("transaction", long_id, {
                "syncId": long_id, "type": "expense", "amount": 1,
                "happenedAt": _iso()}, ledger_id="L01"),
        ])
        assert resp["rejected"] == 1
        assert resp["failed_count"] == 1, (
            f"D3 修复前: failed_count={resp['failed_count']}"
        )
        assert resp["conflict_count"] == 0
        sample = resp["failed_samples"][0]
        assert sample["reason"] == "entity_sync_id_too_long"
        assert sample["entitySyncId"] == long_id, (
            f"D4 修复前 sample 被截断: len={len(sample['entitySyncId'])}"
        )
        assert sample["maxLength"] == 255
    finally:
        app.dependency_overrides.clear()


def test_push_sync_id_mismatch_counts_failed():
    """D3:sync_id_mismatch 分支同样计入 failed_count。"""
    client, _TS = _make_client()
    try:
        auth = _register(client, "d3-mis@t.com", client_type="app", device_id="dev-mis")
        headers = _auth(auth["access_token"])
        resp = _push(client, headers, "dev-mis", [
            _change("transaction", "tx-a", {
                "syncId": "tx-b", "type": "expense", "amount": 1,
                "happenedAt": _iso()}, ledger_id="L01"),
        ])
        assert resp["rejected"] == 1
        assert resp["failed_count"] == 1, resp
        assert resp["failed_samples"][0]["reason"] == "sync_id_mismatch"
        assert resp["failed_samples"][0]["payloadSyncId"] == "tx-b"
    finally:
        app.dependency_overrides.clear()


def test_push_rejected_branches_keep_client_reconciliation_consistent():
    """D3(语义):客户端对账公式 `reported = max(conflict+failed, rejected)`
    在被拒分支上必须两侧一致 —— 即每条 rejected 的 failed/conflict 样本
    分支都要把计数加上,不能出现 rejected=1 而 conflict+failed=0 的
    「unclassified」形态(会落进客户端的 conflict 桶)。

    这里用 ledger_deleted 分支走全链路:建账本 → push 建 tx → 删账本 →
    再推。membership_revoked / unknown_ledger 分支由既有
    test_p1_sync_router_fixes 覆盖 reason 样本,本用例补计数断言口径。
    """
    client, Session = _make_client()
    try:
        auth = _register(client, "d3-ld@t.com")
        headers = {**_auth(auth["access_token"]), "X-Device-ID": "dev-ld"}
        r = client.post("/api/v1/write/ledgers",
                        json={"ledger_id": "del-ledger", "ledger_name": "L",
                              "currency": "CNY"}, headers=headers)
        assert r.status_code == 200, r.text

        app_auth = client.post("/api/v1/auth/login", json={
            "email": "d3-ld@t.com", "password": _PW, "client_type": "app",
            "device_id": "dev-ld", "device_name": "t", "platform": "t"})
        app_token = app_auth.json()["access_token"]

        # 删除账本(软删)
        r = client.delete("/api/v1/write/ledgers/del-ledger", headers=headers)
        assert r.status_code == 200, r.text

        # app 端未感知删除,继续推 → ledger_deleted 分支
        base = datetime.now(timezone.utc)
        resp = _push(client, _auth(app_token), "dev-ld", [
            _change("transaction", "tx-z", {
                "syncId": "tx-z", "type": "expense", "amount": 1,
                "happenedAt": _iso(base)}, ledger_id="del-ledger"),
        ])
        assert resp["rejected"] == 1, resp
        reported = resp["conflict_count"] + resp["failed_count"]
        assert reported >= 1, (
            f"D3: rejected={resp['rejected']} 但 conflict+failed={reported} —— "
            "被拒 change 落进客户端的 unclassified/conflict 桶"
        )
        reasons = [s["reason"] for s in resp["failed_samples"]]
        assert reasons, "应有可诊断的 failed sample"
    finally:
        app.dependency_overrides.clear()


# ══════════════════════════════════════════════════════════════════════
# D5 —— web / 导入路径的金额数量级封顶(sync push 刻意不动)
# ══════════════════════════════════════════════════════════════════════


def test_web_tx_create_amount_cap():
    """D5:web 单笔 create `amount=1e12` → 422;`999999999999` → 200
    (边界与 mobile `maxWriteAmount` 完全一致)。"""
    client, _TS = _make_client()
    try:
        auth = _register(client, "d5-web@t.com")
        headers = {**_auth(auth["access_token"]), "X-Device-ID": "dev-web"}
        r = client.post("/api/v1/write/ledgers",
                        json={"ledger_name": "L5", "currency": "CNY"}, headers=headers)
        ledger_id = r.json()["entity_id"]

        res = client.post(f"/api/v1/write/ledgers/{ledger_id}/transactions",
                          headers=headers, json={
            "base_change_id": 0, "tx_type": "expense", "amount": 1e12,
            "happened_at": _iso(), "note": "cap",
        })
        assert res.status_code == 422, (
            f"D5 修复前: 1e12 被接受({res.status_code}),mobile pull 会永远跳过该行"
        )

        res = client.post(f"/api/v1/write/ledgers/{ledger_id}/transactions",
                          headers=headers, json={
            "base_change_id": 0, "tx_type": "expense", "amount": 999999999999,
            "happened_at": _iso(), "note": "max-ok",
        })
        assert res.status_code == 200, res.text

        # 负向冲正同样受限(|amount| 口径)
        res = client.post(f"/api/v1/write/ledgers/{ledger_id}/transactions",
                          headers=headers, json={
            "base_change_id": 0, "tx_type": "expense", "amount": -1e12,
            "happened_at": _iso(),
        })
        assert res.status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_web_tx_batch_amount_cap():
    """D5:batch(贴图/贴文记账通道)`amount=5e12` → 422。"""
    client, _TS = _make_client()
    try:
        auth = _register(client, "d5-batch@t.com")
        headers = {**_auth(auth["access_token"]), "X-Device-ID": "dev-web"}
        r = client.post("/api/v1/write/ledgers",
                        json={"ledger_name": "L5", "currency": "CNY"}, headers=headers)
        ledger_id = r.json()["entity_id"]

        res = client.post(f"/api/v1/write/ledgers/{ledger_id}/transactions/batch",
                          headers=headers, json={
            "transactions": [{"tx_type": "expense", "amount": 5e12,
                              "happened_at": _iso()}],
        })
        assert res.status_code == 422, (
            f"D5 修复前: batch 5e12 被接受({res.status_code})"
        )
    finally:
        app.dependency_overrides.clear()


def test_import_amount_over_cap_rejected_per_row():
    """D5:CSV 导入行 amount=5e12 → 行级错误(报告可见),同文件合法行照常
    通过(选 reject 而非 clamp:静默改金额比拒一行更糟)。"""
    csv = (
        "类型,金额,时间,分类\n"
        "支出,5000000000000,2024-05-01 12:30,餐饮\n"
        "支出,35,2024-05-01 12:31,餐饮\n"
    )
    data = parse_csv_text(raw_text=csv)
    txs, errors, _ = apply_mapping(rows=data.rows, mapping=data.suggested_mapping)
    assert len(txs) == 1
    assert len(errors) == 1
    assert errors[0].code == "PARSE_AMOUNT_EXCEEDS_MAGNITUDE"
    assert errors[0].row_number == 2  # 指向 CSV 里的具体行
    assert errors[0].field_name == "amount"
    # 边界内最大值通过
    assert txs[0].amount is not None


def test_import_amount_at_max_boundary_accepted():
    """D5 边界:999999999999(< 1e12)导入通过,与 mobile 一致。"""
    csv = "类型,金额,时间,分类\n支出,999999999999,2024-05-01 12:30,餐饮\n"
    data = parse_csv_text(raw_text=csv)
    txs, errors, _ = apply_mapping(rows=data.rows, mapping=data.suggested_mapping)
    assert errors == []
    assert len(txs) == 1


def test_sync_push_huge_amount_still_accepted():
    """D5(刻意不收窄面):sync push 的 amount=5e12 必须仍被接受 —— 存量
    mobile 行 >1e12 要继续同步,web 侧封顶后 mobile pull 守卫(`exceeds_
    magnitude`)仍是唯一兜底,不双重拒绝造成 mobile 数据永远推不上来。"""
    client, _TS = _make_client()
    try:
        auth = _register(client, "d5-sync@t.com", client_type="app", device_id="dev-d5s")
        headers = _auth(auth["access_token"])
        resp = _push(client, headers, "dev-d5s", [
            _change("transaction", "tx-big", {
                "syncId": "tx-big", "type": "expense", "amount": 5e12,
                "happenedAt": _iso()}, ledger_id="L01"),
        ])
        assert resp["accepted"] == 1, resp
    finally:
        app.dependency_overrides.clear()
