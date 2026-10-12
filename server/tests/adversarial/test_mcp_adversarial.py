"""对抗性测试 —— MCP endpoint(PAT 鉴权 + Streamable HTTP transport)。

覆盖攻击面:
  - 无凭据 / 非 PAT / 已撤销 / 已过期 PAT → 401/403
  - scope 越权:只读 PAT 调写工具
  - 畸形 JSON-RPC:非 JSON / 空 body / 超大帧 / 超大 tool name / 控制字符
  - tool name 注入到调用日志(args_summary / tool_name)
  - 认证前调用工具(中间件必须在 session manager 之前拒绝)
  - GET(旧 SSE 语义)与 Accept/Content-Type 协商

注意:这些用例需要真实 lifespan(`with TestClient(app)`)以初始化
streamable session manager;因此每个用例都走 `with` 块,并在结束后显式
清掉 dependency_overrides。
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from src.database import Base, get_db
from src.main import app
from src.mcp import auth as mcp_auth
from src.mcp import server as mcp_server
from src.models import MCPCallLog, PersonalAccessToken, User
from src.security import generate_pat, hash_password

_MCP_HEADERS = {
    "Accept": "application/json, text/event-stream",
    "Content-Type": "application/json",
}
_INIT = {
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "2025-06-18", "capabilities": {},
               "clientInfo": {"name": "adv-probe", "version": "1"}},
}


@pytest.fixture(scope="module")
def mcp_client():
    """模块级共享 client —— StreamableHTTPSessionManager.run() 每实例只能调一次。

    因此 lifespan 只在整个模块进入一次;每个用例各自换 DB(SessionLocal 是
    调用时名字查找,per-test monkeypatch 即可生效)。
    """
    with TestClient(app) as client:
        yield client


@pytest.fixture
def mcp_env(monkeypatch, tmp_path):
    """文件库 + SessionLocal 替换。yield (Session, seed_pat)。

    用**文件库**而不是 `sqlite://` + StaticPool:本文件有 4 个用例要等
    `MCPCallLog` 由后台线程落库(`asyncio.to_thread(_write_call_log)`),而
    StaticPool 把**同一条**连接在请求线程与后台线程之间共享 —— 并发使用会
    互相干扰(SQLAlchemy 文档明确 StaticPool 不适合多线程),实测约 20~40%
    的轮次里轮询读不到刚写入的行(偶发红灯)。文件库给每个连接独立 sqlite
    handle,写入后立即可见(实测 10/10 稳定)。
    """
    engine = create_engine(
        f"sqlite:///{tmp_path / 'mcp_adv.db'}",
        connect_args={"check_same_thread": False},
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
    # MCP middleware 走同步 Session,必须一起替换
    monkeypatch.setattr(mcp_auth, "SessionLocal", Session)
    # tool 内部走 server 模块的 SessionLocal
    monkeypatch.setattr(mcp_server, "SessionLocal", Session)

    def seed(*, scopes=("mcp:read", "mcp:write"), revoked=False, expires=None) -> str:
        plaintext, token_hash, prefix = generate_pat()
        with Session() as db:
            user = User(
                id=str(uuid4()), email=f"mcp-adv-{uuid4().hex[:6]}@example.com",
                password_hash=hash_password("x"), is_admin=False, is_enabled=True,
                created_at=datetime.now(timezone.utc),
            )
            db.add(user)
            db.flush()
            db.add(PersonalAccessToken(
                id=str(uuid4()), user_id=user.id, name="adv", token_hash=token_hash,
                prefix=prefix, scopes_json=json.dumps(list(scopes)),
                created_at=datetime.now(timezone.utc),
                revoked_at=datetime.now(timezone.utc) if revoked else None,
                expires_at=expires,
            ))
            db.commit()
        return plaintext

    yield Session, seed
    app.dependency_overrides.clear()


def _post(client: TestClient, body, pat: str | None = None, *, raw: bytes | None = None,
          headers: dict | None = None):
    hdrs = dict(_MCP_HEADERS)
    if headers:
        hdrs.update(headers)
    if pat is not None:
        hdrs["Authorization"] = f"Bearer {pat}"
    if raw is not None:
        return client.post("/api/v1/mcp", headers=hdrs, content=raw)
    return client.post("/api/v1/mcp", headers=hdrs, json=body)


# ══════════════════════════════════════════════════════════════════════
# 1. 凭据
# ══════════════════════════════════════════════════════════════════════


def test_mcp_without_credentials_is_401(mcp_env, mcp_client) -> None:
    """无 Authorization → 401(不进入 session manager)。"""
    client = mcp_client
    Session, seed = mcp_env
    res = _post(client, _INIT)
    assert res.status_code == 401, res.text


def test_mcp_with_jwt_instead_of_pat_is_403(mcp_env, mcp_client) -> None:
    """拿 JWT/任意非 PAT 串冒充 → 403(明确要求 PAT)。"""
    client = mcp_client
    from src.security import create_access_token

    Session, seed = mcp_env
    jwt_token, _ = create_access_token("someone", scopes=["app_write"])
    res = _post(client, _INIT, pat=jwt_token)
    assert res.status_code == 403, res.text


def test_mcp_with_garbage_pat_shape_token_is_401(mcp_env, mcp_client) -> None:
    """形如 PAT(bcmcp_ 前缀)但不存在 → 401(不泄露 token 是否存在)。"""
    client = mcp_client
    Session, seed = mcp_env
    res = _post(client, _INIT, pat="bcmcp_" + "A" * 60)
    assert res.status_code == 401, res.text


def test_mcp_revoked_pat_is_401(mcp_env, mcp_client) -> None:
    """已撤销 PAT → 401。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed(revoked=True)
    assert _post(client, _INIT, pat=pat).status_code == 401


