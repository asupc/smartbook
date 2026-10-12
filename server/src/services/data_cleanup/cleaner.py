"""孤儿数据清理 — 按 type dispatch 删行 / 改字段 / 删文件。

DB 操作 caller 保证事务边界(router 层 commit / rollback);文件操作 best-effort
unlink,失败 warn。

**删除包含性契约(P1,B3/B1)**:本模块的删除目标是**客户端可控制的输入**
(scan 结果回传到 /clean),因此每个待删路径在 ``os.remove`` 之前必须经共享的
``src.storage_paths.path_within_root`` 证明落在附件存储根之内;不在根内的记录
**明确失败**(记入 result.failures 并把 DB 行回滚),绝不静默跳过 ——
操作员要能看到「为什么没删掉」。
"""
from __future__ import annotations

import json
import logging
import os
from collections.abc import Iterable
from pathlib import Path

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ...models import (
    AttachmentFile,
    ReadBudgetProjection,
    ReadTxProjection,
    SyncChange,
)
from ...storage_paths import (
    attachment_storage_root,
    attachment_storage_root_if_configured,
    resolve_path_within_root,
)
from .models import CleanFailure, CleanResult, OrphanRecord, OrphanType

logger = logging.getLogger("smartbook.data_cleanup")


def _storage_root() -> Path:
    """附件存储根(共享 helper 派生,绝对路径);供 rmdir 向上递归的 stop_at。

    ``create=False`` —— 清理器不创建目录;判据与扫描 / 落盘点同源。
    """
    root = attachment_storage_root(create=False)
    return root.resolve()


def resolve_deletable_within_root(file_path: str | None) -> Path | None:
    """待删路径的**唯一**包含性判据:在附件根之内 → 解析后绝对路径,否则 None。

    两个删除形态共用(与扫描侧的标记同源,不会出现「扫说能删、删时被拒」的分叉):
      - B3 ``disk_file_no_row``:``file_path`` 直接来自**客户端**回传,可指向任意
        绝对路径(如 ``C:\\Users\\…\\victim.txt``);
      - B1 ``attachment_no_ref``:``storage_path`` 来自 DB,但该行可由历史脏数据
        (或 scan 回传的 file_path)写入根之外。

    用 `resolve_path_within_root`(**整条**路径按 cwd 解析,不做 root 拼接)——
    与 ``os.remove`` 的语义一致;`Path.resolve()` 消解 ``..`` / 绝对片段 /
    符号链接,Windows 下大小写 / 盘符切换也由 ``is_relative_to`` 兜住。

    `ATTACHMENT_STORAGE_DIR` 空串(文档化的「关闭附件存储」开关)时
    fail-closed:没有根 → 一切物理删除都拒绝(宁可不删,不可误删)。
    """
    if not file_path:
        return None
    root = attachment_storage_root_if_configured()
    if root is None:
        return None
    return resolve_path_within_root(root, file_path)


def _require_deletable_within_root(file_path: str | None) -> Path:
    """``resolve_deletable_within_root`` 的抛错包装 —— 不可删 → ValueError。

    错误串里带上被拒路径与根,`CleanFailure.error` 会原样回给 admin 操作员
    (响应 failures[]),日志侧另记一条 ERROR(admin 日志面板默认筛 ERROR)。
    """
    resolved = resolve_deletable_within_root(file_path)
    if resolved is None:
        root = _storage_root()
        logger.error(
            "data_cleanup.path_outside_root_blocked path=%r root=%s",
            file_path,
            root,
        )
        raise ValueError(
            f"refusing to delete {file_path!r}: path is outside the attachment "
            f"storage root ({root})"
        )
    return resolved


