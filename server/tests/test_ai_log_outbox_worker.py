"""M6-5 AI 日志 worker — claim/lease + 幂等归档 + dead-letter 测试。

覆盖关键故障注入点(§7.10):
- 正常:入队 → drain_once → 最终日志落 + outbox 删除 + 图片归档;
- 幂等:source_outbox_id 唯一冲突时视为成功(不重复日志);
- dead:permanent 错误进入 dead,不忙循环;
- 并发:两个 worker claim 同一批,最终日志至多 1 条。
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
from src.services.ai import analysis_log_worker as worker_module
from src.services.ai.analysis_log_outbox import (
    enqueue_ai_analysis_log,
    enqueue_ai_analysis_log_with_image,
)
from src.services.ai.analysis_log_worker import drain_once


def _settings(spool_dir: str):
    from src.config import Settings

    # 图片归档目录与 spool 同盘(tmp_path),避免 os.replace 跨盘失败;生产同卷。
    image_dir = Path(spool_dir).parent / "images"
    return Settings(
        DATA_DIR="./data-test",
        AI_LOG_OUTBOX_ENABLED=True,
        AI_LOG_SPOOL_DIR=spool_dir,
        AI_LOG_IMAGE_DIR=str(image_dir),
    )


def _bootstrap(monkeypatch, tmp_path):
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autocommit=False, autoflush=False)

    s = _settings(str(tmp_path / "spool"))
    monkeypatch.setattr(outbox_module, "get_settings", lambda: s)
    monkeypatch.setattr(outbox_module, "SessionLocal", Session)
    monkeypatch.setattr(analysis_log_module, "SessionLocal", Session)
    monkeypatch.setattr(worker_module, "get_settings", lambda: s)
    monkeypatch.setattr(worker_module, "SessionLocal", Session)

    with Session() as db:
        db.add(User(
            id="u-ow", email="ow@example.com", password_hash="x",
            is_admin=False, is_enabled=True, created_at=datetime.now(timezone.utc),
        ))
        db.commit()
    return Session


def test_drain_success_persists_final_log(monkeypatch, tmp_path) -> None:
    Session = _bootstrap(monkeypatch, tmp_path)
    enqueue_ai_analysis_log(
        user_id="u-ow", entry_type="chat", status="ok",
        provider_id="zhipu_glm", output_text="hello", input_text="hi",
    )

    stats = drain_once()
    assert stats["success"] == 1
    assert stats["claimed"] == 1

    with Session() as db:
        log = db.scalar(select(AIAnalysisLog))
        assert log is not None
        assert log.status == "ok"
        assert log.source_outbox_id is not None
        # outbox 行已删
        assert db.scalar(select(AIAnalysisLogOutbox)) is None

def test_drain_with_image_archives_final(monkeypatch, tmp_path) -> None:
    Session = _bootstrap(monkeypatch, tmp_path)
    enqueue_ai_analysis_log_with_image(
        user_id="u-ow", entry_type="parse_tx_image", status="ok",
        image_bytes=b"fake-jpeg", image_mime="image/jpeg",
        input_text="截图", output_text="{}",
    )

    stats = drain_once()
    assert stats["success"] == 1

    with Session() as db:
        log = db.scalar(select(AIAnalysisLog))
        assert log is not None
        assert log.image_path is not None
        assert log.image_path.endswith(".jpg")
        assert Path(log.image_path).exists()
        # spool 已清空
    assert not list((tmp_path / "spool").glob("*"))


def test_drain_idempotent_when_final_already_exists(monkeypatch, tmp_path) -> None:
    """重试:已有 final 日志(source_outbox_id 唯一冲突)→ 视为成功,不重复写。"""
    Session = _bootstrap(monkeypatch, tmp_path)
    enqueue_ai_analysis_log(
        user_id="u-ow", entry_type="chat", status="ok", output_text="once",
    )

    with Session() as db:
        row = db.scalar(select(AIAnalysisLogOutbox))
        outbox_id = row.id

    # 模拟第一次已写最终日志(但 outbox 未删,如崩溃于 delete 前)
    with Session() as db:
        db.add(AIAnalysisLog(
            user_id="u-ow", entry_type="chat", status="ok", output_text="once",
            source_outbox_id=outbox_id, called_at=datetime.now(timezone.utc),
        ))
        db.commit()

    stats = drain_once()
    # 幂等成功:最终日志仍只有 1 条
    assert stats["success"] == 1
    with Session() as db:
        logs = db.scalars(select(AIAnalysisLog)).all()
        assert len(logs) == 1
        assert db.scalar(select(AIAnalysisLogOutbox)) is None


def test_drain_permanent_error_goes_dead(monkeypatch, tmp_path) -> None:
    Session = _bootstrap(monkeypatch, tmp_path)
    enqueue_ai_analysis_log(
        user_id="u-ow", entry_type="chat", status="ok", output_text="boom",
    )

    def fail_archive(spool_path, outbox_id, image_mime):
        raise RuntimeError("permanent: invalid mime config")

    monkeypatch.setattr(worker_module, "_archive_image", fail_archive)

    stats = drain_once()
    # 非瞬时 → dead
    assert stats["dead"] == 1
    with Session() as db:
        row = db.scalar(select(AIAnalysisLogOutbox))
        assert row.state == "dead"
        assert row.last_error is not None
    # 无最终日志
    with Session() as db:
        assert db.scalar(select(AIAnalysisLog)) is None


def test_drain_two_workers_no_duplicate_final(monkeypatch, tmp_path) -> None:
    """两个 worker 并发 claim 同一批,最终日志至多 1 条(lease 抢占 + 幂等)。"""
    Session = _bootstrap(monkeypatch, tmp_path)
    for i in range(3):
        enqueue_ai_analysis_log(
            user_id="u-ow", entry_type="chat", status="ok", output_text=f"m{i}",
        )
    # 模拟两个 owner 先后 drain,第二个因 lease 已被占而领不到
    stats1 = drain_once(owner="worker-A")
    stats2 = drain_once(owner="worker-B")
    with Session() as db:
        # 每 payload 至多 1 条最终日志
        logs = db.scalars(select(AIAnalysisLog)).all()
        assert len(logs) == len({l.output_text for l in logs})
        assert len(logs) == stats1["success"] + stats2["success"]
