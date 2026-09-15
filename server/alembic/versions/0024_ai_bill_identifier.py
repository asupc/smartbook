"""AI 账单唯一标识去重(中转识别前的 LLM 跳过)

Revision ID: 0023_ai_bill_identifier
Revises: 0022_raw_bookkeeping_evidence
Create Date: 2026-09-05
"""

import sqlalchemy as sa
from alembic import op

revision = "0023_ai_bill_identifier"
down_revision = "0022_raw_bookkeeping_evidence"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 已识别账单的唯一标识(订单号/交易号/流水号),按 user 隔离。
    # /ai/relay 在请求 LLM 前用新请求文本匹配这些标识,命中即判重复:
    # 记 ai_analysis_logs(dedup_hit)并返回 duplicate,不调 LLM。
    op.create_table(
        "ai_bill_identifiers",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("identifier", sa.String(64), nullable=False),
        sa.Column("source", sa.String(32), nullable=False),
        sa.Column("hit_count", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("first_seen_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "identifier", name="uq_ai_bill_identifier_user_key"),
    )
    op.create_index("ix_ai_bill_identifier_user_id", "ai_bill_identifiers", ["user_id"])
    op.create_index("ix_ai_bill_identifier_expires_at", "ai_bill_identifiers", ["expires_at"])

    # AI 调用日志:标记「识别前判重跳过」的行(无 LLM 调用发生)
    op.add_column("ai_analysis_logs", sa.Column("dedup_hit", sa.String(32), nullable=True))


def downgrade() -> None:
    op.drop_column("ai_analysis_logs", "dedup_hit")
    op.drop_index("ix_ai_bill_identifier_expires_at", table_name="ai_bill_identifiers")
    op.drop_index("ix_ai_bill_identifier_user_id", table_name="ai_bill_identifiers")
    op.drop_table("ai_bill_identifiers")
