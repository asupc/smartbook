"""AI 分析日志 — 落库 + 查询 endpoint + 账户 hint 测试。

覆盖:
- write_ai_analysis_log:成功字段 + 超长截断
- /ai/parse-tx-text 成功后自动落一行(status=ok, 含 input/output/tokens)
- /ai/parse-tx-text provider 失败也落一行(status=error)
- /ai/ask(SSE)流完成后落一行(输出为 chunks 拼接全文)
- App 自报通道(POST /ai/logs、/ai/logs/image)已删除 → 405
  (中转路径 /ai/relay/* 的落库断言在 test_ai_relay.py)
- /ai/logs:用户隔离、entry_type/status 过滤、预览截断、UTC tz 标记
- /ai/logs/{id}:自己的全文可见,他人 404
- DELETE /ai/logs/{id}:自己删行 + 删落盘图片,他人/不存在 404
- POST /ai/logs/batch-delete:多删自己 + 删图,跳过他人/不存在,id 去重,空/超长 422
- _prune_retention_logs:超期 mcp 日志照清;AI 日志永久保留不受自动清理影响
- /admin/ai-analysis-logs:非 admin 拒绝;admin 可全局查 + 任意用户详情
- _format_accounts_hint:账户类型 / 银行名 / 卡尾号进入提示
"""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base, get_db
from src.main import app
from src.models import AIAnalysisLog, MCPCallLog, User, UserProfile
from src.services.ai import ChatJSONResult
from src.services.ai import analysis_log as analysis_log_module
from src.services.ai import docs_index as docs_index_module
from src.services.ai.analysis_log import write_ai_analysis_log
from src.services.ai.prompts import _format_accounts_hint


def _bootstrap(monkeypatch):
    """内存 sqlite + 替换 get_db / analysis_log.SessionLocal(写日志用独立 session)。"""
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
    monkeypatch.setattr(analysis_log_module, "SessionLocal", Session)
    return Session


def _register(client: TestClient, email: str, password: str = "Pa$$word1!") -> str:
    """注册 + 登录,返回 access_token。"""
    client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "password": password,
            "device_id": "ai-log-dev",
            "client_type": "web",
            "device_name": "pytest-web",
            "platform": "test",
        },
    )
    r = client.post(
        "/api/v1/auth/login",
        json={
            "email": email,
            "password": password,
            "device_id": "ai-log-dev",
            "client_type": "web",
            "device_name": "pytest-web",
            "platform": "test",
        },
    )
    return r.json()["access_token"]


def _seed_ai_config(Session, email: str) -> None:
    with Session() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
        db.add(UserProfile(
            user_id=uid,
            ai_config_json=json.dumps({
                "providers": [{
                    "id": "zhipu_glm", "apiKey": "sk-x", "baseUrl": "https://x",
                    "textModel": "glm-4-flash",
                }],
                "binding": {"textProviderId": "zhipu_glm"},
            }),
        ))
        db.commit()


def _count_logs(Session) -> int:
    with Session() as db:
        return len(db.scalars(select(AIAnalysisLog)).all())


# ──────────────────────────────────────────────────────────────────────
# write_ai_analysis_log
# ──────────────────────────────────────────────────────────────────────


