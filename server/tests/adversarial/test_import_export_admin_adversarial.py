"""对抗性测试 —— 导入 / 导出 / 管理员面。

脚手架同 tests/adversarial/test_tx_write_adversarial.py。
``// ADVERSE FINDING:`` = 已确认缺陷(故意失败);``// HARDENING:`` = 断言现状并通过。
"""
from __future__ import annotations

import json
from datetime import datetime, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import AuditLog, User
from src.services.import_data import parse_csv_text
from src.services.import_data.cache import clear_all

_PW = "Pa$$word1!"

_SB_HEADER = (
    "Type,Category,Subcategory,Amount,Currency,Account,From Account,To Account,"
    "Note,Time,Tags,Attachments"
)


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
    clear_all()
    return TestClient(app, raise_server_exceptions=False)


def _register_and_login(client: TestClient, email: str, client_type: str = "web",
                        device: str = "d-web") -> str:
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


def _ledger(client: TestClient, token: str, name: str = "L") -> str:
    r = client.post("/api/v1/write/ledgers", json={"ledger_name": name, "currency": "CNY"},
                    headers=_h(token))
    assert r.status_code == 200, r.text
    return r.json()["entity_id"]


def _tx(client: TestClient, token: str, ledger_id: str, amount=10.0, note="n", **kw):
    return client.post(
        f"/api/v1/write/ledgers/{ledger_id}/transactions",
        json={"base_change_id": 0, "tx_type": "expense", "amount": amount,
              "happened_at": "2026-05-06T12:30:00Z", "note": note, **kw},
        headers=_h(token),
    )


def _export_csv(client: TestClient, token: str, ledger_id: str, **params) -> str:
    r = client.get(
        "/api/v1/read/workspace/transactions.csv",
        params={"ledger_id": ledger_id, **params}, headers=_h(token),
    )
    assert r.status_code == 200, r.text
    return r.content.decode("utf-8")


def _upload(client: TestClient, token: str, ledger_id: str, text: str):
    return client.post(
        "/api/v1/import/upload",
        files={"file": ("t.csv", text.encode("utf-8"), "text/csv")},
        data={"target_ledger_id": ledger_id}, headers=_h(token),
    )


def _execute_sse(client: TestClient, token: str, import_token: str) -> list[dict]:
    events: list[dict] = []
    with client.stream("POST", f"/api/v1/import/{import_token}/execute",
                       headers=_h(token)) as resp:
        buf = resp.read().decode("utf-8")
    for block in buf.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        ev, data = "", ""
        for line in block.split("\n"):
            if line.startswith("event:"):
                ev = line[len("event:"):].strip()
            elif line.startswith("data:"):
                data += line[len("data:"):].strip()
        if ev:
            try:
                events.append({"event": ev, "data": json.loads(data) if data else {}})
            except json.JSONDecodeError:
                events.append({"event": ev, "data": {"raw": data}})
    return events


# ---------------------------------------------------------------------------
# CSV 导出 / 导入往返
# ---------------------------------------------------------------------------


def test_csv_export_bom_and_headers():
    # HARDENING: 导出带 UTF-8 BOM + 12 列表头(zh-CN 本地化)。
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-hdr@t.com")
        lg = _ledger(client, token)
        text = _export_csv(client, token, lg, lang="zh-CN")
        assert text.startswith("\ufeff")
        first = text.lstrip("\ufeff").split("\n")[0]
        assert first == "类型,分类,二级分类,金额,币种,账户,转出账户,转入账户,备注,时间,标签,附件"
    finally:
        app.dependency_overrides.clear()


def test_csv_export_empty_ledger_only_header():
    # HARDENING: 空账本导出只有表头(1 行),不报错。
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-empty@t.com")
        lg = _ledger(client, token)
        text = _export_csv(client, token, lg)
        assert len([l for l in text.splitlines() if l.strip()]) == 1
    finally:
        app.dependency_overrides.clear()


