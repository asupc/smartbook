"""P1-A4 / P1-A5 / P1-B3 —— main.py 的 retention 任务与 AI outbox 接线单测。

- A4: `_prune_expired_trash`(每日任务本体)清掉软删超 30 天的交易,未到期不动;
- A5: `_prune_retention_logs` 清理过期 ai_analysis_logs(含落盘图片)与
  audit_logs,未过期保留;保留期 <= 0 时跳过;
- B3: `_start/_stop_ai_log_outbox_worker_task` —— 开关关时不建任务,
  开时先恢复 lease 再起 worker,stop_event 优雅关停且幂等。

startup/shutdown 的 on_event 集成测试不可行(TestClient 不带 with 上下文不触发
lifespan,带 with 会连带起 backup scheduler / MCP session manager 等全部
startup 副作用),故直接单测接线 helper 本体 —— 注册的 on_event handler 只是
透传调用它们。
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src import main
from src.database import Base
from src.models import (
    AIAnalysisLog,
    AuditLog,
    Ledger,
    MCPCallLog,
    ReadTxProjection,
    SyncChange,
    User,
)


def _mk_session_factory():
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)
    return sessionmaker(bind=engine, autocommit=False, autoflush=False)


def _mk_user_ledger(db) -> None:
    now = datetime.now(timezone.utc)
    db.add(User(id="u1", email="t@t.com", password_hash="x", created_at=now))
    db.add(Ledger(id="L1", external_id="lg1", name="T", currency="CNY",
                  user_id="u1", created_at=now))


# ─────────────────────── P1-A4: trash retention ───────────────────────


def test_prune_expired_trash_daily_task(monkeypatch):
    """每日任务:软删超 30 天的交易被物理清掉(连带 upsert 事件 compact),
    未到期 / 存活交易不动。"""
    Session = _mk_session_factory()
    with Session() as db:
        _mk_user_ledger(db)
        now = datetime.now(timezone.utc)
        db.add(ReadTxProjection(
            ledger_id="L1", sync_id="tx-expired", user_id="u1", tx_type="expense",
            amount=1.0, happened_at=now, deleted_at=now - timedelta(days=40),
        ))
        db.add(ReadTxProjection(
            ledger_id="L1", sync_id="tx-fresh", user_id="u1", tx_type="expense",
            amount=2.0, happened_at=now, deleted_at=now - timedelta(days=3),
        ))
        db.add(SyncChange(
            user_id="u1", ledger_id="L1", scope="ledger",
            entity_type="transaction", entity_sync_id="tx-expired",
            action="upsert", payload_json={},
            updated_at=datetime.now(timezone.utc),
        ))
        db.commit()

    monkeypatch.setattr(main, "SessionLocal", Session)
    main._prune_expired_trash()

    with Session() as db:
        assert db.get(ReadTxProjection, ("L1", "tx-expired")) is None
        assert db.get(ReadTxProjection, ("L1", "tx-fresh")) is not None
        # compact 语义由 test_tx_purge_compact_events 单独覆盖;这里至少确认
        # upsert 事件没有残留
        left = db.execute(
            select(SyncChange).where(SyncChange.entity_sync_id == "tx-expired")
        ).all()
        assert left == []


# ─────────────────────── P1-A5: log retention ───────────────────────


def _seed_logs(Session, tmp_path) -> dict[str, object]:
    now = datetime.now(timezone.utc)
    image_old = tmp_path / "old.png"
    image_old.write_bytes(b"old-image")
    image_keep = tmp_path / "keep.png"
    image_keep.write_bytes(b"keep-image")
    with Session() as db:
        _mk_user_ledger(db)
        db.add(AIAnalysisLog(
            user_id="u1", entry_type="parse_tx_image", status="ok",
            called_at=now - timedelta(days=100), image_path=str(image_old),
        ))
        db.add(AIAnalysisLog(
            user_id="u1", entry_type="chat", status="ok",
            called_at=now - timedelta(days=1), image_path=str(image_keep),
        ))
        db.add(AuditLog(
            user_id="u1", ledger_id="L1", action="tx_restore_from_trash",
            metadata_json={}, created_at=now - timedelta(days=200),
        ))
        db.add(AuditLog(
            user_id="u1", ledger_id="L1", action="tx_restore_from_trash",
            metadata_json={}, created_at=now - timedelta(days=5),
        ))
        db.add(MCPCallLog(
            user_id="u1", tool_name="list_transactions", status="ok",
            called_at=now - timedelta(days=40),
        ))
        db.commit()
    return {"image_old": image_old, "image_keep": image_keep}


def test_prune_retention_logs_ai_audit_mcp(monkeypatch, tmp_path):
    Session = _mk_session_factory()
    paths = _seed_logs(Session, tmp_path)
    monkeypatch.setattr(main, "SessionLocal", Session)
    monkeypatch.setattr(main.settings, "ai_log_retention_days", 30)
    monkeypatch.setattr(main.settings, "audit_log_retention_days", 60)

    main._prune_retention_logs()

    with Session() as db:
        ai = db.scalars(select(AIAnalysisLog)).all()
        assert len(ai) == 1 and ai[0].entry_type == "chat"
        audit = db.scalars(select(AuditLog)).all()
        assert len(audit) == 1 and audit[0].created_at is not None
        assert db.scalars(select(MCPCallLog)).all() == []
    # 过期日志的落盘图片连带删除;未过期保留
    assert not paths["image_old"].exists()
    assert paths["image_keep"].exists()


def test_prune_retention_logs_disabled_when_zero(monkeypatch, tmp_path):
    """保留期 <= 0 → 对应表跳过自动清理。"""
    Session = _mk_session_factory()
    paths = _seed_logs(Session, tmp_path)
    monkeypatch.setattr(main, "SessionLocal", Session)
    monkeypatch.setattr(main.settings, "ai_log_retention_days", 0)
    monkeypatch.setattr(main.settings, "audit_log_retention_days", 0)

    main._prune_retention_logs()

    with Session() as db:
        assert len(db.scalars(select(AIAnalysisLog)).all()) == 2
        assert len(db.scalars(select(AuditLog)).all()) == 2
        # mcp 是硬编码 30 天,不受开关影响
        assert db.scalars(select(MCPCallLog)).all() == []
    assert paths["image_old"].exists()


# ─────────────────────── P1-B3: outbox worker 接线 ───────────────────────


def test_outbox_wiring_disabled_creates_no_task(monkeypatch):
    async def scenario():
        monkeypatch.setattr(main.settings, "ai_log_outbox_enabled", False)
        await main._start_ai_log_outbox_worker_task(main.app)
        assert getattr(main.app.state, "ai_log_outbox_task", None) is None

    asyncio.run(scenario())


def test_outbox_wiring_start_recovers_leases_and_stops_clean(monkeypatch):
    from src.services.ai import analysis_log_worker

    calls = {"recover": 0, "worker": 0}
    stop_events = []

    def fake_recover():
        calls["recover"] += 1

    async def fake_worker(stop_event):
        calls["worker"] += 1
        stop_events.append(stop_event)
        await stop_event.wait()

    monkeypatch.setattr(main.settings, "ai_log_outbox_enabled", True)
    monkeypatch.setattr(analysis_log_worker, "recover_stale_leases", fake_recover)
    monkeypatch.setattr(analysis_log_worker, "run_worker_forever", fake_worker)

    async def scenario():
        await main._start_ai_log_outbox_worker_task(main.app)
        # create_task 只调度不执行,让一步 loop 使 worker 协程真正进入
        await asyncio.sleep(0)
        assert calls == {"recover": 1, "worker": 1}
        task = main.app.state.ai_log_outbox_task
        assert not task.done()
        # stop:置位 stop_event,worker 协程返回,task 完成;重复 stop 幂等
        await main._stop_ai_log_outbox_worker_task(main.app)
        assert task.done()
        assert stop_events[0].is_set()
        await main._stop_ai_log_outbox_worker_task(main.app)

    try:
        asyncio.run(scenario())
    finally:
        # 单例 app 上的 state 不泄漏给后续测试
        for attr in ("ai_log_outbox_task", "ai_log_outbox_stop"):
            if hasattr(main.app.state, attr):
                delattr(main.app.state, attr)
