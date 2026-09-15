"""交易软删 + 回收站(误删安全网)

Revision ID: 0030_tx_soft_delete
Revises: 0029_perf_hot_indexes
Create Date: 2026-09-10

read_tx_projection 加 deleted_at 列:web/mobile 删除交易改写软删标记,
读投影/统计/导出统一过滤 deleted_at IS NULL;30 天后物理清理(连附件文件
与 upsert 事件 compact)—— 由 main.py 的每日 retention 任务自动执行
(data_cleanup scanner._scan_tx_trash_expired → cleaner),admin 也可经
/admin/data-cleanup 手动触发。回收站端点(读取/恢复/彻底删除)见
read/trash.py。附件物理 GC 从删除现场延后到「彻底删除/过期清理」时执行。
"""

import sqlalchemy as sa
from alembic import op

revision = "0030_tx_soft_delete"
down_revision = "0029_perf_hot_indexes"
branch_labels = None
depends_on = None


def _is_postgresql() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    # SQLite 兼容:普通列用 batch_alter_table(项目 0003/0006 先例)。
    # PG 下 autocommit_block(见下)会把本 ALTER 连同前面的隐式事务一起提交
    # —— 若后续建索引失败重跑,需先手动删掉 deleted_at 列(alembic 未打版本号)。
    with op.batch_alter_table("read_tx_projection") as batch:
        batch.add_column(
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True)
        )
    # 回收站列表按删除时间倒序;过滤条件 deleted_at IS NULL 与现有索引
    # 组合(ledger_id+time)选择性足够,不额外建部分索引。
    if _is_postgresql():
        # PG:索引部分用 CREATE INDEX CONCURRENTLY 避免锁表写(CONCURRENTLY
        # 不能在事务内,autocommit_block 提交外层事务后自动提交执行)。
        # 中途失败会留下 INVALID 索引,需 DROP INDEX ix_read_tx_deleted_at
        # 后重跑本迁移。
        with op.get_context().autocommit_block():
            op.execute(
                "CREATE INDEX CONCURRENTLY ix_read_tx_deleted_at "
                "ON read_tx_projection (user_id, deleted_at DESC)"
            )
    else:
        op.create_index(
            "ix_read_tx_deleted_at",
            "read_tx_projection",
            ["user_id", sa.text("deleted_at DESC")],
        )


def downgrade() -> None:
    if _is_postgresql():
        with op.get_context().autocommit_block():
            op.execute("DROP INDEX CONCURRENTLY IF EXISTS ix_read_tx_deleted_at")
    else:
        op.drop_index("ix_read_tx_deleted_at", table_name="read_tx_projection")
    with op.batch_alter_table("read_tx_projection") as batch:
        batch.drop_column("deleted_at")