def _remove_empty_parents(file_path: str, stop_at: Path | None = None) -> None:
    """删完一个附件文件后,向上递归删空目录,直到遇到非空目录 / stop_at / 根。

    stop_at 默认是 attachment_storage_dir 根 —— 永远不删根本身。每级用 rmdir
    (只在空时成功),非空会抛 OSError 被 catch,不会误删兄弟附件所在目录。
    """
    if not file_path:
        return
    try:
        root = (stop_at or _storage_root()).resolve()
    except OSError:
        return
    try:
        parent = Path(file_path).resolve().parent
    except OSError:
        return
    while True:
        # 必须严格在 root 之下,且不是 root 本身
        try:
            parent_resolved = parent.resolve()
        except OSError:
            return
        if parent_resolved == root:
            return
        try:
            parent_resolved.relative_to(root)
        except ValueError:
            # parent 已经在 root 之外 —— 安全起见停止
            return
        try:
            parent_resolved.rmdir()
        except OSError:
            # 非空 / 权限等任何错误 → 停止递归(兄弟附件还在,不再继续向上)
            return
        parent = parent_resolved.parent


def clean(db: Session, records: Iterable[OrphanRecord]) -> CleanResult:
    """逐条 dispatch 删除。失败收集到 failures,不阻断其余。

    caller 负责 commit / rollback。文件删失败只 warn。
    生产环境 SQLite 用,每条 record 处理完立即 db.commit() 避免长事务持有
    write lock 阻塞其他请求(observability 中间件的读请求频繁,长事务 + 文件
    IO 慢操作会导致 "database is locked")。文件 IO(unlink + rmdir)放到
    DB commit 之后,确保 DB lock 已释放。
    """
    success = 0
    failures: list[CleanFailure] = []
    for record in records:
        pending_file_ops: list[callable] = []  # type: ignore[type-arg]
        try:
            _dispatch(db, record, pending_file_ops)
            db.commit()
            success += 1
        except Exception as exc:  # noqa: BLE001
            db.rollback()
            logger.warning(
                "clean record %s db failed: %s",
                record.unique_key,
                exc,
            )
            failures.append(CleanFailure(record_key=record.unique_key, error=str(exc)))
            continue
        # DB 已 commit + 锁已释放 → 执行文件 IO。失败只 warn,不回滚 DB(行已删
        # 是事实,磁盘残留下次 GC 会扫到)。
        for op in pending_file_ops:
            try:
                op()
            except Exception as exc:  # noqa: BLE001
                # 包含性校验已在 _dispatch 阶段完成(失败 → 上面的 failures
                # 分支);这里只剩真实 IO 错误(权限 / 占用),按契约只 warn。
                logger.warning(
                    "clean record %s file op failed: %s",
                    record.unique_key,
                    exc,
                )
    return CleanResult(success_count=success, failures=failures)


def _dispatch(db: Session, r: OrphanRecord, file_ops: list) -> None:
    """跑 record 类型对应的 DB 操作;文件 IO append 到 file_ops 列表,由
    caller 在 db.commit 之后跑(避免长事务持锁)。"""
    t = r.type
    if t == OrphanType.TX_MISSING_CATEGORY:
        _clear_tx_field(db, r, "category_sync_id", "category_name")
    elif t == OrphanType.TX_MISSING_ACCOUNT:
        _clear_tx_field(db, r, "account_sync_id", "account_name")
    elif t == OrphanType.TX_MISSING_FROM_ACCOUNT:
        _clear_tx_field(db, r, "from_account_sync_id", "from_account_name")
    elif t == OrphanType.TX_MISSING_TO_ACCOUNT:
        _clear_tx_field(db, r, "to_account_sync_id", "to_account_name")
    elif t == OrphanType.BUDGET_MISSING_CATEGORY:
        _clear_budget_category(db, r)
    elif t == OrphanType.SYNC_CHANGE_MISSING_ENTITY:
        _delete_sync_change(db, r)
    elif t == OrphanType.ATTACHMENT_NO_REF:
        _delete_attachment_with_file(db, r, file_ops)
    elif t == OrphanType.ATTACHMENT_FILE_MISSING:
        _delete_attachment_row_only(db, r)
    elif t == OrphanType.DISK_FILE_NO_ROW:
        # B3 的 file_path 是**客户端回传**的任意字符串,先在 dispatch 阶段
        # (commit 之前)证明它在附件根之内;逃逸 → ValueError → 记 failures
        # 并在响应里明确回报(不静默跳过)。
        resolved = _require_deletable_within_root(r.file_path)
        file_ops.append(lambda p=resolved: _delete_disk_file_only(p))
    elif t == OrphanType.TX_REF_BROKEN_ATTACHMENT:
        _strip_broken_attachments(db, r)
    elif t == OrphanType.TX_TRASH_EXPIRED:
        _purge_expired_trash_tx(db, r, file_ops)
    else:  # pragma: no cover
        raise ValueError(f"unknown OrphanType: {t}")


