"""M6-5 AI 日志可靠 outbox — 原子入队 + 失败 fallback 测试。

覆盖:
- enqueue_ai_analysis_log 落 pending 行(独立 Session),commit 后返回;
- 开关关闭时直接走同步 writer(不落 outbox);
- 入队失败 fallback 到同步 writer(不丢日志);
- 带图入队:spool `.tmp` → 原子 rename `.ready`,outbox 行指向 `.ready`;
- 图片 mime 不在白名单时 spool_path 为 null(行照常入队)。
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from src.database import Base
from src.models import AIAnalysisLog, AIAnalysisLogOutbox, User
from src.services.ai import analysis_log as analysis_log_module
from src.services.ai import analysis_log_outbox as outbox_module
from src.services.ai.analysis_log_outbox import (
    enqueue_ai_analysis_log,
    enqueue_ai_analysis_log_with_image,
)


def _settings(enabled: bool, spool_dir: str):
    from src.config import Settings

    s = Settings(
        DATA_DIR="./data-test",
        AI_LOG_OUTBOX_ENABLED=enabled,
        AI_LOG_SPOOL_DIR=spool_dir,
    )
    return s


def _bootstrap(monkeypatch, enabled: bool = True, spool_dir: str | None = None):
    """内存 sqlite + 替换 outbox / analysis_log 的 SessionLocal 与 get_settings。"""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    # get_settings 是 lru_cache,直接 monkeypatch 模块内的引用。
    s = _settings(enabled, spool_dir or "./data-test/ai-log-spool")
    monkeypatch.setattr(outbox_module, "get_settings", lambda: s)
    monkeypatch.setattr(outbox_module, "SessionLocal", Session)
    # fallback 要写真实日志表,复用同一 Session(同引擎)。
    monkeypatch.setattr(analysis_log_module, "SessionLocal", Session)

    with Session() as db:
        db.add(User(
            id="u-outbox", email="outbox@example.com", password_hash="x",
            is_admin=False, is_enabled=True, created_at=datetime.now(timezone.utc),
        ))
        db.commit()
    return Session


def test_enqueue_persists_pending_row(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)
    enqueue_ai_analysis_log(
        user_id="u-outbox", entry_type="chat", status="ok",
        provider_id="zhipu_glm", model="glm-4-flash",
        input_text="你好", output_text="你好呀",
    )

    with Session() as db:
        row = db.scalar(select(AIAnalysisLogOutbox))
        assert row is not None
        assert row.state == "pending"
        assert row.attempt_count == 0
        assert row.image_spool_path is None
        assert row.payload_json is not None
    # 最终日志尚未落(等 worker) —— 关键:入队 ≠ 落最终日志
    with Session() as db:
        assert db.scalar(select(AIAnalysisLog)) is None


def test_enqueue_truncates_payload(monkeypatch) -> None:
    import json

    Session = _bootstrap(monkeypatch)
    enqueue_ai_analysis_log(
        user_id="u-outbox", entry_type="chat", status="ok",
        input_text="x" * 100_000, output_text="y" * 200_000,
    )
    with Session() as db:
        row = db.scalar(select(AIAnalysisLogOutbox))
        payload = json.loads(row.payload_json)
        assert len(payload["input_text"]) == 50_000
        assert len(payload["output_text"]) == 100_000


def test_enqueue_disabled_falls_back_to_sync_writer(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch, enabled=False)
    enqueue_ai_analysis_log(
        user_id="u-outbox", entry_type="chat", status="ok", output_text="hi",
    )
    with Session() as db:
        assert db.scalar(select(AIAnalysisLogOutbox)) is None
        assert db.scalar(select(AIAnalysisLog)) is not None


def test_enqueue_failure_falls_back_to_sync_writer(monkeypatch) -> None:
    Session = _bootstrap(monkeypatch)

    def fail_insert(**kwargs):
        raise RuntimeError("db down")

    monkeypatch.setattr(outbox_module, "_insert_outbox_row", fail_insert)

    # outbox 入队失败 → fallback 同步写最终日志,不丢
    enqueue_ai_analysis_log(
        user_id="u-outbox", entry_type="chat", status="ok", output_text="hi",
    )
    with Session() as db:
        assert db.scalar(select(AIAnalysisLog)) is not None


def test_enqueue_with_image_stages_spool(monkeypatch, tmp_path) -> None:
    spool = tmp_path / "spool"
    Session = _bootstrap(monkeypatch, spool_dir=str(spool))

    enqueue_ai_analysis_log_with_image(
        user_id="u-outbox", entry_type="parse_tx_image", status="ok",
        image_bytes=b"fake-jpeg-bytes", image_mime="image/jpeg",
        input_text="截图", output_text='{"amount": 30}',
    )

    with Session() as db:
        row = db.scalar(select(AIAnalysisLogOutbox))
        assert row is not None
        assert row.image_mime == "image/jpeg"
        assert row.image_spool_path is not None
        assert row.image_spool_path.endswith(".ready")
        assert Path(row.image_spool_path).exists()
    # 没有残留 .tmp
    assert not list(spool.glob("*.tmp"))


def test_enqueue_with_image_bad_mime_no_spool(monkeypatch, tmp_path) -> None:
    spool = tmp_path / "spool"
    Session = _bootstrap(monkeypatch, spool_dir=str(spool))

    enqueue_ai_analysis_log_with_image(
        user_id="u-outbox", entry_type="parse_tx_image", status="ok",
        image_bytes=b"xx", image_mime="application/pdf",
        input_text="截图",
    )

    with Session() as db:
        row = db.scalar(select(AIAnalysisLogOutbox))
        assert row is not None
        assert row.image_spool_path is None  # 白名单外不落 spool
    assert not list(spool.glob("*"))