def test_csv_export_escapes_quotes_and_commas():
    # HARDENING: note 里的逗号 / 双引号按 RFC 4180 转义(引号包裹 + "" 加倍)。
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-esc@t.com")
        lg = _ledger(client, token)
        _tx(client, token, lg, note='他说"好吃",还想再来')
        text = _export_csv(client, token, lg, lang="zh-CN")
        assert '"他说""好吃"",还想再来"' in text, text
    finally:
        app.dependency_overrides.clear()


def test_csv_export_does_not_neutralize_formula_injection():
    # ADVERSE FINDING: CSV 公式注入 —— note 以 `=` / `+` / `-` / `@` 开头时
    # 原样导出,Excel / LibreOffice 打开会把该单元格当公式执行(DDE/远程引用
    # 可导致文件泄露或命令执行)。移动端导入他人的 CSV 后 Web 端再导出,
    # 就把攻击载荷带到了用户桌面。
    # 证据: src/routers/read/workspace.py:500-513 直接 _csv_field(note);
    #       src/routers/read/_shared.py:666-675 _csv_field 只处理 RFC 4180
    #       引号/逗号/换行,**不做** =+-@ 前缀转义(无 `'` 前缀或制表符前置)。
    # 期望: 危险前缀被转义(-- 或前置单引号);实际: 原样输出 `=1+1`
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-formula@t.com")
        lg = _ledger(client, token)
        for payload in ("=1+1", "+1+1", "-1+1", "@SUM(1)"):
            _tx(client, token, lg, note=payload)
        text = _export_csv(client, token, lg, lang="en")
        lines = [l for l in text.splitlines() if l.strip()][1:]
        for payload, line in zip(("=1+1", "+1+1", "-1+1", "@SUM(1)"), sorted(lines)):
            cells = line.split(",")
            exported_note = cells[8]
            assert not exported_note.startswith(payload[0]), (
                f"CSV 单元格以危险字符 {payload[0]!r} 开头(Excel 公式注入): {exported_note!r}"
            )
    finally:
        app.dependency_overrides.clear()


def test_csv_export_roundtrip_simple_notes():
    # HARDENING: 普通备注(含中文/%)导出后可被导入器无损解析回同样的 2 行。
    #
    # 断言随 G3 修复调整(原为 `len(txs) == 4`):该断言断言的是「导出→立刻回导
    # 会把账本翻倍」—— 正是 `test_import_dedup_skips_only_decimal_canonical_amounts`
    # 记为缺陷的行为(去重键口径不一致导致 35.50 / 100.00 漏判重)。G3 修好后
    # (两侧统一 Decimal 规范化)默认 skip_duplicates 必须全部判重、总笔数
    # **不变**;两条断言逻辑上互斥,故保留本 HARDENING 的真实意图
    # (「往返可解析」),把重复计数改为「未翻倍 + 全部跳过」。
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-rt@t.com")
        lg = _ledger(client, token)
        _tx(client, token, lg, amount=35.5, note="星巴克")
        _tx(client, token, lg, amount=12.0, note="percent 50%")
        text = _export_csv(client, token, lg)
        r = _upload(client, token, lg, text)
        assert r.status_code == 200, r.text
        assert r.json()["stats"]["total_rows"] == 2
        events = _execute_sse(client, token, r.json()["import_token"])
        complete = next(e for e in events if e["event"] == "complete")
        # 回导不再制造重复(G3):两行都还在,且整批被判重跳过
        assert complete["data"]["created_tx_count"] == 0, complete["data"]
        assert complete["data"]["skipped_count"] == 2, complete["data"]
        txs = client.get(f"/api/v1/read/ledgers/{lg}/transactions", headers=_h(token)).json()
        assert len(txs) == 2, [(t["note"], t["amount"]) for t in txs]
    finally:
        app.dependency_overrides.clear()


