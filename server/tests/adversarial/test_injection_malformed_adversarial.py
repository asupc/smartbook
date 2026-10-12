"""注入与畸形输入对抗测试 —— SQL 注入串、XSS/路径穿越、空字节、超长字段、
分页边界、JSON 结构畸形、数值边界、CSV 公式注入、HTTP header 边界。

标注约定:
  ADVERSE FINDING  —— 真实缺陷(测试保持失败)
  HARDENING        —— 行为可辩护但脆弱(断言当前行为并通过)
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app

PASSWORD = "Pa$$word1!"
SQLI = "Robert'); DROP TABLE users;--"
XSS = "<script>alert('xss')</script>"


def _make_client() -> tuple[TestClient, sessionmaker]:
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
    return TestClient(app, raise_server_exceptions=False), TS


@pytest.fixture()
def client():
    c, TS = _make_client()
    yield c, TS
    app.dependency_overrides.clear()


def _register(client, email: str, client_type: str = "web", device_id: str = "d1") -> dict:
    res = client.post(
        "/api/v1/auth/register",
        json={"email": email, "password": PASSWORD, "client_type": client_type,
              "device_id": device_id, "device_name": "pytest", "platform": "test"},
    )
    assert res.status_code == 200, res.text
    return res.json()


def _auth(tok: str, device: str = "d1") -> dict:
    return {"Authorization": f"Bearer {tok}", "X-Device-ID": device}


def _ledger(client, tok: str, ext: str = "MJ-L", device: str = "d1") -> str:
    res = client.post(
        "/api/v1/write/ledgers",
        headers=_auth(tok, device),
        json={"ledger_id": ext, "ledger_name": "MJ", "currency": "CNY"},
    )
    assert res.status_code == 200, res.text
    return res.json()["entity_id"]


def _tx(client, tok, ledger, *, note=None, amount=1.0, device="d1", happened_at="2026-05-06T12:30:00Z"):
    body = {"base_change_id": 0, "tx_type": "expense", "amount": amount, "happened_at": happened_at}
    if note is not None:
        body["note"] = note
    return client.post(f"/api/v1/write/ledgers/{ledger}/transactions",
                       headers=_auth(tok, device), json=body)


# --------------------------------------------------------------------------
# SQL 注入
# --------------------------------------------------------------------------


def test_sqli_payloads_are_stored_verbatim_and_do_not_execute(client):
    """SQL 注入串在所有文本入口按字面存储,表结构不受影响。"""
    c, TS = client
    body = _register(c, "sqli@example.com")
    tok = body["access_token"]
    ledger = _ledger(c, tok, "SQLI-L")

    payloads = [
        SQLI,
        "1' OR '1'='1",
        "'; UPDATE users SET is_admin=1 WHERE '1'='1",
        "\\'; DROP TABLE ledgers; --",
        "1 UNION SELECT password_hash FROM users --",
    ]
    for i, payload in enumerate(payloads):
        assert _tx(c, tok, ledger, note=payload, amount=float(i + 1)).status_code == 200
        assert c.post(
            f"/api/v1/write/ledgers/{ledger}/tags",
            headers=_auth(tok), json={"base_change_id": 0, "name": payload},
        ).status_code == 200

    # 表仍在,数据未被篡改
    db = TS()
    assert db.execute(text("SELECT COUNT(*) FROM users")).scalar() == 1
    assert db.execute(text("SELECT COUNT(*) FROM ledgers")).scalar() == 1
    row = db.execute(text("SELECT is_admin FROM users")).scalar()
    db.close()
    assert row in (0, False), "SQL 注入改写了 is_admin"

    notes = {t.get("note") for t in c.get(
        f"/api/v1/read/ledgers/{ledger}/transactions?limit=100", headers=_auth(tok)).json()}
    assert SQLI in notes, "SQL 注入串未被字面存储"


def test_sqli_in_query_params(client):
    """查询参数中的 SQL 注入串按字面搜索,不报错。"""
    c, _ = client
    tok = _register(c, "sqli2@example.com")["access_token"]
    ledger = _ledger(c, tok, "SQLI2")
    for q in (SQLI, "' OR 1=1 --", "%' UNION SELECT 1 --"):
        for path in (
            f"/api/v1/read/workspace/transactions?q={q}",
            f"/api/v1/read/workspace/tags?q={q}",
            f"/api/v1/read/workspace/categories?q={q}",
        ):
            res = c.get(path, headers=_auth(tok))
            assert res.status_code == 200, f"{path} → {res.status_code}"


# --------------------------------------------------------------------------
# XSS / 路径穿越 / 空字节
# --------------------------------------------------------------------------


def test_xss_payloads_stored_as_data(client):
    """`<script>` 按数据存储与回读(服务端不做 HTML 转义;前端需自行编码)。

    HARDENING: API 返回 JSON,由前端负责转义。此处确认服务端不会把它当
    模板/路径处理,也不报错。
    """
    c, _ = client
    tok = _register(c, "xss@example.com")["access_token"]
    ledger = _ledger(c, tok, "XSS-L")
    assert _tx(c, tok, ledger, note=XSS).status_code == 200
    res = c.post(f"/api/v1/write/ledgers/{ledger}/tags",
                 headers=_auth(tok), json={"base_change_id": 0, "name": XSS})
    assert res.status_code == 200
    tags = c.get("/api/v1/read/workspace/tags", headers=_auth(tok)).json()
    assert any(t.get("name") == XSS for t in tags)


def test_path_traversal_in_ledger_external_id_is_accepted(client):
    """`../../pwn` 作为 external_id 被接受,且注入到附件落盘路径。

    ADVERSE FINDING: external_id 无字符集校验
    (src/schemas.py:937 只限制 3-128 字符长度);
    src/routers/attachments.py:140 直接
    `_attachment_root() / ledger.user_id / ledger.external_id / sha256[:2]`
    拼路径,`..` 段未被 os.path.normpath/resolve 收敛。local 部署下
    (DATA_DIR 挂载)写入可逃出附件根目录 → 任意路径写文件。

    期望:external_id 拒绝含路径分隔/`..` 的值(422)。
    """
    c, TS = client
    tok = _register(c, "trav@example.com")["access_token"]
    res = c.post(
        "/api/v1/write/ledgers",
        headers=_auth(tok),
        json={"ledger_id": "../../pwn", "ledger_name": "PWN", "currency": "CNY"},
    )
    assert res.status_code == 422, (
        f"含路径穿越段的 external_id 应被拒绝,实际 {res.status_code}(已入库)"
    )


def test_attachment_storage_path_escapes_root(client, tmp_path, monkeypatch):
    """附件落盘路径逃出 `_attachment_root()`(配合上一条的可利用链)。

    ADVERSE FINDING: src/routers/attachments.py:138-142 —— 用户可控 external_id
    直接参与路径拼接。用 6 层 `..` 可逃出附件根目录(DATA_DIR/attachments →
    DATA_DIR 之外),`storage_dir.mkdir(parents=True)` 会**实际创建**该目录并
    写出文件。期望:路径规范化后校验仍在 root 内(对照 main.py:_resolve_static_file
    的 `is_relative_to` 校验)。
    """
    c, TS = client
    tok = _register(c, "trav2@example.com")["access_token"]

    import src.routers.attachments as att

    root = tmp_path / "att-root"
    root.mkdir()
    monkeypatch.setattr(att, "_attachment_root", lambda: root)

    ext = "../" * 6 + "escaped-dir"
    created = c.post("/api/v1/write/ledgers", headers=_auth(tok),
                     json={"ledger_id": ext, "ledger_name": "E", "currency": "CNY"})
    if created.status_code != 200:
        pytest.skip(f"external_id 已被拒绝({created.status_code})—— 缺陷已修")

    res = c.post(
        "/api/v1/attachments/upload",
        headers=_auth(tok),
        data={"ledger_id": ext},
        files={"file": ("payload.sh", b"#!/bin/sh\necho pwned\n", "text/x-sh")},
    )
    assert res.status_code == 200, res.text

    db = TS()
    from src.models import AttachmentFile

    row = db.query(AttachmentFile).order_by(AttachmentFile.created_at.desc()).first()
    stored = os.path.abspath(row.storage_path)
    db.close()

    root_abs = os.path.abspath(str(root))
    assert stored.startswith(root_abs + os.sep), (
        f"附件被写出到附件根目录之外:\n  root={root_abs}\n  stored={stored}"
    )


def test_nul_byte_in_text_fields(client):
    """空字节 `\\u0000` 在名称字段被接受并原样回读。

    ADVERSE FINDING: tags/categories/accounts 的 name 无字符集校验
    (src/schemas.py:1100 仅长度)。NUL 进入 SQLite TEXT 列,回读 JSON 时
    产生 `\\u0000`;下游(CSV 导出、文件命名、日志)可能截断或损坏。
    期望:422 或静默剥离控制字符。
    """
    c, _ = client
    tok = _register(c, "nul@example.com")["access_token"]
    ledger = _ledger(c, tok, "NUL-L")
    res = c.post(f"/api/v1/write/ledgers/{ledger}/tags",
                 headers=_auth(tok), json={"base_change_id": 0, "name": "evil\u0000name"})
    assert res.status_code == 422, f"含 NUL 的名称应被拒绝,实际 {res.status_code}"
    tags = c.get("/api/v1/read/workspace/tags", headers=_auth(tok)).json()
    assert not any("\u0000" in (t.get("name") or "") for t in tags), "NUL 已落入存储"


def test_lone_surrogate_rejected_with_422_not_500(client):
    """非法 UTF-8 代理对(`\\ud800`)在写路径 → 500。

    ADVERSE FINDING: FastAPI/pydantic 解析 JSON 时接受 lone surrogate
    (Python str 允许),随后 SQLAlchemy 写库 encode('utf-8') 抛
    UnicodeEncodeError → 全局 handler 500。期望:422(校验阶段拒绝)。
    """
    c, _ = client
    tok = _register(c, "surr@example.com")["access_token"]
    ledger = _ledger(c, tok, "SURR-L")
    res = c.post(
        f"/api/v1/write/ledgers/{ledger}/tags",
        headers={**_auth(tok), "Content-Type": "application/json"},
        content=b'{"base_change_id":0,"name":"x\\ud800y"}',
    )
    assert res.status_code != 500, f"lone surrogate 导致 500:{res.text[:200]}"
    assert res.status_code == 422


# --------------------------------------------------------------------------
# 超长字段
# --------------------------------------------------------------------------


def test_oversized_ledger_name_rejected(client):
    c, _ = client
    tok = _register(c, "longn@example.com")["access_token"]
    assert c.post("/api/v1/write/ledgers", headers=_auth(tok),
                  json={"ledger_id": "LONGN", "ledger_name": "N" * 100000}).status_code == 422
    assert c.post("/api/v1/write/ledgers", headers=_auth(tok),
                  json={"ledger_id": "L" * 5000, "ledger_name": "x"}).status_code == 422


def test_oversized_tag_and_category_names_rejected(client):
    c, _ = client
    tok = _register(c, "longt@example.com")["access_token"]
    ledger = _ledger(c, tok, "LONGT")
    assert c.post(f"/api/v1/write/ledgers/{ledger}/tags",
                  headers=_auth(tok), json={"base_change_id": 0, "name": "X" * 100000}).status_code == 422
    assert c.post(f"/api/v1/write/ledgers/{ledger}/categories",
                  headers=_auth(tok),
                  json={"base_change_id": 0, "name": "X" * 100000, "kind": "expense"}).status_code == 422


def test_unbounded_note_length_is_accepted(client):
    """`note` 无长度上限:1MB / 5MB 文本全部被接受并入投影。

    ADVERSE FINDING: `WriteTransactionCreateRequest.note` 无 max_length
    (src/schemas.py:953;对照 RawEvidenceUpsertRequest.body 的 max_length=65536)。
    read_tx_projection.note 是 Text 列,5MB 单行直接落库并随 sync_changes
    payload 与 CSV 导出重复放大(存储与带宽放大攻击面)。期望:设上限(如 64KB)。
    """
    c, TS = client
    tok = _register(c, "bignote@example.com")["access_token"]
    ledger = _ledger(c, tok, "BIGNOTE")
    res = _tx(c, tok, ledger, note="Z" * 1_000_000)
    assert res.status_code in (413, 422), (
        f"1MB note 应被拒(413/422),实际 {res.status_code}"
    )


def test_huge_body_total_size_handled(client):
    """10MB 单请求体:服务端应给出确定性 4xx 或正常处理,不能 5xx。"""
    c, _ = client
    tok = _register(c, "hugebody@example.com")["access_token"]
    ledger = _ledger(c, tok, "HUGEL")
    res = _tx(c, tok, ledger, note="Z" * 10_000_000)
    assert res.status_code != 500, f"10MB body 导致 500:{res.text[:200]}"


# --------------------------------------------------------------------------
# 分页 / 数值边界
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "query",
    [
        "limit=-1",
        "limit=0",
        "limit=2147483647",
        "limit=abc",
        "limit=99999999999999999999",
        "offset=-5",
    ],
)
def test_pagination_bounds_rejected_with_422(client, query):
    c, _ = client
    tok = _register(c, f"page{abs(hash(query)) % 100000}@example.com")["access_token"]
    for path in (
        "/api/v1/read/workspace/transactions",
        "/api/v1/read/workspace/trash",
        "/api/v1/profile/mcp-calls",
        "/api/v1/ai/logs",
        "/api/v1/evidence/raw",
    ):
        res = c.get(f"{path}?{query}", headers=_auth(tok))
        assert res.status_code == 422, f"{path}?{query} → {res.status_code}"


def test_offset_beyond_int64_returns_500(client):
    """`offset` 超过 64 位整型(> 2^63)时部分端点 500。

    ADVERSE FINDING: 多个端点的 `offset` 只声明 `Query(ge=0)`,没有上界;
    pydantic 接受任意 Python int,随后 SQLAlchemy 传给 SQLite 时抛
    `OverflowError: Python int too large to convert to SQLite INTEGER`
    (Postgres 会因 int8 out of range 同样报错)。

    实测:
      - `/read/workspace/trash`、`/profile/mcp-calls`、`/ai/logs`、
        `/evidence/raw` → 500(offset=2**63)
      - `/read/workspace/transactions` 侥幸 200(参数在其它分支被吞掉)
    期望:422(如 `le=2**31` 或 le=1_000_000)。
    """
    c, _ = client
    tok = _register(c, "hugeoff@example.com")["access_token"]
    broken = {}
    for path in (
        "/api/v1/read/workspace/transactions",
        "/api/v1/read/workspace/trash",
        "/api/v1/profile/mcp-calls",
        "/api/v1/ai/logs",
        "/api/v1/evidence/raw",
    ):
        code = c.get(f"{path}?offset={2**63}", headers=_auth(tok)).status_code
        if code >= 500:
            broken[path] = code
    assert not broken, f"offset 超 int64 导致 500:{broken}"


def test_legitimate_pagination_limits_ok(client):
    c, _ = client
    tok = _register(c, "pageok@example.com")["access_token"]
    for query in ("limit=1", "limit=2000", "offset=0", "limit=2000&offset=1000"):
        res = c.get(f"/api/v1/read/workspace/transactions?{query}", headers=_auth(tok))
        assert res.status_code == 200, f"{query} → {res.status_code}"


def test_nan_amount_returns_4xx_not_500(client):
    """JSON 里 `NaN` 作为 amount → 500。

    ADVERSE FINDING: `tx_type`/`amount: float`(src/schemas.py:951)默认允许
    NaN;NaN 写入 read_tx_projection.amount(NOT NULL Float)时 sqlite 抛
    IntegrityError("NOT NULL constraint failed") → src/routers/write/_shared.py:597
    无兜底 → 500。期望:422。
    """
    c, _ = client
    tok = _register(c, "nan@example.com")["access_token"]
    ledger = _ledger(c, tok, "NAN-L")
    res = c.post(
        f"/api/v1/write/ledgers/{ledger}/transactions",
        headers={**_auth(tok), "Content-Type": "application/json"},
        content=b'{"base_change_id":0,"tx_type":"expense","amount":NaN,'
                b'"happened_at":"2026-05-06T12:00:00Z"}',
    )
    assert res.status_code != 500, f"NaN amount 导致 500:{res.text[:200]}"
    assert res.status_code == 422


def test_infinity_amount_silently_persisted(client):
    """`Infinity` 作为 amount → 200,并以 NULL/`inf` 落入投影与 CSV。

    ADVERSE FINDING: Infinity 通过 float 校验,写入 projection 后:
      - `GET /read/ledgers/{id}/transactions` 的 amount 变成 `null`(ORM→JSON
        时被序列化成 null),
      - 聚合列(expense_total / balance)变 `null`,
      - CSV 导出直接输出字面 `inf`(Excel 解析为文本/错误值)。
    无校验、无告警、静默数据污染。期望:422(金额必须有限)。
    """
    c, _ = client
    tok = _register(c, "inf@example.com")["access_token"]
    ledger = _ledger(c, tok, "INF-L")
    res = c.post(
        f"/api/v1/write/ledgers/{ledger}/transactions",
        headers={**_auth(tok), "Content-Type": "application/json"},
        content=b'{"base_change_id":0,"tx_type":"expense","amount":Infinity,'
                b'"happened_at":"2026-05-06T12:00:00Z","note":"inf-note"}',
    )
    assert res.status_code == 422, (
        f"Infinity 金额应被拒绝(金额必须有限),实际 {res.status_code};"
        "已入库并污染聚合与 CSV 导出"
    )


def test_negative_amount_and_extreme_values(client):
    """负数金额被接受(记账语义允许冲正);极值受数量级上限约束。

    HARDENING(round-3 中-2 更新):web 写路径 `|amount| >= 1e12` → 422
    (`BoundedTxAmount`,与 mobile `maxWriteAmount` / pull 守卫同口径 ——
    旧的「1e308 通过」记录的是收窄前的现状,现为故意拒绝;sync push
    路径仍无范围约束,见 test_sync_numeric_boundary_adversarial)。
    负数仍由业务层容忍。
    """
    c, _ = client
    tok = _register(c, "numedge@example.com")["access_token"]
    ledger = _ledger(c, tok, "NUMEDGE")
    assert _tx(c, tok, ledger, amount=-100.0).status_code == 200
    res = c.post(
        f"/api/v1/write/ledgers/{ledger}/transactions",
        headers={**_auth(tok), "Content-Type": "application/json"},
        content=b'{"base_change_id":0,"tx_type":"expense","amount":1.7976931348623157e308,'
                b'"happened_at":"2026-05-06T12:00:00Z"}',
    )
    assert res.status_code == 422
    # 上限内的最大值(999999999999)仍通过 —— 边界与 mobile 完全一致。
    assert _tx(c, tok, ledger, amount=999999999999).status_code == 200


# --------------------------------------------------------------------------
# JSON 结构畸形
# --------------------------------------------------------------------------


def test_json_structure_malformations_return_4xx(client):
    c, _ = client
    tok = _register(c, "jsonmal@example.com")["access_token"]
    ledger = _ledger(c, tok, "JSONMAL")
    h = {**_auth(tok), "Content-Type": "application/json"}

    # 数组代替对象
    assert c.post(f"/api/v1/write/ledgers/{ledger}/transactions", headers=h,
                  content=b'[1,2,3]').status_code == 422
    # 字符串代替对象
    assert c.post(f"/api/v1/write/ledgers/{ledger}/transactions", headers=h,
                  content=b'"hello"').status_code == 422
    # 非法 JSON
    assert c.post(f"/api/v1/write/ledgers/{ledger}/transactions", headers=h,
                  content=b'{invalid').status_code == 422
    # 空体
    assert c.post(f"/api/v1/write/ledgers/{ledger}/transactions", headers=h,
                  content=b'').status_code == 422
    # 字段类型错误
    assert c.post(f"/api/v1/write/ledgers/{ledger}/transactions", headers=h,
                  json={"base_change_id": "not-an-int", "tx_type": "expense",
                        "amount": 1, "happened_at": "2026-05-06T12:00:00Z"}).status_code == 422


def test_deeply_nested_json_in_profile_corrupts_profile_read(client):
    """深嵌套 JSON(99 层)写入 profile → 后续 `GET /profile/me` 永久 500。

    ADVERSE FINDING: `UserProfilePatchRequest.appearance: dict`
    (src/schemas.py:66) 无深度/体积限制,`_dump_appearance_json`
    (src/routers/profile.py:118) 原样 `json.dumps` 落库。响应序列化时
    pydantic 递归超过 `sys.getrecursionlimit()` 附近深度 → 
    `PydanticSerializationError: Circular reference detected (depth exceeded)`
    → 500。**数据已落库**,此后 GET /profile/me、PATCH /profile/me 全部 500
    (自锁,用户无法自救),且这是 WS `profile_change` 与登录后首个请求的路径。
    期望:写入侧限制深度/体积(或序列化侧 raise 一个 4xx)。

    复现:`PATCH /profile/me {"appearance": {n:{n:{...99 层}}}}` → 500;
    随后 `GET /profile/me` → 500。
    """
    c, _ = client
    tok = _register(c, "deep@example.com")["access_token"]
    nested: dict = {}
    cur = nested
    for _ in range(120):
        cur["nested"] = {}
        cur = cur["nested"]

    patched = c.patch("/api/v1/profile/me", headers=_auth(tok), json={"appearance": nested})
    got = c.get("/api/v1/profile/me", headers=_auth(tok))
    assert patched.status_code != 500 and got.status_code == 200, (
        f"深嵌套 appearance 自锁 profile:patch={patched.status_code} get={got.status_code}"
    )


def test_deeply_nested_json_in_sync_push_payload_is_contained(client):
    """sync/push 的深嵌套 payload 不会 5xx(被 savepoint 隔离或正常接受)。

    HARDENING: push 的 payload 是 `dict[str, Any]`(src/schemas.py:157),
    150 层嵌套被接受并落 SyncChange.payload_json(JSON 序列化)。投影侧
    只读白名单字段,因此不会把深结构带到读路径。记录现状(存储放大)。
    """
    c, _ = client
    tok = _register(c, "deeppush@example.com", "app")["access_token"]
    nested: dict = {}
    cur = nested
    for _ in range(150):
        cur["n"] = {"v": 1}
        cur = cur["n"]
    res = c.post(
        "/api/v1/sync/push", headers=_auth(tok),
        json={"device_id": "d1", "changes": [{
            "ledger_id": None, "entity_type": "category", "entity_sync_id": "deep-cat",
            "action": "upsert",
            "payload": {"syncId": "deep-cat", "name": "x", "extra": nested},
            "updated_at": datetime.now(timezone.utc).isoformat()}]},
    )
    assert res.status_code == 200, res.text


# --------------------------------------------------------------------------
# CSV 导出 / 公式注入
# --------------------------------------------------------------------------


def test_csv_formula_injection_not_mitigated(client):
    """备注以 `=` 开头的公式在 CSV 导出中原样输出(Excel/Sheets 公式注入)。

    ADVERSE FINDING: `_csv_field`(src/routers/read/_shared.py:666-675)只做
    RFC 4180 引号转义,不处理 `=`/`+`/`-`/`@` 开头的公式前缀。用户在 web 导出
    后于 Excel 打开会执行公式(`=cmd|'/C calc'!A0` 为经典 DDE 攻击串)。
    期望:公式前缀加 `'` 或以制表符包裹(OWASP CSV injection)。
    """
    c, _ = client
    tok = _register(c, "csv@example.com")["access_token"]
    ledger = _ledger(c, tok, "CSV-L")
    payload = "=cmd|'/C calc'!A0"
    assert _tx(c, tok, ledger, note=payload).status_code == 200

    res = c.get("/api/v1/read/workspace/transactions.csv", headers=_auth(tok))
    assert res.status_code == 200
    lines = [ln for ln in res.text.splitlines() if "cmd|" in ln]
    assert lines, "CSV 导出未包含备注列?"
    cell = lines[0]
    # 导出列序:type,category,subcategory,amount,currency,account,from,to,note,
    # time,tags,attachments —— note 是第 9 列(索引 8 / 倒数第 4)。
    # 原实现取 `cells[-2]`(末列前的空 Attachments 字段)恒为空,导致这条
    # 「缺陷仍然存在」哨兵检查在**修复前也失败**,无法区分「已防护」与「列取错」。
    cells = cell.split(",")
    exported_note = cells[8] if len(cells) > 8 else ""
    # 哨兵:确认我们取到的确实是 note 列(未防护时应以 "=" 起始)
    assert "cmd|" in exported_note, f"列索引错位,取到的是 {exported_note!r}:{cell[:160]}"
    # 验收(期望见 docstring):危险前缀必须被中和 —— 不得以公式字符原样起始
    assert not (exported_note.startswith("=") or '"=cmd' in cell or ",=cmd" in cell), (
        f"CSV 公式注入未缓解:{cell[:160]}"
    )


def test_csv_export_escapes_quotes_and_newlines(client):
    """CSV 导出对引号 / 换行做 RFC 4180 转义(不破坏列结构)。"""
    c, _ = client
    tok = _register(c, "csv2@example.com")["access_token"]
    ledger = _ledger(c, tok, "CSV2-L")
    assert _tx(c, tok, ledger, note='he said "hi"\nnext line').status_code == 200
    res = c.get("/api/v1/read/workspace/transactions.csv", headers=_auth(tok))
    assert res.status_code == 200
    assert '""hi""' in res.text, "双引号未按 RFC 4180 转义"


# --------------------------------------------------------------------------
# 附件上传畸形输入
# --------------------------------------------------------------------------


def test_attachment_upload_malformed_inputs(client, tmp_path, monkeypatch):
    c, _ = client
    tok = _register(c, "attmal@example.com")["access_token"]
    ledger = _ledger(c, tok, "ATTMAL")

    import src.routers.attachments as att

    monkeypatch.setattr(att, "_attachment_root", lambda: tmp_path)

    # 空文件 → 400
    empty = c.post("/api/v1/attachments/upload", headers=_auth(tok),
                   data={"ledger_id": ledger},
                   files={"file": ("empty.bin", b"", "application/octet-stream")})
    assert empty.status_code == 400

    # 缺 file 字段 → 422
    assert c.post("/api/v1/attachments/upload", headers=_auth(tok),
                  data={"ledger_id": ledger}).status_code == 422
    # 缺 ledger_id → 422
    assert c.post("/api/v1/attachments/upload", headers=_auth(tok),
                  files={"file": ("a.bin", b"x", "application/octet-stream")}).status_code == 422

    # 文件名含路径穿越 → 只保留 basename(src/routers/attachments.py:_safe_file_name)
    trav = c.post("/api/v1/attachments/upload", headers=_auth(tok),
                  data={"ledger_id": ledger},
                  files={"file": ("../../../../evil.sh", b"#!/bin/sh\n", "text/x-sh")})
    assert trav.status_code == 200, trav.text
    assert "/" not in trav.json()["file_name"] and "\\" not in trav.json()["file_name"]
    assert trav.json()["file_name"] == "evil.sh"


def test_attachment_download_for_foreign_ledger_rejected(client, tmp_path, monkeypatch):
    """非成员 / 被移除成员不能下载他人账本的附件。"""
    c, _ = client
    a = _register(c, "attd-a@example.com")["access_token"]
    x = _register(c, "attd-x@example.com")["access_token"]
    ledger = _ledger(c, a, "ATTD-L")

    import src.routers.attachments as att

    monkeypatch.setattr(att, "_attachment_root", lambda: tmp_path)
    up = c.post("/api/v1/attachments/upload", headers=_auth(a), data={"ledger_id": ledger},
                files={"file": ("s.txt", b"TOPSECRET-ATTACHMENT", "text/plain")})
    assert up.status_code == 200, up.text
    fid = up.json()["file_id"]

    assert c.get(f"/api/v1/attachments/{fid}").status_code == 401
    foreign = c.get(f"/api/v1/attachments/{fid}", headers=_auth(x))
    assert foreign.status_code == 403
    assert "TOPSECRET" not in foreign.text
    assert c.get(f"/api/v1/attachments/{fid}", headers=_auth(a)).status_code == 200


def test_attachment_oversize_rejected(client, tmp_path, monkeypatch):
    c, _ = client
    tok = _register(c, "attbig@example.com")["access_token"]
    ledger = _ledger(c, tok, "ATTBIG")
    import src.routers.attachments as att

    monkeypatch.setattr(att, "_attachment_root", lambda: tmp_path)
    from src.config import get_settings

    limit = get_settings().attachment_max_upload_bytes
    res = c.post("/api/v1/attachments/upload", headers=_auth(tok), data={"ledger_id": ledger},
                 files={"file": ("big.bin", b"Z" * (limit + 1), "application/octet-stream")})
    assert res.status_code == 413


# --------------------------------------------------------------------------
# 其他畸形输入
# --------------------------------------------------------------------------


def test_invalid_uuid_and_id_shapes(client):
    """畸形 path 参数:非 UUID / 非法 int 不应 5xx(超 int64 的 log_id 除外,
    单独由 test_huge_int_path_param_returns_500 覆盖)。"""
    c, _ = client
    tok = _register(c, "idshape@example.com")["access_token"]
    for path in (
        "/api/v1/profile/pats/not-a-uuid",
        "/api/v1/ai/logs/not-an-int",
        "/api/v1/evidence/raw/not-an-id",
        "/api/v1/admin/users/not-a-uuid",
    ):
        res = c.get(path, headers=_auth(tok))
        assert res.status_code < 500, f"{path} → {res.status_code}"


def test_huge_int_path_param_returns_500(client):
    """超 int64 的 `log_id` path 参数 → 500(与 offset 同源的溢出)。

    ADVERSE FINDING: `GET /ai/logs/{log_id}`(`log_id: int`)无上界;
    `db.get(AIAnalysisLog, 10**22)` → SQLite OverflowError → 500。
    期望:404 或 422。
    """
    c, _ = client
    tok = _register(c, "hugeid@example.com")["access_token"]
    res = c.get(f"/api/v1/ai/logs/{10**22}", headers=_auth(tok))
    assert res.status_code < 500, f"超 int64 的 log_id → {res.status_code}"


def test_bad_datetime_formats_rejected(client):
    c, _ = client
    tok = _register(c, "dt@example.com")["access_token"]
    ledger = _ledger(c, tok, "DT-L")
    for bad in ("not-a-date", "2026-13-45T99:99:99Z", "0000-00-00", ""):
        res = c.post(
            f"/api/v1/write/ledgers/{ledger}/transactions",
            headers=_auth(tok),
            json={"base_change_id": 0, "tx_type": "expense", "amount": 1, "happened_at": bad},
        )
        assert res.status_code == 422, f"happened_at={bad!r} → {res.status_code}"


def test_bad_currency_and_hex_color_inputs(client):
    c, _ = client
    tok = _register(c, "cur@example.com")["access_token"]
    ledger = _ledger(c, tok, "CUR-L")
    # theme_primary_color 必须是 #RRGGBB
    for bad in ("red", "#12345", "#GGGGGG", "javascript:alert(1)", "#12345678"):
        res = c.patch("/api/v1/profile/me", headers=_auth(tok), json={"theme_primary_color": bad})
        assert res.status_code == 422, f"{bad!r} → {res.status_code}"
    # 合法值被规范化
    ok = c.patch("/api/v1/profile/me", headers=_auth(tok), json={"theme_primary_color": "#aabbcc"})
    assert ok.status_code == 200 and ok.json()["theme_primary_color"] == "#AABBCC"
    # primary_currency pattern ^[A-Za-z]{3,8}$
    assert c.patch("/api/v1/profile/me", headers=_auth(tok),
                   json={"primary_currency": "USD; DROP TABLE users"}).status_code == 422
    assert c.patch("/api/v1/profile/me", headers=_auth(tok),
                   json={"primary_currency": "US"}).status_code == 422


def test_display_name_boundaries(client):
    c, _ = client
    tok = _register(c, "dn@example.com")["access_token"]
    assert c.patch("/api/v1/profile/me", headers=_auth(tok),
                   json={"display_name": "   "}).status_code == 422
    assert c.patch("/api/v1/profile/me", headers=_auth(tok),
                   json={"display_name": "X" * 33}).status_code == 422
    assert c.patch("/api/v1/profile/me", headers=_auth(tok),
                   json={"display_name": "X" * 32}).status_code == 200


def test_evidence_source_validation(client):
    """evidence source 拒绝空白/控制字符(白名单之外但允许新值)。"""
    c, _ = client
    tok = _register(c, "evsrc@example.com", "app")["access_token"]
    now = datetime.now(timezone.utc).isoformat()
    for bad in ("", "  ", "bad source", "bad\nsource", "x" * 40):
        res = c.post("/api/v1/evidence/raw", headers=_auth(tok),
                     json={"event_key": "k", "source": bad, "captured_at": now})
        assert res.status_code in (400, 422, 410), f"{bad!r} → {res.status_code}"
    # 合法
    assert c.post("/api/v1/evidence/raw", headers=_auth(tok),
                  json={"event_key": "k-ok", "source": "sms", "captured_at": now}).status_code == 200


def test_evidence_metadata_size_bound(client):
    """evidence metadata 有体积上限(src/schemas.py:_limit_metadata)。"""
    c, _ = client
    tok = _register(c, "evmeta@example.com", "app")["access_token"]
    now = datetime.now(timezone.utc).isoformat()
    huge = {"k": "V" * 200_000}
    res = c.post("/api/v1/evidence/raw", headers=_auth(tok),
                 json={"event_key": "k", "source": "sms", "metadata": huge, "captured_at": now})
    assert res.status_code in (400, 422), f"超体 metadata → {res.status_code}"


def test_mcp_call_logs_filter_values_validated(client):
    c, _ = client
    tok = _register(c, "mcpfilt@example.com")["access_token"]
    assert c.get("/api/v1/profile/mcp-calls?status=bogus", headers=_auth(tok)).status_code == 422
    assert c.get("/api/v1/profile/mcp-calls?status=ok", headers=_auth(tok)).status_code == 200
    assert c.get("/api/v1/profile/mcp-calls?limit=0", headers=_auth(tok)).status_code == 422


def test_ai_logs_entry_type_pattern_validated(client):
    c, _ = client
    tok = _register(c, "ailogp@example.com")["access_token"]
    assert c.get("/api/v1/ai/logs?entry_type=..%2Fetc", headers=_auth(tok)).status_code == 422
    assert c.get("/api/v1/ai/logs?status=bogus", headers=_auth(tok)).status_code == 422
    assert c.get("/api/v1/ai/logs?entry_type=ask&status=ok", headers=_auth(tok)).status_code == 200


def test_exchange_rate_base_currency_pattern(client):
    """汇率 base 参数必须过 ^[A-Za-z]{3,8}$(防 SSRF/缓存污染)。"""
    c, _ = client
    tok = _register(c, "fx@example.com")["access_token"]
    for bad in ("USD/../..", "abcdefghij", "US", "invalid;param=1", "USD%20"):
        res = c.get(f"/api/v1/read/exchange-rates?base={bad}", headers=_auth(tok))
        assert res.status_code == 422, f"{bad!r} → {res.status_code}"


def test_exchange_rate_override_validation(client):
    c, _ = client
    tok = _register(c, "fwo@example.com")["access_token"]
    cases = [
        {"base_currency": "USD", "quote_currency": "USD", "rate": "7.2"},  # same
        {"base_currency": "USD", "quote_currency": "CNY", "rate": "abc"},
        {"base_currency": "USD", "quote_currency": "CNY", "rate": "0"},
        {"base_currency": "USD", "quote_currency": "CNY", "rate": "-1"},
        {"base_currency": "USD", "quote_currency": "CNY", "rate": "1e12"},
    ]
    for body in cases:
        res = c.put("/api/v1/write/exchange-rate-overrides", headers=_auth(tok), json=body)
        assert res.status_code == 422, f"{body} → {res.status_code}"


def test_static_path_traversal_blocked(client):
    """SPA catch-all 的路径穿越防护(对照 src/main.py:_resolve_static_file)。"""
    c, _ = client
    for evil in ("..%2F..%2Fdata%2F.jwt_secret", "..%2Fmain.py", "%2e%2e%2f%2e%2e%2fetc%2fpasswd"):
        res = c.get(f"/{evil}")
        assert res.status_code in (404, 400, 405), f"{evil} → {res.status_code}"
        assert "SECRET" not in res.text and "jwt_secret" not in res.text
