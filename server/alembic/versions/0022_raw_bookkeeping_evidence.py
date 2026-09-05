"""add display-only raw bookkeeping evidence

Revision ID: 0022_raw_bookkeeping_evidence
Revises: 0021_ai_log_image
Create Date: 2026-09-05
"""

import sqlalchemy as sa
from alembic import op

revision = "0022_raw_bookkeeping_evidence"
down_revision = "0021_ai_log_image"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "raw_bookkeeping_evidence",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("ledger_id", sa.String(128), nullable=True),
        sa.Column("event_key", sa.String(255), nullable=False),
        sa.Column("source", sa.String(32), nullable=False),
        sa.Column("source_channel", sa.String(128), nullable=True),
        sa.Column("external_id", sa.String(255), nullable=True),
        sa.Column("content_hash", sa.String(128), nullable=True),
        sa.Column("actor", sa.String(255), nullable=True),
        sa.Column("title", sa.Text(), nullable=True),
        sa.Column("body", sa.Text(), nullable=True),
        sa.Column("metadata_json", sa.JSON(), nullable=False, server_default=sa.text("'{}'")),
        sa.Column("captured_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.UniqueConstraint("user_id", "event_key", name="uq_raw_evidence_user_event"),
    )
    op.create_index("ix_raw_bookkeeping_evidence_user_id", "raw_bookkeeping_evidence", ["user_id"])
    op.create_index("ix_raw_bookkeeping_evidence_ledger_id", "raw_bookkeeping_evidence", ["ledger_id"])
    op.create_index("ix_raw_bookkeeping_evidence_source", "raw_bookkeeping_evidence", ["source"])
    op.create_index("ix_raw_bookkeeping_evidence_captured_at", "raw_bookkeeping_evidence", ["captured_at"])
    op.create_index("ix_raw_bookkeeping_evidence_expires_at", "raw_bookkeeping_evidence", ["expires_at"])
    op.create_index("ix_raw_evidence_user_captured", "raw_bookkeeping_evidence", ["user_id", "captured_at"])


def downgrade() -> None:
    op.drop_index("ix_raw_evidence_user_captured", table_name="raw_bookkeeping_evidence")
    op.drop_index("ix_raw_bookkeeping_evidence_expires_at", table_name="raw_bookkeeping_evidence")
    op.drop_index("ix_raw_bookkeeping_evidence_captured_at", table_name="raw_bookkeeping_evidence")
    op.drop_index("ix_raw_bookkeeping_evidence_source", table_name="raw_bookkeeping_evidence")
    op.drop_index("ix_raw_bookkeeping_evidence_ledger_id", table_name="raw_bookkeeping_evidence")
    op.drop_index("ix_raw_bookkeeping_evidence_user_id", table_name="raw_bookkeeping_evidence")
    op.drop_table("raw_bookkeeping_evidence")