def test_csv_export_roundtrip_quote_plus_newline_note_fails_to_import():
    # ADVERSE FINDING: 自己导出的 CSV 在备注同时含「转义双引号 + 换行」时
    # **无法被自己的导入器解析** —— csv.Sniffer 推断出 doublequote=False 的方言,
    # 把一条带换行的行拆成两行,必填列错位 → 整批 0 笔(round-trip 契约破裂)。
    # 证据: src/services/import_data/parser.py:207-220 _parse_csv_rows ——
    #       `csv.Sniffer().sniff(sample, delimiters=",;\t|")` 的 doublequote
    #       推断随内容变化(短样本 True / 长样本 False);未显式传
    #       `doublequote=True` 或 `dialect=csv.excel` 兜底。
    #       导出侧 src/routers/read/_shared.py:666-675 是标准 RFC 4180 转义。
    # 期望: 导出 → 导入往返得到同样数量的交易;实际: 解析出 0 笔 + 2 条
    #       COLUMN_COUNT_MISMATCH 警告,execute 报 PARSE_MISSING_REQUIRED
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-rt2@t.com")
        lg = _ledger(client, token)
        _tx(client, token, lg, amount=12.5, note='note,with"quotes"\nand newline')
        text = _export_csv(client, token, lg)

        data = parse_csv_text(raw_text=text)
        assert len(data.rows) == 1 and not data.parse_warnings, (
            f"导出内容无法被同仓解析器还原: rows={len(data.rows)} "
            f"warnings={[(w.code, w.row_number) for w in data.parse_warnings]}"
        )
    finally:
        app.dependency_overrides.clear()


def test_import_dedup_skips_only_decimal_canonical_amounts():
    # ADVERSE FINDING: 导入去重的 dedup key 用 `f"{Decimal}"` 字符串拼装,与
    # 库内 `f"{float}"` 口径不一致 —— 只有末尾非零小数(如 12.34)能命中,
    # 35.50 / 100.00 这类"整角/整元"金额永远去重失败,重复导入会翻倍。
    # 证据: src/services/import_data/__init__.py(execute 第 501 行)
    #       dedup_key = (tx.tx_type, f"{tx.amount}", tx.happened_at.isoformat())
    #       —— tx.amount 是 Decimal("35.50") → "35.50";
    #       而 src/services/import_data/stats.py:243 build_existing_sets 用
    #       f"{amt}" 拼库内金额(ReadTxProjection.amount 是 Float → "35.5")。
    # 期望: 导出→导入把 35.50/100.00 也判为重复(skipped_dedup=3);
    # 实际: 只跳过 12.34 → skipped_dedup=1,交易数翻倍
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-dedup@t.com")
        lg = _ledger(client, token)
        _tx(client, token, lg, amount=12.34, note="a")
        _tx(client, token, lg, amount=35.5, note="b")
        _tx(client, token, lg, amount=100.0, note="c")
        text = _export_csv(client, token, lg)
        r = _upload(client, token, lg, text)
        assert r.status_code == 200, r.text
        skipped = r.json()["stats"]["skipped_dedup"]
        assert skipped == 3, (
            f"导出后立刻回导应全部判重(skipped_dedup=3),实际 {skipped};"
            f"sample={r.json()['sample_transactions']}"
        )
    finally:
        app.dependency_overrides.clear()


def test_import_in_file_duplicates_skipped_at_execute():
    # HARDENING: 同一文件内的重复行在 execute 阶段按 skip_duplicates 去重
    # (preview 的 skipped_dedup 只看库内,故为 0)。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-infile@t.com")
        lg = _ledger(client, token)
        csv = "类型,金额,时间,分类\n支出,10,2026-05-01,餐饮\n支出,10,2026-05-01,餐饮\n支出,10,2026-05-01,餐饮\n"
        r = _upload(client, token, lg, csv)
        assert r.status_code == 200, r.text
        events = _execute_sse(client, token, r.json()["import_token"])
        complete = next(e for e in events if e["event"] == "complete")
        assert complete["data"]["created_tx_count"] == 1
        assert complete["data"]["skipped_count"] == 2
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 畸形 CSV / 限额
# ---------------------------------------------------------------------------


def test_import_ragged_csv_pads_and_truncates():
    # HARDENING: 列数不齐的行被补空/截断 + COLUMN_COUNT_MISMATCH 警告,不炸。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-ragged@t.com")
        lg = _ledger(client, token)
        csv = "类型,金额,时间,分类\n支出,10,2026-05-01,餐饮\n支出,20\n支出,30,2026-05-02,餐饮,EXTRA,COL\n"
        r = _upload(client, token, lg, csv)
        assert r.status_code == 200, r.text
        assert r.json()["stats"]["total_rows"] == 2, r.json()["stats"]
    finally:
        app.dependency_overrides.clear()