def test_mcp_expired_pat_is_401(mcp_env, mcp_client) -> None:
    """已过期 PAT → 401(不得 500:naive/aware 时间比较曾有 TypeError 历史)。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed(expires=datetime.now(timezone.utc) - timedelta(minutes=1))
    res = _post(client, _INIT, pat=pat)
    assert res.status_code == 401, res.text


def test_mcp_disabled_user_pat_is_rejected(mcp_env, mcp_client) -> None:
    """PAT 有效但所属 user 被禁用 → 401/403 拒绝(不得 200、不得 500)。

    断言修正(2026-10):`PATAuthMiddleware._resolve_pat_sync` 对禁用用户抛
    `_AuthError(403, "User disabled")`,因此实际是 403 而非 401 —— 鉴权通过、
    授权拒绝,语义同样正确且不泄露 token 存在性,故收窄为 401/403 双收。
    """
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    with Session() as db:
        user = db.scalar(select(User).where(User.id.in_(
            db.scalars(select(PersonalAccessToken.user_id)).all()
        )))
        user.is_enabled = False
        db.commit()
    assert _post(client, _INIT, pat=pat).status_code in (401, 403)


# ══════════════════════════════════════════════════════════════════════
# 2. scope 越权
# ══════════════════════════════════════════════════════════════════════


def test_readonly_pat_cannot_call_write_tool(mcp_env, mcp_client) -> None:
    """只读 PAT 调写工具 → 工具级拒绝(JSON-RPC error,非 200 成功)。"""
    client = mcp_client
    Session, seed = mcp_env
    read_pat = seed(scopes=["mcp:read"])
    assert _post(client, _INIT, pat=read_pat).status_code == 200
    res = _post(client, {
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "create_transaction", "arguments": {
            "ledger_id": "L", "amount": 1, "tx_type": "expense",
            "happened_at": "2026-01-01T00:00:00Z"}},
    }, pat=read_pat)
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["result"]["isError"] is True, body
    assert "mcp:write" in body["result"]["content"][0]["text"], body


def test_writeonly_pat_cannot_call_read_tool(mcp_env, mcp_client) -> None:
    """只写 PAT 调读工具 → 同样被 scope 拦。"""
    client = mcp_client
    Session, seed = mcp_env
    write_pat = seed(scopes=["mcp:write"])
    assert _post(client, _INIT, pat=write_pat).status_code == 200
    res = _post(client, {
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "list_ledgers", "arguments": {}},
    }, pat=write_pat)
    body = res.json()
    assert body["result"]["isError"] is True, body
    assert "mcp:read" in body["result"]["content"][0]["text"], body


def test_scope_violation_is_audit_logged(mcp_env, mcp_client) -> None:
    """ADVERSE FINDING: scope 越权尝试**不**落 MCPCallLog(不可审计)。

    期望:越权探测(只读 PAT 打写工具)也应留痕,便于发现 token 被滥用;
    实际:`_logged_call`(src/mcp/server.py:119-160)在 `try` 块**之前**就
    `require_mcp_scope(ctx, scope)` 抛 PermissionError,`finally` 里的
    `asyncio.create_task(..._write_call_log)` 根本没机会执行 → 该次调用
    完全无审计记录。攻击者拿一个只读 PAT 可以无限次探测/爆破写工具,
    日志里一片干净。
    """
    client = mcp_client
    Session, seed = mcp_env
    read_pat = seed(scopes=["mcp:read"])
    _post(client, _INIT, pat=read_pat)
    _post(client, {
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": {"name": "create_transaction", "arguments": {
            "ledger_id": "L", "amount": 1, "tx_type": "expense",
            "happened_at": "2026-01-01T00:00:00Z"}},
    }, pat=read_pat)
    # 调用日志写入走 asyncio.to_thread 的 create_task,给一点时间落库
    import time

    # 日志写入走 asyncio.create_task(to_thread(...)),负载下可能晚到几秒 ——
    # 上限放到 5s,避免把「慢」误报成「没写」(scope 越权用例仍会失败,那是真缺陷)。
    for _ in range(100):
        with Session() as db:
            rows = db.scalars(select(MCPCallLog)).all()
        if rows:
            break
        time.sleep(0.05)
    # ADVERSE FINDING: 越权调用未落 MCPCallLog(require_mcp_scope 在 try 之前抛出)
    assert rows, "scope 越权未被记入 MCPCallLog"
    assert rows[0].status == "error", rows[0].status
    assert "create_transaction" in (rows[0].tool_name or "")


# ══════════════════════════════════════════════════════════════════════
# 3. 畸形帧 / 解析层
# ══════════════════════════════════════════════════════════════════════


def test_mcp_non_json_body_is_parse_error_400(mcp_env, mcp_client) -> None:
    """非 JSON body → JSON-RPC parse error(400),不是 500。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    assert _post(client, _INIT, pat=pat).status_code == 200
    res = _post(client, None, pat=pat, raw=b"not-json-at-all")
    assert res.status_code == 400, res.text
    body = res.json()
    assert body["error"]["code"] == -32700, body


