"""ai_analysis_logs — AI 分析调用审计表

Revision ID: 0019_ai_analysis_logs
Revises: 0018_tx_multi_currency
Create Date: 2026-09-03

每次 AI 分析调用(ask / parse-tx-image / parse-tx-text)登记一行,Web AI
设置页「调用记录」读这张表。跟 mcp_call_logs 的区别:**完整记录输入输出**
(便于调试 prompt / 排查 provider 问题),因此:

  - 输入输出含用户交易内容 → 保留期 **7 天**(比 mcp 的 30 天短),由
    main.py 的后台 retention loop 清
  - 图片输入不存 base64,只存图片元信息摘要
  - 列上 provider / model / duration / tokens(provider 返 usage 时)/ IP 等元数据

user_id FK CASCADE —— 用户删号时日志随之删。
"""

import sqlalchemy as sa
from alembic import op


revision = "0019_ai_analysis_logs"
down_revision = "0019_account_hidden"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "ai_analysis_logs",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column(
            "user_id",
            sa.String(36),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("entry_type", sa.String(32), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("provider_id", sa.String(64), nullable=True),
        sa.Column("model", sa.String(128), nullable=True),
        sa.Column("ledger_id", sa.String(128), nullable=True),
        sa.Column("input_text", sa.Text(), nullable=True),
        sa.Column("output_text", sa.Text(), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("duration_ms", sa.Integer, nullable=False, server_default="0"),
        sa.Column("prompt_tokens", sa.Integer, nullable=True),
        sa.Column("completion_tokens", sa.Integer, nullable=True),
        sa.Column("total_tokens", sa.Integer, nullable=True),
        sa.Column("client_ip", sa.String(64), nullable=True),
        sa.Column(
            "called_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
    )
    op.create_index("ix_ai_analysis_logs_user_id", "ai_analysis_logs", ["user_id"])
    op.create_index("ix_ai_analysis_logs_entry_type", "ai_analysis_logs", ["entry_type"])
    op.create_index("ix_ai_analysis_logs_status", "ai_analysis_logs", ["status"])
    op.create_index("ix_ai_analysis_logs_called_at", "ai_analysis_logs", ["called_at"])
    # 复合:WHERE user_id=? ORDER BY called_at DESC LIMIT N — 列表页主查询
    op.create_index(
        "ix_ai_log_user_time",
        "ai_analysis_logs",
        ["user_id", sa.text("called_at DESC")],
    )


def downgrade() -> None:
    op.drop_index("ix_ai_log_user_time", table_name="ai_analysis_logs")
    op.drop_index("ix_ai_analysis_logs_called_at", table_name="ai_analysis_logs")
    op.drop_index("ix_ai_analysis_logs_status", table_name="ai_analysis_logs")
    op.drop_index("ix_ai_analysis_logs_entry_type", table_name="ai_analysis_logs")
    op.drop_index("ix_ai_analysis_logs_user_id", table_name="ai_analysis_logs")
    op.drop_table("ai_analysis_logs")
