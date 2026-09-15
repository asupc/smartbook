"""user_profiles.ai_config_version 乐观锁列(S3)

Revision ID: 0031_user_profile_ai_config_version
Revises: 0030_tx_soft_delete
Create Date: 2026-09-15

`ai_config_json` 是单 TEXT 列整块 read-modify-write(App /ai/providers CRUD
+ Web PATCH /profile/me),并发写互相覆盖。加整数版本列:写路径统一
`UPDATE ... WHERE ai_config_version = ?` + 自增,rowcount=0 → 409。
存量行 default 0(与 models.py 的 server_default 一致)。
"""

import sqlalchemy as sa
from alembic import op

revision = "0031_user_profile_ai_config_version"
down_revision = "0030_tx_soft_delete"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("user_profiles") as batch:
        batch.add_column(
            sa.Column(
                "ai_config_version",
                sa.Integer(),
                nullable=False,
                server_default="0",
            )
        )


def downgrade() -> None:
    with op.batch_alter_table("user_profiles") as batch:
        batch.drop_column("ai_config_version")
