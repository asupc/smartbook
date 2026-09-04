"""ai_analysis_logs: add input image columns

App 上报截图记账时同时上传原图,供 Web「AI 调用记录」详情直接查看。图片
本体存磁盘(ai_log_image_dir,文件名 {log_id}.{ext}),DB 只记路径 + mime
(不存 base64/blob,避免撑爆日志表);7 天保留期删行时随行删除文件
(见 main.py _prune_retention_logs)。

Revision ID: 0021_ai_log_image
Revises: 0020_drop_2fa_totp
Create Date: 2026-09-03
"""

import sqlalchemy as sa
from alembic import op


revision = "0021_ai_log_image"
down_revision = "0020_drop_2fa_totp"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "ai_analysis_logs",
        sa.Column("image_path", sa.String(512), nullable=True),
    )
    op.add_column(
        "ai_analysis_logs",
        sa.Column("image_mime", sa.String(64), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("ai_analysis_logs", "image_mime")
    op.drop_column("ai_analysis_logs", "image_path")
