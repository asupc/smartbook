"""原始证据 ↔ 投影交易多对多关联表(M6-6)

Revision ID: 0026_raw_evidence_transaction_links
Revises: 0025_ai_analysis_log_outbox
Create Date: 2026-09-08
"""

import sqlalchemy as sa
from alembic import op

revision = "0026_raw_evidence_transaction_links"
down_revision = "0025_ai_analysis_log_outbox"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "raw_evidence_transaction_links",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "evidence_id",
            sa.String(36),
            sa.ForeignKey("raw_bookkeeping_evidence.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column(
            "user_id",
            sa.String(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("ledger_id", sa.String(128), nullable=False, index=True),
        sa.Column("transaction_sync_id", sa.String(255), nullable=False, index=True),
        sa.Column("event_item_index", sa.Integer(), nullable=True),
        sa.Column("link_source", sa.String(16), nullable=False, server_default="client"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint(
            "evidence_id", "ledger_id", "transaction_sync_id",
            name="uq_raw_evidence_tx_link",
        ),
    )
    op.create_index(
        "ix_raw_evidence_tx_link_user_time",
        "raw_evidence_transaction_links",
        ["user_id", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_raw_evidence_tx_link_user_time", table_name="raw_evidence_transaction_links")
    op.drop_table("raw_evidence_transaction_links")