def test_write_log_persists_row(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        with Session() as db:
            u = User(
                id="u-test-1",
                email="logger@example.com",
                password_hash="x",
                is_admin=False,
                is_enabled=True,
                created_at=datetime.now(timezone.utc),
            )
            db.add(u)
            db.commit()

        write_ai_analysis_log(
            user_id="u-test-1",
            entry_type="parse_tx_text",
            status="ok",
            provider_id="zhipu_glm",
            model="glm-4-flash",
            ledger_id="ledger-abc",
            input_text="昨天打车 30 块",
            output_text='{"tx_drafts": [{"amount": 30}]}',
            duration_ms=123,
            prompt_tokens=10,
            completion_tokens=5,
            total_tokens=15,
            client_ip="127.0.0.1",
        )

        with Session() as db:
            r = db.scalar(select(AIAnalysisLog))
            assert r is not None
            assert r.entry_type == "parse_tx_text"
            assert r.status == "ok"
            assert r.provider_id == "zhipu_glm"
            assert r.model == "glm-4-flash"
            assert r.ledger_id == "ledger-abc"
            assert r.input_text == "昨天打车 30 块"
            assert r.output_text == '{"tx_drafts": [{"amount": 30}]}'
            assert r.duration_ms == 123
            assert r.prompt_tokens == 10
            assert r.completion_tokens == 5
            assert r.total_tokens == 15
            assert r.client_ip == "127.0.0.1"
            assert r.error_message is None
    finally:
        app.dependency_overrides.clear()


def test_write_log_truncates_long_texts(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        with Session() as db:
            u = User(
                id="u-test-2",
                email="big@example.com",
                password_hash="x",
                is_admin=False,
                is_enabled=True,
                created_at=datetime.now(timezone.utc),
            )
            db.add(u)
            db.commit()

        write_ai_analysis_log(
            user_id="u-test-2",
            entry_type="parse_tx_text",
            status="ok",
            input_text="x" * 100_000,
            output_text="y" * 200_000,
        )

        with Session() as db:
            r = db.scalar(select(AIAnalysisLog))
            assert r is not None
            assert len(r.input_text) == 50_000
            assert len(r.output_text) == 100_000
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# 路由自动落日志
# ──────────────────────────────────────────────────────────────────────


def test_parse_tx_text_records_log_on_success(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token = _register(client, "ptx-ok@example.com")
        _seed_ai_config(Session, "ptx-ok@example.com")

        async def fake_call(**kwargs):
            return ChatJSONResult(
                parsed={"tx_drafts": [{"amount": 30, "note": "打车"}]},
                usage={"prompt_tokens": 8, "completion_tokens": 6, "total_tokens": 14},
            )

        monkeypatch.setattr("src.routers.ai.parse_tx_image.call_chat_json", fake_call)

        r = client.post(
            "/api/v1/ai/parse-tx-text",
            json={"text": "昨天打车 30 块", "locale": "zh"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200, r.text

        with Session() as db:
            log = db.scalar(select(AIAnalysisLog))
            assert log is not None
            assert log.entry_type == "parse_tx_text"
            assert log.status == "ok"
            assert log.input_text == "昨天打车 30 块"
            assert json.loads(log.output_text)["tx_drafts"][0]["amount"] == 30
            assert log.prompt_tokens == 8
            assert log.total_tokens == 14
            assert log.provider_id == "zhipu_glm"
    finally:
        app.dependency_overrides.clear()


def test_parse_tx_text_records_log_on_provider_error(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token = _register(client, "ptx-err@example.com")
        _seed_ai_config(Session, "ptx-err@example.com")

        async def fake_call_fails(**kwargs):
            from src.services.ai import ChatProviderError
            raise ChatProviderError("provider returned 401: invalid api_key")

        monkeypatch.setattr("src.routers.ai.parse_tx_image.call_chat_json", fake_call_fails)

        r = client.post(
            "/api/v1/ai/parse-tx-text",
            json={"text": "昨天打车 30 块", "locale": "zh"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 502, r.text

        with Session() as db:
            log = db.scalar(select(AIAnalysisLog))
            assert log is not None
            assert log.status == "error"
            assert log.input_text == "昨天打车 30 块"
            assert "401" in log.error_message
            assert log.output_text is None
    finally:
        app.dependency_overrides.clear()


def test_ask_records_log_with_concatenated_output(monkeypatch, tmp_path) -> None:
    """SSE 流完成后落日志:输出 = chunks 拼接全文。"""
    Session = _bootstrap(monkeypatch)
    try:
        # 造假索引(复用 test_ai_ask 手法)
        from src.config import get_settings
        db_path = tmp_path / "docs-index.zh.sqlite"
        conn = sqlite3.connect(db_path)
        conn.executescript(
            """
            CREATE TABLE chunks (
                id INTEGER PRIMARY KEY, content TEXT NOT NULL, doc_path TEXT NOT NULL,
                doc_title TEXT, section TEXT, url TEXT, vector BLOB NOT NULL
            );
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            """
        )
        rng = np.random.default_rng(1)
        dim = 8
        conn.execute(
            "INSERT INTO chunks (id, content, doc_path, doc_title, section, url, vector)"
            " VALUES (?,?,?,?,?,?,?)",
            (1, "Ask about 2FA", "docs/2fa.md", "2FA", None, "https://x/docs/2fa",
             rng.standard_normal(dim).astype(np.float32).tobytes()),
        )
        conn.execute("INSERT INTO meta VALUES ('dim', ?)", (str(dim),))
        conn.commit()
        conn.close()
        monkeypatch.setattr(docs_index_module, "_DATA_DIR", tmp_path)
        monkeypatch.setattr(get_settings(), "embedding_api_key", "fake-server-key")

        async def fake_embed(query):
            return [0.1] * 8

        async def fake_stream(*, config, messages, timeout=30.0):
            yield "在"
            yield "个人资料页"
            yield "点开 2FA。"

        monkeypatch.setattr("src.routers.ai.ask.embed_query", fake_embed)
        monkeypatch.setattr("src.routers.ai.ask.stream_chat_completion", fake_stream)

        client = TestClient(app)
        token = _register(client, "ask-log@example.com")
        _seed_ai_config(Session, "ask-log@example.com")

        r = client.post(
            "/api/v1/ai/ask",
            json={"query": "怎么开 2FA", "locale": "zh"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200, r.text

        with Session() as db:
            log = db.scalar(select(AIAnalysisLog))
            assert log is not None
            assert log.entry_type == "ask"
            assert log.status == "ok"
            assert log.input_text == "怎么开 2FA"
            assert log.output_text == "在个人资料页点开 2FA。"
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# 查询 endpoint(用户)
# ──────────────────────────────────────────────────────────────────────


def _seed_logs(Session, email: str) -> None:
    with Session() as db:
        uid = db.scalar(select(User.id).where(User.email == email))
        db.add(AIAnalysisLog(
            user_id=uid, entry_type="ask", status="ok", provider_id="zhipu_glm",
            model="glm-4-flash", input_text="怎么开 2FA", output_text="个人资料页",
            duration_ms=100, called_at=datetime.now(timezone.utc),
        ))
        db.add(AIAnalysisLog(
            user_id=uid, entry_type="parse_tx_text", status="error",
            input_text="昨天打车 30", output_text='{"x": "y"*10}',
            error_message="provider 401", duration_ms=50,
            called_at=datetime.now(timezone.utc),
        ))
        db.commit()


def test_list_logs_filters_and_preview(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token = _register(client, "list@example.com")
        _seed_logs(Session, "list@example.com")

        r = client.get(
            "/api/v1/ai/logs",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["total"] == 2
        assert body["items"][0]["entry_type"] == "parse_tx_text"  # called_at 倒序
        for it in body["items"]:
            assert "+00:00" in it["called_at"] or it["called_at"].endswith("Z")
            assert "input_preview" in it

        # entry_type 过滤
        r2 = client.get(
            "/api/v1/ai/logs?entry_type=ask",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r2.json()["total"] == 1
        assert r2.json()["items"][0]["entry_type"] == "ask"

        # status 过滤
        r3 = client.get(
            "/api/v1/ai/logs?status=error",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r3.json()["total"] == 1
        assert r3.json()["items"][0]["status"] == "error"
    finally:
        app.dependency_overrides.clear()


def test_detail_own_fulltext_others_404(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token_a = _register(client, "detail-a@example.com")
        token_b = _register(client, "detail-b@example.com")
        with Session() as db:
            uid_a = db.scalar(select(User.id).where(User.email == "detail-a@example.com"))
            row = AIAnalysisLog(
                user_id=uid_a, entry_type="parse_tx_text", status="ok",
                input_text="全文输入", output_text="全文输出",
                duration_ms=1, called_at=datetime.now(timezone.utc),
            )
            db.add(row)
            db.commit()
            log_id = row.id

        # 本人 → 全文
        r = client.get(
            f"/api/v1/ai/logs/{log_id}",
            headers={"Authorization": f"Bearer {token_a}"},
        )
        assert r.status_code == 200
        detail = r.json()
        assert detail["input_text"] == "全文输入"
        assert detail["output_text"] == "全文输出"

        # 他人 → 404(不泄露存在性)
        r2 = client.get(
            f"/api/v1/ai/logs/{log_id}",
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert r2.status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_list_logs_user_isolation(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token_a = _register(client, "iso-a@example.com")
        token_b = _register(client, "iso-b@example.com")
        _seed_logs(Session, "iso-a@example.com")

        r = client.get(
            "/api/v1/ai/logs",
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert r.status_code == 200
        assert r.json() == {"total": 0, "items": []}

        r2 = client.get(
            "/api/v1/ai/logs",
            headers={"Authorization": f"Bearer {token_a}"},
        )
        assert r2.json()["total"] == 2
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# POST /ai/logs — App 端 AI 调用上报
# ──────────────────────────────────────────────────────────────────────


def test_self_report_endpoints_removed(monkeypatch) -> None:
    """App 自报日志通道已随「LLM 经服务端中转」改造删除:POST /ai/logs 与
    POST /ai/logs/image 不再存在(405;路径被 GET 覆盖,不是 404)。"""
    _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token = _register(client, "report-gone@example.com")
        headers = {"Authorization": f"Bearer {token}"}

        r = client.post(headers=headers, json={}, url="/api/v1/ai/logs")
        assert r.status_code == 405
        r2 = client.post(
            headers=headers,
            url="/api/v1/ai/logs/image",
            files={"image": ("x.jpg", b"xx", "image/jpeg")},
            data={"entry_type": "parse_tx_image", "status": "ok"},
        )
        assert r2.status_code == 405

        # 查询端点不受影响
        r3 = client.get("/api/v1/ai/logs", headers=headers)
        assert r3.status_code == 200
        assert r3.json() == {"total": 0, "items": []}
    finally:
        app.dependency_overrides.clear()


def test_prune_retention_removes_old_mcp_logs(monkeypatch) -> None:
    """自动清理仅剩 mcp_call_logs(30 天):超期行删,保留期内的不动。"""
    Session = _bootstrap(monkeypatch)
    try:
        import src.main as main_module
        from src.main import _prune_retention_logs

        monkeypatch.setattr(main_module, "SessionLocal", Session)

        with Session() as db:
            db.add(User(
                id="u-prune-mcp", email="prune-mcp@example.com", password_hash="x",
                is_admin=False, is_enabled=True, created_at=datetime.now(timezone.utc),
            ))
            db.add(MCPCallLog(
                user_id="u-prune-mcp", tool_name="get_transactions", status="ok",
                called_at=datetime.now(timezone.utc) - timedelta(days=35),
            ))
            db.add(MCPCallLog(
                user_id="u-prune-mcp", tool_name="get_transactions", status="ok",
                called_at=datetime.now(timezone.utc),
            ))
            db.commit()

        _prune_retention_logs()

        with Session() as db:
            rows = db.scalars(select(MCPCallLog)).all()
            assert len(rows) == 1
            # SQLite 读回 naive,不能用 tz-aware 的 now 直接比
            assert rows[0].called_at >= datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(days=1)
    finally:
        app.dependency_overrides.clear()


def test_prune_retention_keeps_ai_logs_forever(monkeypatch, tmp_path) -> None:
    """AI 日志不设保留期限:自动清理跑一次,超期旧行 + 其落盘图片原样保留。"""
    Session = _bootstrap(monkeypatch)
    try:
        import src.main as main_module
        from src.main import _prune_retention_logs

        monkeypatch.setattr(main_module, "SessionLocal", Session)

        old_img = tmp_path / "old.jpg"
        old_img.write_bytes(b"old")
        with Session() as db:
            db.add(User(
                id="u-prune-ai", email="prune-ai@example.com", password_hash="x",
                is_admin=False, is_enabled=True, created_at=datetime.now(timezone.utc),
            ))
            db.add(AIAnalysisLog(
                user_id="u-prune-ai", entry_type="parse_tx_image", status="ok",
                image_path=str(old_img), image_mime="image/jpeg",
                called_at=datetime.now(timezone.utc) - timedelta(days=365),
            ))
            db.commit()

        _prune_retention_logs()

        with Session() as db:
            rows = db.scalars(select(AIAnalysisLog)).all()
            assert len(rows) == 1  # 一年前的记录完好无损
        assert old_img.exists()
    finally:
        app.dependency_overrides.clear()


def test_delete_log_removes_row_and_image(monkeypatch, tmp_path) -> None:
    """DELETE /ai/logs/{id}:本人删除行 + 落盘图片;他人 / 不存在 404。"""
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token_a = _register(client, "del-a@example.com")
        token_b = _register(client, "del-b@example.com")

        img = tmp_path / "shot.jpg"
        img.write_bytes(b"img-bytes")
        with Session() as db:
            uid_a = db.scalar(select(User.id).where(User.email == "del-a@example.com"))
            db.add(AIAnalysisLog(
                user_id=uid_a, entry_type="parse_tx_image", status="ok",
                image_path=str(img), image_mime="image/jpeg",
                called_at=datetime.now(timezone.utc),
            ))
            db.commit()
            log_id = db.scalar(select(AIAnalysisLog.id))

        # 他人删 → 404(不泄露存在性),行和数据都不动
        r = client.delete(
            f"/api/v1/ai/logs/{log_id}",
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert r.status_code == 404
        assert img.exists()

        # 本人删 → 200,行 + 图片都没了
        r2 = client.delete(
            f"/api/v1/ai/logs/{log_id}",
            headers={"Authorization": f"Bearer {token_a}"},
        )
        assert r2.status_code == 200, r2.text
        assert r2.json() == {"ok": True}
        with Session() as db:
            assert db.scalar(select(AIAnalysisLog)) is None
        assert not img.exists()

        # 不存在 → 404
        r3 = client.delete(
            f"/api/v1/ai/logs/{log_id}",
            headers={"Authorization": f"Bearer {token_a}"},
        )
        assert r3.status_code == 404

        # 无图记录照样删(直接走写入函数 seed —— 自报接口已删)
        write_ai_analysis_log(
            user_id=uid_a, entry_type="ask", status="ok", output_text="hi",
        )
        with Session() as db:
            text_log_id = db.scalar(select(AIAnalysisLog.id))
        r5 = client.delete(
            f"/api/v1/ai/logs/{text_log_id}",
            headers={"Authorization": f"Bearer {token_a}"},
        )
        assert r5.status_code == 200
        with Session() as db:
            assert db.scalar(select(AIAnalysisLog)) is None
    finally:
        app.dependency_overrides.clear()


def test_batch_delete_removes_own_logs_only(monkeypatch, tmp_path) -> None:
    """批量删除:只删本人的 id,跳过他人/不存在;删行顺带删图;id 去重;
    空 ids / 超 200 → 422;未登录 → 401。"""
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token_a = _register(client, "bd-a@example.com")
        _register(client, "bd-b@example.com")

        img = tmp_path / "a-img.jpg"
        img.write_bytes(b"img-bytes")
        with Session() as db:
            uid_a = db.scalar(select(User.id).where(User.email == "bd-a@example.com"))
            uid_b = db.scalar(select(User.id).where(User.email == "bd-b@example.com"))
            db.add(AIAnalysisLog(
                user_id=uid_a, entry_type="parse_tx_image", status="ok",
                image_path=str(img), image_mime="image/jpeg",
                called_at=datetime.now(timezone.utc),
            ))
            db.add(AIAnalysisLog(
                user_id=uid_a, entry_type="ask", status="ok", output_text="hi",
                called_at=datetime.now(timezone.utc),
            ))
            db.add(AIAnalysisLog(
                user_id=uid_b, entry_type="ask", status="ok", output_text="b",
                called_at=datetime.now(timezone.utc),
            ))
            db.commit()
            ids_a = db.scalars(
                select(AIAnalysisLog.id).where(AIAnalysisLog.user_id == uid_a).order_by(
                    AIAnalysisLog.id
                )
            ).all()
            id_b = db.scalar(select(AIAnalysisLog.id).where(AIAnalysisLog.user_id == uid_b))

        # 自己的 2 条(1 条重复传)+ 他人 1 条 + 不存在 1 条 → 只删自己的
        r = client.post(
            "/api/v1/ai/logs/batch-delete",
            headers={"Authorization": f"Bearer {token_a}"},
            json={"ids": [ids_a[0], ids_a[1], ids_a[0], id_b, 99999]},
        )
        assert r.status_code == 200, r.text
        assert r.json() == {"deleted": 2}

        with Session() as db:
            remaining = db.scalars(select(AIAnalysisLog)).all()
            assert [row.id for row in remaining] == [id_b]  # B 的还在
        assert not img.exists()  # A 的用户图删了

        # 空 ids → 422
        r2 = client.post(
            "/api/v1/ai/logs/batch-delete",
            headers={"Authorization": f"Bearer {token_a}"},
            json={"ids": []},
        )
        assert r2.status_code == 422

        # 超 200 → 422
        r3 = client.post(
            "/api/v1/ai/logs/batch-delete",
            headers={"Authorization": f"Bearer {token_a}"},
            json={"ids": list(range(1, 202))},
        )
        assert r3.status_code == 422

        # 未登录 → 401
        r4 = client.post(
            "/api/v1/ai/logs/batch-delete",
            json={"ids": [id_b]},
        )
        assert r4.status_code == 401
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# admin 查询
# ──────────────────────────────────────────────────────────────────────


def _make_admin(Session, email: str) -> None:
    with Session() as db:
        u = db.scalar(select(User).where(User.email == email))
        u.is_admin = True
        db.commit()


def test_admin_list_and_detail(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    try:
        client = TestClient(app)
        token_admin = _register(client, "admin@example.com")
        token_user = _register(client, "admin-subject@example.com")
        _make_admin(Session, "admin@example.com")
        _seed_logs(Session, "admin-subject@example.com")

        # 非 admin → 403
        r0 = client.get(
            "/api/v1/admin/ai-analysis-logs",
            headers={"Authorization": f"Bearer {token_user}"},
        )
        assert r0.status_code == 403, r0.text

        # admin 全局
        r = client.get(
            "/api/v1/admin/ai-analysis-logs",
            headers={"Authorization": f"Bearer {token_admin}"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["total"] == 2
        assert body["items"][0]["user_email"] == "admin-subject@example.com"
        assert body["items"][0]["input_preview"] is not None

        # admin 单条详情(任意用户全文)
        log_id = body["items"][0]["id"]
        r2 = client.get(
            f"/api/v1/admin/ai-analysis-logs/{log_id}",
            headers={"Authorization": f"Bearer {token_admin}"},
        )
        assert r2.status_code == 200
        detail = r2.json()
        assert detail["input_text"] in ("怎么开 2FA", "昨天打车 30")
        assert detail["user_email"] == "admin-subject@example.com"
    finally:
        app.dependency_overrides.clear()


# ──────────────────────────────────────────────────────────────────────
# 账户 hint(需求B)
# ──────────────────────────────────────────────────────────────────────


def test_format_accounts_hint_includes_type_bank_last_four() -> None:
    accounts = [
        ("工资卡", "CNY", "bank_card", "招商银行", "1234"),
        ("信用卡A", "CNY", "credit_card", None, None),
        ("美元账户", "USD", "cash", None, None),
    ]
    s = _format_accounts_hint(accounts, "CNY", is_zh=True)
    assert "工资卡(银行卡·招商银行·尾号1234)" in s
    assert "信用卡A(信用卡)" in s
    assert "美元账户(USD·现金)" in s  # 外币标币种,类型照标


def test_format_accounts_hint_empty() -> None:
    assert _format_accounts_hint([], "CNY") == "(none — leave account_name empty for user to pick)"