# ─────────────────────── helpers ───────────────────────


def _ledger_sync_from_record(r: OrphanRecord) -> tuple[str, str]:
    """从 extra 解析 (ledger_id, sync_id),失败抛 ValueError。"""
    extra = r.extra or {}
    ledger_id = extra.get("ledger_id")
    sync_id = extra.get("sync_id") or r.sync_id
    if not ledger_id or not sync_id:
        raise ValueError(f"record {r.unique_key} 缺 ledger_id/sync_id")
    return str(ledger_id), str(sync_id)


def _clear_tx_field(
    db: Session,
    r: OrphanRecord,
    sync_id_col: str,
    name_col: str,
) -> None:
    """A1/A2/A3:把 ReadTxProjection 的 *_sync_id 和 *_name 字段置 NULL。保留交易本体。"""
    ledger_id, sync_id = _ledger_sync_from_record(r)
    stmt = (
        update(ReadTxProjection)
        .where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
        )
        .values(**{sync_id_col: None, name_col: None})
    )
    db.execute(stmt)


def _clear_budget_category(db: Session, r: OrphanRecord) -> None:
    """A4:ReadBudgetProjection.category_sync_id 置 NULL。"""
    ledger_id, sync_id = _ledger_sync_from_record(r)
    stmt = (
        update(ReadBudgetProjection)
        .where(
            ReadBudgetProjection.ledger_id == ledger_id,
            ReadBudgetProjection.sync_id == sync_id,
        )
        .values(category_sync_id=None)
    )
    db.execute(stmt)


def _delete_sync_change(db: Session, r: OrphanRecord) -> None:
    """A5/C1:删 sync_changes 行。"""
    if not r.row_id:
        raise ValueError("sync_change record 缺 row_id (change_id)")
    change_id = int(r.row_id)
    row = db.get(SyncChange, change_id)
    if row is None:
        return  # 已经被删,视为成功
    db.delete(row)


def _delete_attachment_with_file(
    db: Session, r: OrphanRecord, file_ops: list
) -> None:
    """B1:删 AttachmentFile 行(同事务)+ 物理文件 + 删空父目录(commit 后)。"""
    if not r.row_id:
        raise ValueError("attachment record 缺 row_id")
    row = db.get(AttachmentFile, r.row_id)
    if row is None:
        return
    storage_path = row.storage_path
    # P1 包含性前置校验:storage_path 是 DB 值,但该行可能由历史脏数据 / 迁移
    # 写入根之外(实测:DB 行 storage_path=C:\...\victim.txt,clean 直接 os.remove)。
    # 必须在 db.delete(row) **之前**判定 —— 失败时整条 record 回滚,DB 行与
    # 文件都保留,响应 failures 里给出原因(不静默跳过)。空 storage_path
    # (无物理文件)跳过校验,只删行。
    resolved = _require_deletable_within_root(storage_path) if storage_path else None
    db.delete(row)
    if storage_path:
        assert resolved is not None  # storage_path 非空时上面的校验必返回路径

        def _do_file_op(path: Path = resolved, row_id: str = r.row_id) -> None:
            try:
                path_str = str(path)
                if os.path.exists(path_str):
                    os.remove(path_str)
                _remove_empty_parents(path_str)
            except OSError as exc:
                logger.warning(
                    "B1 unlink failed file=%s path=%s err=%s",
                    row_id, path, exc,
                )
        file_ops.append(_do_file_op)


def _delete_attachment_row_only(db: Session, r: OrphanRecord) -> None:
    """B2:磁盘已没,只删 DB 行。"""
    if not r.row_id:
        raise ValueError("attachment record 缺 row_id")
    row = db.get(AttachmentFile, r.row_id)
    if row is None:
        return
    db.delete(row)


