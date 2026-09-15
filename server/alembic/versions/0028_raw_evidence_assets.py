"""原始证据媒体资源表(M6-6)

Revision ID: 0027_raw_evidence_assets
Revises: 0026_raw_evidence_transaction_links
Create Date: 2026-09-08
"""

import sqlalchemy as sa
from alembic import op

revision = "0027_raw_evidence_assets"
down_revision = "0026_raw_evidence_transaction_links"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "raw_evidence_assets",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "evidence_id",
            sa.String(36),
            sa.ForeignKey("raw_bookkeeping_evidence.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("kind", sa.String(16), nullable=False, server_default="image"),
        sa.Column("mime_type", sa.String(64), nullable=False),
        sa.Column("storage_path", sa.String(512), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("width", sa.Integer(), nullable=True),
        sa.Column("height", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("evidence_id", "sha256", name="uq_raw_evidence_asset_sha"),
    )
    op.create_index(
        "ix_raw_evidence_asset_evidence_time",
        "raw_evidence_assets",
        ["evidence_id", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_raw_evidence_asset_evidence_time", table_name="raw_evidence_assets")
    op.drop_table("raw_evidence_assets")
