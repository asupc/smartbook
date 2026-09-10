"""余额调整记录表(独立于交易,不进收支统计)

Revision ID: 0028_account_adjustment_records
Revises: 0027_raw_evidence_assets
Create Date: 2026-09-10

「调整余额」从「记一笔 exclude_from_stats 交易」改为独立的 ledger-scope 同步
实体 account_adjustment:不进收支统计/预算/分类排行,只参与账户余额与净资产。
存量调整交易不迁移(exclude 标记继续生效,口径一致)。
"""

import sqlalchemy as sa
from alembic import op

revision = "0028_account_adjustment_records"
down_revision = "0027_raw_evidence_assets"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "read_account_adjustment_projection",
        sa.Column("ledger_id", sa.String(36), primary_key=True),
        sa.Column("sync_id", sa.String(255), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=False, index=True),
        sa.Column("account_sync_id", sa.String(255), nullable=False, index=True),
        sa.Column("account_name", sa.Text(), nullable=True),
        sa.Column("amount", sa.Float(), nullable=False, server_default="0"),
        sa.Column("balance_before", sa.Float(), nullable=True),
        sa.Column("balance_after", sa.Float(), nullable=True),
        sa.Column("happened_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("created_by_user_id", sa.String(36), nullable=True),
        sa.Column("last_edited_by_user_id", sa.String(36), nullable=True),
        sa.Column(
            "source_change_id", sa.BigInteger(), nullable=False, server_default="0"
        ),
        sa.ForeignKeyConstraint(
            ["ledger_id"], ["ledgers.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], ondelete="CASCADE"
        ),
    )
    op.create_index(
        "ix_read_adj_ledger_time",
        "read_account_adjustment_projection",
        ["ledger_id", sa.text("happened_at DESC")],
    )
    op.create_index(
        "ix_read_adj_ledger_account",
        "read_account_adjustment_projection",
        ["ledger_id", "account_sync_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_read_adj_ledger_account", table_name="read_account_adjustment_projection"
    )
    op.drop_index(
        "ix_read_adj_ledger_time", table_name="read_account_adjustment_projection"
    )
    op.drop_table("read_account_adjustment_projection")