def test_import_binary_garbage_rejected():
    # HARDENING: 非法编码(utf-8/gbk 都失败)→ 400 IMPORT_DECODE_FAILED。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-bin@t.com")
        lg = _ledger(client, token)
        r = client.post(
            "/api/v1/import/upload",
            files={"file": ("b.csv", b"\xff\xfe\x00\x01\x02\x03garbage", "text/csv")},
            data={"target_ledger_id": lg}, headers=_h(token),
        )
        assert r.status_code == 400, r.text
    finally:
        app.dependency_overrides.clear()


def test_import_empty_file_and_header_only():
    # HARDENING: 空文件 400 IMPORT_EMPTY_FILE;只有表头 400 IMPORT_NO_ROWS。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-norow@t.com")
        lg = _ledger(client, token)
        r = client.post(
            "/api/v1/import/upload",
            files={"file": ("e.csv", b"", "text/csv")},
            data={"target_ledger_id": lg}, headers=_h(token),
        )
        assert r.status_code == 400
        r = _upload(client, token, lg, "类型,金额,时间,分类\n")
        assert r.status_code == 400
    finally:
        app.dependency_overrides.clear()


def test_import_row_limit_boundary():
    # HARDENING: 50001 行 → 413 IMPORT_TOO_MANY_ROWS。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-rows@t.com")
        lg = _ledger(client, token)
        body = "类型,金额,时间,分类\n" + "支出,1,2026-05-01,餐饮\n" * 50001
        r = _upload(client, token, lg, body)
        assert r.status_code == 413, r.text
    finally:
        app.dependency_overrides.clear()


def test_import_file_size_limit():
    # HARDENING: > 10MB → 413 IMPORT_FILE_TOO_LARGE。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-size@t.com")
        r = client.post(
            "/api/v1/import/upload",
            files={"file": ("big.csv", b"x" * (11 * 1024 * 1024), "text/csv")},
            headers=_h(token),
        )
        assert r.status_code == 413
    finally:
        app.dependency_overrides.clear()


def test_import_wide_csv_is_accepted():
    # HARDENING: 5000 列的超宽 CSV 被接受(只影响内存,无列数上限)。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-wide@t.com")
        lg = _ledger(client, token)
        header = ",".join(f"c{i}" for i in range(5000))
        row = ",".join("1" for _ in range(5000))
        r = _upload(client, token, lg, header + "\n" + row + "\n")
        assert r.status_code == 200, r.text
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 导入授权 / token 生命周期
# ---------------------------------------------------------------------------


def test_import_token_scoped_to_owner_and_single_use():
    # HARDENING: 他人 preview/cancel token → 410/False;execute 后 token 失效 410。
    client = _make_client()
    try:
        a = _register_and_login(client, "imp-tok-a@t.com", device="d-a")
        b = _register_and_login(client, "imp-tok-b@t.com", device="d-b")
        lg = _ledger(client, a, "A")
        csv = "类型,金额,时间,分类\n支出,10,2026-05-01,餐饮\n"
        r = _upload(client, a, lg, csv)
        import_token = r.json()["import_token"]

        r_cross = client.post(f"/api/v1/import/{import_token}/preview", json={}, headers=_h(b))
        assert r_cross.status_code in (410, 404), r_cross.text
        r_cancel = client.delete(f"/api/v1/import/{import_token}", headers=_h(b))
        assert r_cancel.json()["cancelled"] is False

        _execute_sse(client, a, import_token)
        assert client.post(
            f"/api/v1/import/{import_token}/preview", json={}, headers=_h(a)
        ).status_code == 410
    finally:
        app.dependency_overrides.clear()


def test_import_into_foreign_ledger_denied():
    # HARDENING: 把 target_ledger_id 指向他人账本 → 404 IMPORT_LEDGER_NOT_FOUND。
    client = _make_client()
    try:
        a = _register_and_login(client, "imp-own2@t.com", device="d-a")
        b = _register_and_login(client, "imp-out2@t.com", device="d-b")
        lg_a = _ledger(client, a, "A")
        csv = "类型,金额,时间,分类\n支出,10,2026-05-01,餐饮\n"
        r = _upload(client, b, lg_a, csv)
        assert r.status_code == 404, r.text
    finally:
        app.dependency_overrides.clear()