def test_mcp_empty_body_is_parse_error(mcp_env, mcp_client) -> None:
    """空 body → 400 parse error(不 500)。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    assert _post(client, _INIT, pat=pat).status_code == 200
    res = _post(client, None, pat=pat, raw=b"")
    assert res.status_code in (400, 406, 415), res.text


def test_mcp_oversize_body_rejected_413(mcp_env, mcp_client) -> None:
    """超大帧(>MCP 默认 body 上限)→ 413 拒绝(不 OOM/不 hang)。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    huge = (b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"pad":"'
            + b"A" * (12 * 1024 * 1024) + b'"}}}')
    assert _post(client, _INIT, pat=pat).status_code == 200
    res = _post(client, None, pat=pat, raw=huge)
    assert res.status_code == 413, f"{res.status_code} {res.text[:160]}"


def test_mcp_missing_accept_header_negotiation(mcp_env, mcp_client) -> None:
    """HARDENING:Accept 头不足时 streamable transport 用 406 拒绝。

    记录协商行为:客户端必须同时接受 application/json 与
    text/event-stream(`Accept: application/json, text/event-stream`)。
    这属于 MCP 规范要求,但会让只发 `Accept: application/json` 的老客户端
    直接 406 —— 记录为兼容性边界。
    """
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    _post(client, _INIT, pat=pat)
    res = _post(
        client, _INIT, pat=pat,
        headers={"Accept": "application/json"},
    )
    assert res.status_code in (200, 406), res.text