def _delete_disk_file_only(file_path: Path) -> None:
    """B3:DB 没记,只清磁盘 + 删空父目录。

    `file_path` 必须是**已通过包含性校验**的解析路径(`_dispatch` 在 commit
    之前用 `_require_deletable_within_root` 判过),本函数不再接受裸字符串 ——
    避免未来新增调用点绕过校验。
    """
    if os.path.exists(file_path):
        os.remove(file_path)
    _remove_empty_parents(str(file_path))


def _strip_broken_attachments(db: Session, r: OrphanRecord) -> None:
    """B4:从 ReadTxProjection.attachments_json 移除指向不存在 fileId 的项。

    tx 本体保留 + 重写 JSON。broken_file_ids 从 extra 拿。
    """
    from sqlalchemy import select

    ledger_id, sync_id = _ledger_sync_from_record(r)
    broken = (r.extra or {}).get("broken_file_ids") or []
    if not broken:
        return
    broken_set = set(broken)
    obj = db.scalar(
        select(ReadTxProjection).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
        )
    )
    if obj is None or not obj.attachments_json:
        return
    try:
        atts = json.loads(obj.attachments_json)
    except (ValueError, TypeError):
        return
    if not isinstance(atts, list):
        return
    kept = [
        a
        for a in atts
        if not (isinstance(a, dict) and a.get("cloudFileId") in broken_set)
    ]
    obj.attachments_json = json.dumps(kept) if kept else None


def _purge_expired_trash_tx(db: Session, r: OrphanRecord, file_ops: list) -> None:
    """D 类(0030):回收站 30 天保留期到的交易物理删除(行 + 附件 GC)。

    与 read/trash.py 的 purge 端点同语义:先收集附件引用,删行,再 GC
    孤立附件(共享引用保留)。GC 的文件 unlink 由 gc 内部处理;这里的
    file_ops 预留为空(clean() 会在 DB commit 后跑列表内容)。

    物理删除后该交易的所有 **upsert** sync_changes 事件一并 compact
    (P1-A3):transaction 是最大实体,upsert 历史只增不减会让 sync_changes
    无界膨胀。复用 sync_applier._compact_entity_upsert_events 的契约例外
    —— **delete 墓碑事件保留**,cursor 落后的设备仍能 apply delete 把本地
    副本删干净(upsert 事件对已不存在的实体毫无价值,apply 是幂等 no-op)。
    """
    from ... import projection
    from ...concurrency import lock_ledger_for_materialize, lock_user_global
    from ...sync_applier import _compact_entity_upsert_events

    ledger_id, sync_id = _ledger_sync_from_record(r)
    # F-13 锁覆盖(§4.7 user→ledger):清理器改投影(purge 行 + GC)会与并发
    # push/web 写同一批行竞争。旧实现无锁 —— PostgreSQL 下真实竞态(SQLite 的
    # lock_* 是 no-op)。锁顺序固定 user→ledger:r.user_id 是投影行的 user_id
    # (= ledger owner,见下方 _compact 注释),可作 user 锁 key。
    lock_user_global(db, r.user_id)
    lock_ledger_for_materialize(db, ledger_id)
    # 二次校验仍在回收站(避免清理扫描后用户已恢复的行被误删)
    row = db.scalar(
        select(ReadTxProjection).where(
            ReadTxProjection.ledger_id == ledger_id,
            ReadTxProjection.sync_id == sync_id,
            ReadTxProjection.deleted_at.is_not(None),
        )
    )
    if row is None:
        return
    tx_file_ids = projection.collect_tx_attachment_fileids(
        db, ledger_id=ledger_id, sync_id=sync_id,
    )
    projection.purge_tx(db, ledger_id=ledger_id, sync_id=sync_id)
    projection.gc_orphan_attachments_for_ledger(
        db, ledger_id=ledger_id, file_ids=tx_file_ids,
    )
    # r.user_id 即投影行的 user_id(= ledger owner),与 SyncChange.user_id
    # 的对应关系同 scanner._scan_sync_change_missing_entity 的 transaction 分支
    _compact_entity_upsert_events(
        db, user_id=r.user_id, entity_type="transaction", entity_sync_id=sync_id,
    )
