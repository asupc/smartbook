"""同步/读路径热查询索引补缺(性能审计 F10/F18)

Revision ID: 0029_perf_hot_indexes
Revises: 0028_account_adjustment_records
Create Date: 2026-09-10

两个缺口:
1. sync_changes 的 user-scope LWW 查询(/sync/push 对 user-global 实体按
   (user_id, scope, entity_type, entity_sync_id) 取最新一条)此前只有
   (user_id, scope, change_id) / (user_id, change_id) 索引,entity 过滤在
   索引之外 → 大 change 表上逐条倒扫。
2. /workspace/transactions 按 created_at 排序(0024 新列)无索引 → 全排序。
"""

import sqlalchemy as sa
from alembic import op

revision = "0029_perf_hot_indexes"
down_revision = "0028_account_adjustment_records"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # user-global LWW:覆盖 (user_id, scope, entity_type, entity_sync_id, change_id DESC)
    op.create_index(
        "idx_sync_changes_user_scope_entity_latest",
        "sync_changes",
        ["user_id", "scope", "entity_type", "entity_sync_id", sa.text("change_id DESC")],
    )
    # created_at 排序:表达式与 /workspace/transactions 的
    # coalesce(created_at, happened_at) 完全一致(SQLite/PG 表达式索引均按
    # 逐字匹配命中)。
    op.create_index(
        "ix_read_tx_ledger_created",
        "read_tx_projection",
        ["ledger_id", sa.text("coalesce(created_at, happened_at) DESC")],
    )


def downgrade() -> None:
    op.drop_index("ix_read_tx_ledger_created", table_name="read_tx_projection")
    op.drop_index(
        "idx_sync_changes_user_scope_entity_latest", table_name="sync_changes"
    )
