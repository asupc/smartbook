"""users: drop 2FA (TOTP) columns

二次验证功能已整体移除(App / Web / server),删除 users 表上的 TOTP 三列。
生产环境已启用 2FA 的存量账号随本次升级自动关闭二次验证(列删除后
totp_enabled 逻辑不复存在,登录直接发 token)。

Revision ID: 0020_drop_2fa_totp
Revises: 0019_ai_analysis_logs
Create Date: 2026-09-03
"""

import sqlalchemy as sa
from alembic import op


revision = "0020_drop_2fa_totp"
down_revision = "0019_ai_analysis_logs"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_column("users", "totp_enabled_at")
    op.drop_column("users", "totp_enabled")
    op.drop_column("users", "totp_secret_encrypted")
    op.drop_table("recovery_codes")


def downgrade() -> None:
    op.create_table(
        "recovery_codes",
        sa.Column("id", sa.Integer(), autoincrement=True, primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False),
        sa.Column("code_hash", sa.String(64), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.add_column(
        "users", sa.Column("totp_secret_encrypted", sa.Text(), nullable=True)
    )
    op.add_column(
        "users",
        sa.Column("totp_enabled", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.add_column(
        "users",
        sa.Column("totp_enabled_at", sa.DateTime(timezone=True), nullable=True),
    )
