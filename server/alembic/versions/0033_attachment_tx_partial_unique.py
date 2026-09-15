"""attachment_files 交易附件 (ledger_id, sha256) 部分唯一索引(S9)

Revision ID: 0032_attachment_tx_partial_unique
Revises: 0031_user_profile_ai_config_version
Create Date: 2026-09-15

背景:附件上传去重是 check-then-insert(attachments.py /_shared
transactions_batch),并发同图上传会落重复行 + 重复磁盘文件。加部分唯一
索引(transaction kind)把去重下沉到存储层,代码路径在冲突时复用既有行。

- 先清理存量重复(同 (ledger_id, sha256) 的 transaction 行保留
  read_tx_projection.attachments_json 仍引用的;无引用的组保留最小 id);
  被删行对应的磁盘文件留给 data_cleanup 的孤立附件扫描回收。
- PG 用 CREATE UNIQUE INDEX CONCURRENTLY(0029/0031 先例,不锁表写);
  SQLite 用普通 create_index + sqlite_where。
"""

import json
import sqlite3

import sqlalchemy as sa
from alembic import op

revision = "0032_attachment_tx_partial_unique"
down_revision = "0031_user_profile_ai_config_version"
branch_labels = None
depends_on = None

_INDEX_NAME = "uq_attachment_files_tx_ledger_sha"


def _is_postgresql() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def _dedup_existing_duplicates() -> int:
    """删除 transaction kind 的存量重复行,返回删除数。

    保留规则:每 (ledger_id, sha256) 组里,仍被 read_tx_projection
    .attachments_json(cloudFileId)引用的行全保;其余保留最小 id。
    """
    conn = op.get_bind()
    rows = conn.execute(
        sa.text(
            "SELECT id, ledger_id, sha256 FROM attachment_files "
            "WHERE attachment_kind = 'transaction' AND ledger_id IS NOT NULL "
            "ORDER BY ledger_id, sha256, id"
        )
    ).mappings().all()

    groups: dict[tuple[str, str], list[str]] = {}
    for r in rows:
        groups.setdefault((r["ledger_id"], r["sha256"]), []).append(r["id"])

    dup_groups = {k: ids for k, ids in groups.items() if len(ids) > 1}
    if not dup_groups:
        return 0

    # 仍被引用的 file id 全部保留(引用行删了会断交易的附件链接)。
    referenced: set[str] = set()
    proj_rows = conn.execute(
        sa.text(
            "SELECT attachments_json FROM read_tx_projection "
            "WHERE attachments_json IS NOT NULL"
        )
    ).mappings().all()
    for pr in proj_rows:
        try:
            arr = json.loads(pr["attachments_json"])
        except (ValueError, TypeError):
            continue
        if not isinstance(arr, list):
            continue
        for att in arr:
            if isinstance(att, dict):
                fid = att.get("cloudFileId") or att.get("fileId") or att.get("file_id")
                if isinstance(fid, str) and fid:
                    referenced.add(fid)

    to_delete: list[str] = []
    for ids in dup_groups.values():
        keep = {i for i in ids if i in referenced} or {ids[0]}  # 无引用则保最小 id
        to_delete.extend(i for i in ids if i not in keep)

    for fid in to_delete:
        conn.execute(
            sa.text("DELETE FROM attachment_files WHERE id = :fid"),
            {"fid": fid},
        )
    return len(to_delete)


def upgrade() -> None:
    removed = _dedup_existing_duplicates()
    if removed:
        # 让删除先提交,CONCURRENTLY 分支要求事务外执行;SQLite 下也无害。
        op.get_bind().commit()

    if _is_postgresql():
        with op.get_context().autocommit_block():
            op.execute(
                f"CREATE UNIQUE INDEX CONCURRENTLY {_INDEX_NAME} "
                "ON attachment_files (ledger_id, sha256) "
                "WHERE attachment_kind = 'transaction'"
            )
    else:
        op.create_index(
            _INDEX_NAME,
            "attachment_files",
            ["ledger_id", "sha256"],
            unique=True,
            sqlite_where=sa.text("attachment_kind = 'transaction'"),
        )


def downgrade() -> None:
    if _is_postgresql():
        with op.get_context().autocommit_block():
            op.execute(f"DROP INDEX CONCURRENTLY IF EXISTS {_INDEX_NAME}")
    else:
        try:
            op.drop_index(_INDEX_NAME, table_name="attachment_files")
        except sqlite3.OperationalError:
            # 旧库可能没有该索引(从未跑过 upgrade 的部分路径),降级幂等。
            pass
