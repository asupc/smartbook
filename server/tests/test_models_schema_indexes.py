"""P1-A6 —— models.py 与 alembic 0029/0030 的索引一致性。

3 个热索引此前只在迁移里,models.py 无定义 → 测试库 `Base.metadata.create_all`
建的 schema 与生产不一致。现在补进 models;这里 create_all 后直接查
sqlite_master 断言 3 个索引存在,且表达式索引的 SQL 与迁移逐字对齐
(SQLite/PG 的表达式索引都按逐字匹配命中)。
"""
from __future__ import annotations

from sqlalchemy import create_engine, text
from sqlalchemy.pool import StaticPool

from src.database import Base


def test_hot_indexes_present_after_create_all():
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)
    try:
        with engine.connect() as conn:
            rows = conn.execute(
                text("SELECT name, sql FROM sqlite_master WHERE type = 'index'")
            ).all()
    finally:
        engine.dispose()
    by_name = {name: (sql or "") for name, sql in rows}

    # 0029: user-scope LWW(/sync/push 的 user-global 实体取最新一条)
    sql = by_name.get("idx_sync_changes_user_scope_entity_latest")
    assert sql is not None, by_name.keys()
    assert "change_id DESC" in sql

    # 0029: /workspace/transactions 的 created_at 排序(表达式索引)
    sql = by_name.get("ix_read_tx_ledger_created")
    assert sql is not None, by_name.keys()
    assert "coalesce(created_at, happened_at) DESC" in sql

    # 0030: 回收站列表按删除时间倒序
    sql = by_name.get("ix_read_tx_deleted_at")
    assert sql is not None, by_name.keys()
    assert "deleted_at DESC" in sql