def test_import_tz_offset_out_of_range_is_silently_ignored():
    # HARDENING: tz_offset_minutes 无范围校验,超大地偏移被 timezone() 拒绝 →
    # _localize_naive 内 ValueError → 该行 PARSE_INVALID_FIELD(tz 校验缺位,
    # 但不至于 500)。
    client = _make_client()
    try:
        token = _register_and_login(client, "imp-tz@t.com")
        lg = _ledger(client, token)
        csv = "类型,金额,时间,分类\n支出,10,2026-05-01,餐饮\n"
        r = client.post(
            "/api/v1/import/upload",
            files={"file": ("t.csv", csv.encode("utf-8"), "text/csv")},
            data={"target_ledger_id": lg, "tz_offset_minutes": "99999999999"},
            headers=_h(token),
        )
        assert r.status_code == 200, r.text
        events = _execute_sse(client, token, r.json()["import_token"])
        err = next((e for e in events if e["event"] == "error"), None)
        assert err is not None, "超大 tz 应导致该行解析失败而不是静默按 UTC 记账"
    finally:
        app.dependency_overrides.clear()


def test_csv_export_huge_tz_offset_returns_500():
    # ADVERSE FINDING: /workspace/transactions.csv 的 tz_offset_minutes **无范围
    # 校验**(对比 analytics / budget-usage / net-worth 都有 ge=-720/le=840),
    # 超大值让 timedelta(minutes=...) 溢出/越界 → 500。
    # 证据: src/routers/read/workspace.py:322-325 tz_offset_minutes 是裸 int
    #       (无 Query(ge=, le=));:458 `tz_delta = timedelta(minutes=...)`;
    #       :470 `local_dt = _to_utc(tx.happened_at) + tz_delta` → OverflowError。
    # 期望: 422(参数越界);实际: 500(仅当账本有交易时才走到该行)
    client = _make_client()
    try:
        token = _register_and_login(client, "csv-tz@t.com")
        lg = _ledger(client, token)
        _tx(client, token, lg)
        r = client.get(
            "/api/v1/read/workspace/transactions.csv",
            params={"ledger_id": lg, "tz_offset_minutes": 99999999999}, headers=_h(token),
        )
        assert r.status_code == 422, f"越界 tz 应 422,实际 {r.status_code}"
    finally:
        app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# 管理员
# ---------------------------------------------------------------------------


def _make_admin(client: TestClient, email: str, device: str = "d-a") -> str:
    token = _register_and_login(client, email, device=device)
    db = next(app.dependency_overrides[get_db]())
    u = db.scalar(select(User).where(User.email == email))
    u.is_admin = True
    db.commit()
    uid = u.id
    db.close()
    return token, uid


def test_non_admin_endpoints_are_forbidden():
    # HARDENING: 普通用户调 admin 端点 403(users/overview/创建用户);
    # /admin/devices 对非 admin 退化为"只看自己",不泄露他人。
    client = _make_client()
    try:
        plain = _register_and_login(client, "adm-plain@t.com")
        for path in ("/api/v1/admin/users", "/api/v1/admin/overview",
                     "/api/v1/admin/data-cleanup/scan", "/api/v1/admin/logs"):
            r = client.get(path, headers=_h(plain))
            assert r.status_code == 403, f"{path} → {r.status_code}"
        assert client.post(
            "/api/v1/admin/users", json={"email": "x@t.com", "password": "123456"},
            headers=_h(plain),
        ).status_code == 403
    finally:
        app.dependency_overrides.clear()


def test_admin_cannot_self_delete_or_disable():
    # HARDENING: admin 自删 400 / 自禁用 400(防止锁死控制台)。
    client = _make_client()
    try:
        token, uid = _make_admin(client, "adm-self@t.com")
        assert client.delete(f"/api/v1/admin/users/{uid}", headers=_h(token)).status_code == 400
        assert client.patch(
            f"/api/v1/admin/users/{uid}", json={"is_enabled": False}, headers=_h(token)
        ).status_code == 400
    finally:
        app.dependency_overrides.clear()


