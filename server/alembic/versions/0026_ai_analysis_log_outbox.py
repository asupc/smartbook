"""AI 日志可靠 outbox 表 + ai_analysis_logs.source_outbox_id(M6-5)

Revision ID: 0025_ai_analysis_log_outbox
Revises: 0024_tx_created_at
Create Date: 2026-09-08
"""

import sqlalchemy as sa
from alembic import op

revision = "0025_ai_analysis_log_outbox"
down_revision = "0024_tx_created_at"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 可靠 outbox 主表:请求先持久化 enqueue,worker 异步按 claim/lease 归档。
    op.create_table(
        "ai_analysis_log_outbox",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "user_id",
            sa.String(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("payload_json", sa.Text(), nullable=False),
        sa.Column("image_spool_path", sa.String(512), nullable=True),
        sa.Column("image_mime", sa.String(64), nullable=True),
        sa.Column("state", sa.String(16), nullable=False, server_default="pending"),
        sa.Column("attempt_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("lease_owner", sa.String(64), nullable=True),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_ai_log_outbox_state_attempt",
        "ai_analysis_log_outbox",
        ["state", "next_attempt_at", "created_at"],
    )
    op.create_index(
        "ix_ai_log_outbox_user_time",
        "ai_analysis_log_outbox",
        ["user_id", "created_at"],
    )

    # 最终日志指向来源 outbox(worker 重试防重复)。唯一约束必须走 batch 模式:
    # SQLite 不支持 ALTER TABLE 加约束(会走 copy-and-move 重建),PG 上仍是原生 ALTER。
    with op.batch_alter_table("ai_analysis_logs") as batch_op:
        batch_op.add_column(sa.Column("source_outbox_id", sa.String(36), nullable=True))
        batch_op.create_unique_constraint(
            "uq_ai_logs_source_outbox", ["source_outbox_id"]
        )


def downgrade() -> None:
    with op.batch_alter_table("ai_analysis_logs") as batch_op:
        batch_op.drop_constraint("uq_ai_logs_source_outbox", type_="unique")
        batch_op.drop_column("source_outbox_id")
    op.drop_index("ix_ai_log_outbox_user_time", table_name="ai_analysis_log_outbox")
    op.drop_index("ix_ai_log_outbox_state_attempt", table_name="ai_analysis_log_outbox")
    op.drop_table("ai_analysis_log_outbox")