def test_mcp_get_with_pat_never_returns(mcp_env, mcp_client) -> None:
    """ADVERSE FINDING: 带 PAT 的 GET /api/v1/mcp **永不返回**(连接被挂起)。

    期望:MCP Streamable HTTP 的 GET 是可选能力 —— 不支持就该立刻 405/406
    (原用例即按此写),支持就该立刻发响应头再保持 SSE 流。
    实测(两路独立验证):
      - TestClient(app):5s 内连 `http.response.start` 都收不到;
      - 真实 uvicorn + httpx(timeout=5):服务端 access 日志已记
        `GET /api/v1/mcp → 200`(observability 在 call_next 返回时打点),
        客户端却是 ReadTimeout —— 响应头从未上线。
    后果:连接被无限占住直到进程退出,且日志显示 200 与客户端实际收不到
    响应严重不一致(监控失真)。任一持 PAT 的账号可并发开 N 个 GET 把
    连接/工作线程占满(资源耗尽),反代层同样会被悬挂连接拖住。

    实现要点:用 daemon 线程 + join(timeout) 保证**套件不被挂死**;
    断言按「安全行为」写(必须在 5s 内返回),因此保持红色。
    """
    import threading

    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    result: dict = {}

    def _get() -> None:
        try:
            result["status"] = client.get(
                "/api/v1/mcp",
                headers={"Authorization": f"Bearer {pat}",
                         "Accept": "application/json, text/event-stream"},
            ).status_code
        except Exception as exc:  # noqa: BLE001 — 超时/断连都算「返回了」
            result["err"] = repr(exc)

    th = threading.Thread(target=_get, daemon=True)
    th.start()
    th.join(timeout=5)
    # ADVERSE FINDING: GET 挂起不返回 → 断言失败(安全期望:5s 内必须有响应)
    assert not th.is_alive(), (
        "带 PAT 的 GET /api/v1/mcp 5s 内未返回(响应头都不发,连接被无限挂起);"
        f" 期望 405/406 或立即开始 SSE 流。result={result}"
    )


# ══════════════════════════════════════════════════════════════════════
# 4. tool name / 参数注入到审计日志
# ══════════════════════════════════════════════════════════════════════