def test_admin_create_user_always_non_admin():
    # HARDENING: 即使 body 传 is_admin=True,服务端硬锁 is_admin=False
    # (单租户单管理员约束),并在 audit 里记 requestedIsAdmin。
    client = _make_client()
    try:
        token, _ = _make_admin(client, "adm-create@t.com")
        r = client.post(
            "/api/v1/admin/users",
            json={"email": "wannabe@t.com", "password": "123456", "is_admin": True},
            headers=_h(token),
        )
        assert r.status_code == 201
        assert r.json()["is_admin"] is False

        db = next(app.dependency_overrides[get_db]())
        log = db.scalars(
            select(AuditLog).where(AuditLog.action == "admin_user_create")
        ).first()
        assert log is not None and log.metadata_json.get("requestedIsAdmin") is True
        db.close()
    finally:
        app.dependency_overrides.clear()


def test_admin_patch_ignores_is_admin_escalation():
    # HARDENING: PATCH 里带 is_admin 被 schema 忽略(不在 UserAdminPatchRequest),
    # 目标用户不会被提权。
    client = _make_client()
    try:
        token, _ = _make_admin(client, "adm-esc@t.com")
        _register_and_login(client, "esc-target@t.com", device="d-t")
        db = next(app.dependency_overrides[get_db]())
        target_id = db.scalar(select(User.id).where(User.email == "esc-target@t.com"))
        db.close()

        r = client.patch(
            f"/api/v1/admin/users/{target_id}",
            json={"email": "esc2@t.com", "is_admin": True}, headers=_h(token),
        )
        assert r.status_code == 200
        assert r.json()["is_admin"] is False
        db = next(app.dependency_overrides[get_db]())
        assert db.scalar(select(User.is_admin).where(User.id == target_id)) is False
        db.close()
    finally:
        app.dependency_overrides.clear()


def test_admin_change_password_requires_own_password():
    # HARDENING: 改他人密码需要 admin 自己当前密码(二次验证),错密码 401;
    # 目标不存在 404。
    client = _make_client()
    try:
        token, _ = _make_admin(client, "adm-pw@t.com")
        _register_and_login(client, "pw-target@t.com", device="d-t")
        db = next(app.dependency_overrides[get_db]())
        target_id = db.scalar(select(User.id).where(User.email == "pw-target@t.com"))
        db.close()

        assert client.post(
            f"/api/v1/admin/users/{target_id}/password",
            json={"admin_password": "wrong-pass", "new_password": "abcdef"},
            headers=_h(token),
        ).status_code == 401
        assert client.post(
            "/api/v1/admin/users/no-such-id/password",
            json={"admin_password": _PW, "new_password": "abcdef"}, headers=_h(token),
        ).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_admin_list_pagination_edges():
    # HARDENING: limit=0/-5/100000/非数字、offset=-1 全部 422(边界值由 schema
    # 守住);offset 远超总数返回空 items 但 total 正确。
    client = _make_client()
    try:
        token, _ = _make_admin(client, "adm-page@t.com")
        for q in ("limit=0", "limit=-5", "limit=100000", "offset=-1", "limit=abc"):
            r = client.get(f"/api/v1/admin/users?{q}", headers=_h(token))
            assert r.status_code == 422, f"{q} → {r.status_code}"
        r = client.get("/api/v1/admin/users?status=all&offset=10000", headers=_h(token))
        assert r.status_code == 200
        assert r.json()["items"] == [] and r.json()["total"] >= 1
    finally:
        app.dependency_overrides.clear()


