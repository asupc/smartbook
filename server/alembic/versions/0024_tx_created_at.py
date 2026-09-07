"""交易投影表加 created_at(记录时间,服务端首次落库盖章)

Revision ID: 0024_tx_created_at
Revises: 0023_ai_bill_identifier
Create Date: 2026-09-07
"""

import sqlalchemy as sa
from alembic import op

revision = "0024_tx_created_at"
down_revision = "0023_ai_bill_identifier"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 记录时间(服务端收到写入、首次插入 projection 的时刻,UTC)。
    # 客户端不提交该字段,upsert_tx 首次插入时盖章;update 保留不变。
    # NULL = 本迁移之前创建的存量行(不回填:精确的首次落库时刻只在
    # sync_changes 的 create 事件里有,且成本高;NULL 在 UI 显示 "-")。
    op.add_column(
        "read_tx_projection",
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("read_tx_projection", "created_at")