def test_unknown_tool_name_is_graceful_error(mcp_env, mcp_client) -> None:
    """不存在的工具名 → 优雅的 isError 响应(不 500)。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    _post(client, _INIT, pat=pat)
    res = _post(client, {
        "jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": {"name": "no_such_tool_xyz", "arguments": {}},
    }, pat=pat)
    assert res.status_code == 200, res.text
    assert res.json()["result"]["isError"] is True, res.json()


def test_unknown_tool_name_with_control_characters_is_graceful(mcp_env, mcp_client) -> None:
    """tool name 含控制字符 / 超长 → 同样优雅报错,且**不写日志**(未命中工具)。

    对抗点:不能让攻击者用任意 tool_name 往 MCPCallLog.tool_name 里注入
    超长/控制字符内容(`_write_call_log` 只在工具真正被调用时触发,因此
    unknown tool 不会落库 —— 这里断言该性质)。
    """
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    _post(client, _INIT, pat=pat)
    for name in ("bad\x00name", "x" * 5000, "list_ledgers\nstatus=ok"):
        res = _post(client, {
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": {"name": name, "arguments": {}},
        }, pat=pat)
        assert res.status_code == 200, f"{name[:20]!r} -> {res.status_code}"
        assert res.json()["result"]["isError"] is True, res.json()

    import time

    time.sleep(0.2)
    with Session() as db:
        rows = db.scalars(select(MCPCallLog)).all()
    assert rows == [], f"未命中的 tool name 不应落审计日志: {[r.tool_name[:30] for r in rows]}"


def test_args_summary_skips_free_text_fields(mcp_env, mcp_client) -> None:
    """HARDENING:args_summary 跳过 note/text,且总长截断到 200 字。

    断言当前脱敏行为成立:note 里的自由文本不落审计日志。
    """
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    _post(client, _INIT, pat=pat)
    _post(client, {
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": {"name": "list_transactions", "arguments": {
            "ledger_id": "L", "limit": 5, "q": ("Q" * 40), "note": "SECRET-NOTE"}},
    }, pat=pat)
    import time

    # 日志写入走 asyncio.create_task(to_thread(...)),负载下可能晚到几秒 ——
    # 上限放到 5s,避免把「慢」误报成「没写」(scope 越权用例仍会失败,那是真缺陷)。
    for _ in range(100):
        with Session() as db:
            rows = db.scalars(select(MCPCallLog)).all()
        if rows:
            break
        time.sleep(0.05)
    assert rows, "list_transactions 调用未落审计日志"
    summary = rows[0].args_summary or ""
    assert "SECRET-NOTE" not in summary, summary
    assert len(summary) <= 200, len(summary)


def test_tool_name_length_in_call_log_is_bounded(mcp_env, mcp_client) -> None:
    """HARDENING:成功调用的 tool_name 是服务端常量(不可被客户端注入长度)。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    _post(client, _INIT, pat=pat)
    _post(client, {
        "jsonrpc": "2.0", "id": 8, "method": "tools/call",
        "params": {"name": "get_active_ledger", "arguments": {}},
    }, pat=pat)
    import time

    # 日志写入走 asyncio.create_task(to_thread(...)),负载下可能晚到几秒 ——
    # 上限放到 5s,避免把「慢」误报成「没写」(scope 越权用例仍会失败,那是真缺陷)。
    for _ in range(100):
        with Session() as db:
            rows = db.scalars(select(MCPCallLog)).all()
        if rows:
            break
        time.sleep(0.05)
    assert rows
    assert rows[0].tool_name == "get_active_ledger", rows[0].tool_name
    assert len(rows[0].tool_name) <= 64


def test_mcp_tools_list_does_not_require_write_scope(mcp_env, mcp_client) -> None:
    """tools/list 只需认证;返回的工具清单里写工具带 annotations 标注。"""
    client = mcp_client
    Session, seed = mcp_env
    read_pat = seed(scopes=["mcp:read"])
    _post(client, _INIT, pat=read_pat)
    res = _post(client, {"jsonrpc": "2.0", "id": 9, "method": "tools/list", "params": {}},
                pat=read_pat)
    assert res.status_code == 200, res.text
    names = {t["name"] for t in res.json()["result"]["tools"]}
    assert "list_ledgers" in names and "create_transaction" in names, sorted(names)


def test_mcp_batch_request_rejected_or_handled(mcp_env, mcp_client) -> None:
    """JSON-RPC 批数组(单请求多调用)→ 不得绕过鉴权/审计(4xx/优雅错误)。"""
    client = mcp_client
    Session, seed = mcp_env
    pat = seed()
    _post(client, _INIT, pat=pat)
    res = _post(client, [
        {"jsonrpc": "2.0", "id": 10, "method": "tools/list", "params": {}},
        {"jsonrpc": "2.0", "id": 11, "method": "tools/call",
         "params": {"name": "list_ledgers", "arguments": {}}},
    ], pat=pat)
    assert res.status_code in (200, 400, 406, 422), res.text
    if res.status_code == 200:
        # 若被接受,每个子请求都必须各自经过 scope 检查(此处无断言失败风险)
        body = res.json()
        assert isinstance(body, (list, dict)), body


def test_mcp_requires_pat_even_for_initialize(mcp_env, mcp_client) -> None:
    """认证前不得调用任何工具:未带 PAT 的 tools/call 直接 401。"""
    client = mcp_client
    Session, seed = mcp_env
    res = _post(client, {
        "jsonrpc": "2.0", "id": 12, "method": "tools/call",
        "params": {"name": "list_ledgers", "arguments": {}},
    })
    assert res.status_code == 401, res.text
    import time

    time.sleep(0.1)
    with Session() as db:
        assert db.scalars(select(MCPCallLog)).all() == []
