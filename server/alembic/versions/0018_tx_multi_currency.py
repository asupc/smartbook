"""read_tx_projection: currency_code + native_amount — 交易级多币种

设计见 SmartBook 仓 .docs/multi-currency-ledger/03-tech-design-cloud.md。
currency_code = 交易原币种(NULL 视作账本本位币);
native_amount = 折账本本位币的金额快照(NULL 时统计端 COALESCE 回退 amount)。

存量投影行回填 native_amount = amount(隐含汇率 1.0),与 App 端 v30 迁移
同口径 —— 单币种账本回填前后统计结果不变。currency_code 留 NULL(过渡期
NULL 视作账本本位币,统计不依赖它),从简。

Revision ID: 0018_tx_multi_currency
Revises: 0017_transaction_exclude_flags
Create Date: 2026-07-12
"""

import sqlalchemy as sa
from alembic import op


revision = "0018_tx_multi_currency"
down_revision = "0017_transaction_exclude_flags"
branch_labels = None
depends_on = None


# 已有 native_amount 的行不覆盖(WHERE IS NULL)。供测试 import 验证语义
# (照 0015 BACKFILL_STATEMENTS 的测试风格)。
BACKFILL_STATEMENT = (
    "UPDATE read_tx_projection SET native_amount = amount "
    "WHERE native_amount IS NULL"
)


def upgrade() -> None:
    op.add_column(
        "read_tx_projection",
        sa.Column("currency_code", sa.String(16), nullable=True),
    )
    op.add_column(
        "read_tx_projection",
        sa.Column("native_amount", sa.Float(), nullable=True),
    )
    bind = op.get_bind()
    result = bind.execute(sa.text(BACKFILL_STATEMENT))
    rowcount = getattr(result, "rowcount", None)
    if rowcount is not None:
        print(f"0018_tx_multi_currency: backfilled native_amount for {rowcount} rows")


def downgrade() -> None:
    op.drop_column("read_tx_projection", "native_amount")
    op.drop_column("read_tx_projection", "currency_code")
