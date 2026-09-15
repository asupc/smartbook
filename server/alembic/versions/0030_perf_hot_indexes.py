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


def _is_postgresql() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    if _is_postgresql():
        # PG:纯索引迁移用 CREATE INDEX CONCURRENTLY,避免锁表写(同步/记账
        # 高峰期普通 CREATE INDEX 会卡住所有写入)。CONCURRENTLY 不能在事务
        # 内跑 —— autocommit_block 先提交外层事务再以自动提交执行。
        # 注意:CONCURRENTLY 中途失败会留下 INVALID 索引,需手动
        # DROP INDEX <name> 后重跑本迁移(alembic 未打版本号)。
        with op.get_context().autocommit_block():
            op.execute(
                "CREATE INDEX CONCURRENTLY idx_sync_changes_user_scope_entity_latest "
                "ON sync_changes (user_id, scope, entity_type, entity_sync_id, "
                "change_id DESC)"
            )
            op.execute(
                "CREATE INDEX CONCURRENTLY ix_read_tx_ledger_created "
                "ON read_tx_projection (ledger_id, "
                "coalesce(created_at, happened_at) DESC)"
            )
    else:
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
    if _is_postgresql():
        # DROP INDEX CONCURRENTLY 同样不锁表写、不能在事务内,autocommit 执行。
        with op.get_context().autocommit_block():
            op.execute("DROP INDEX CONCURRENTLY IF EXISTS ix_read_tx_ledger_created")
            op.execute(
                "DROP INDEX CONCURRENTLY IF EXISTS "
                "idx_sync_changes_user_scope_entity_latest"
            )
    else:
        # if_exists:0031(downgrade 用 batch_alter_table 重建表)在 SQLite 上
        # 会连带丢掉表达式索引(反射看不到),先降 0031 再降本步时索引已不在
        # —— 显式 drop 会炸整条 downgrade 链。
        op.drop_index(
            "ix_read_tx_ledger_created",
            table_name="read_tx_projection",
            if_exists=True,
        )
        op.drop_index(
            "idx_sync_changes_user_scope_entity_latest",
            table_name="sync_changes",
            if_exists=True,
        )