def test_admin_audit_log_written_once_per_real_change():
    # HARDENING: 真实变更写 1 条 admin_user_patch;no-op(同值)PATCH 不写
    # (避免噪音),但**也返回 200**。
    client = _make_client()
    try:
        token, admin_id = _make_admin(client, "adm-audit@t.com")
        _register_and_login(client, "audit-target@t.com", device="d-t")
        db = next(app.dependency_overrides[get_db]())
        target_id = db.scalar(select(User.id).where(User.email == "audit-target@t.com"))
        db.close()

        client.patch(f"/api/v1/admin/users/{target_id}", json={"is_enabled": False},
                     headers=_h(token))
        client.patch(f"/api/v1/admin/users/{target_id}", json={"is_enabled": False},
                     headers=_h(token))
        client.patch(f"/api/v1/admin/users/{target_id}", json={"email": "audit-target@t.com"},
                     headers=_h(token))

        db = next(app.dependency_overrides[get_db]())
        logs = db.scalars(
            select(AuditLog).where(AuditLog.action == "admin_user_patch")
        ).all()
        db.close()
        assert len(logs) == 1, [l.metadata_json for l in logs]
        assert logs[0].user_id == admin_id
        assert logs[0].metadata_json["targetUserId"] == target_id
    finally:
        app.dependency_overrides.clear()


def test_admin_soft_delete_user_revokes_access():
    # HARDENING: 软删用户 → is_enabled=False + is_admin=False;该用户后续请求 403
    # (User disabled),登录也 403。
    client = _make_client()
    try:
        token, _ = _make_admin(client, "adm-del@t.com")
        victim = _register_and_login(client, "victim@t.com", device="d-v")
        db = next(app.dependency_overrides[get_db]())
        victim_id = db.scalar(select(User.id).where(User.email == "victim@t.com"))
        db.close()

        r = client.delete(f"/api/v1/admin/users/{victim_id}", headers=_h(token))
        assert r.status_code == 200
        assert r.json()["is_enabled"] is False and r.json()["is_admin"] is False

        assert client.get("/api/v1/read/ledgers", headers=_h(victim)).status_code == 403
        assert client.post("/api/v1/auth/login", json={
            "email": "victim@t.com", "password": _PW, "client_type": "web",
            "device_name": "p", "platform": "web",
        }).status_code == 403
    finally:
        app.dependency_overrides.clear()


def test_admin_cannot_delete_admin_user():
    # HARDENING: 删除另一个 admin 账号 → 400(admin 不能被删/禁用)。
    client = _make_client()
    try:
        token_a, _ = _make_admin(client, "adm-a2@t.com", device="d-a")
        _, b_id = _make_admin(client, "adm-b2@t.com", device="d-b")
        r = client.delete(f"/api/v1/admin/users/{b_id}", headers=_h(token_a))
        assert r.status_code == 400, r.text
    finally:
        app.dependency_overrides.clear()


def test_admin_overview_counts_include_trashed_transactions():
    # ADVERSE FINDING: /admin/overview 的 transactions_total 直接 COUNT
    # read_tx_projection,**不过滤软删**,与它自己注释宣称的"projection 是
    # hard-deleted 的权威源,COUNT(*) 就干净正确"相反 —— 回收站里的交易
    # 仍被计入总量,admin 面板数字虚高(purge 之后才下降)。
    # 证据: src/routers/admin.py:497-499 `func.count().select_from(ReadTxProjection)`
    #       无 `deleted_at.is_(None)`;对比 src/routers/read/ledgers.py:155 同款
    #       COUNT 也是漏过滤(见 test_ledger_stats_counts_trashed_rows)。
    # 期望: 删除 1 笔后 transactions_total 由 2 变 1;
    # 实际: 仍是 2(回收站行被计入),purge 后才变 1
    client = _make_client()
    try:
        token, _ = _make_admin(client, "adm-ov@t.com")
        lg = _ledger(client, token, "O")
        ids = [_tx(client, token, lg, note=f"t{i}").json()["entity_id"] for i in range(2)]
        assert client.get("/api/v1/admin/overview", headers=_h(token)).json()["transactions_total"] == 2

        client.request(
            "DELETE", f"/api/v1/write/ledgers/{lg}/transactions/{ids[0]}",
            json={"base_change_id": 0}, headers=_h(token),
        )
        after_trash = client.get("/api/v1/admin/overview", headers=_h(token)).json()["transactions_total"]
        assert after_trash == 1, f"回收站行仍被 admin overview 计入(transactions_total={after_trash})"
    finally:
        app.dependency_overrides.clear()


if __name__ == "__main__":
    import pytest
    pytest.main([__file__, "-q"])
