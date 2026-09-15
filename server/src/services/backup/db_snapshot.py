"""数据库快照 —— 按方言分支拿一致的单文件输出。

SQLite(WAL 模式)下直接 `cp smartbook.db` 不安全:
  - WAL 段还没 checkpoint,目标文件少事务
  - 备份过程中读到的内容半截

`VACUUM INTO 'path'` 是原子的 + 已 checkpoint + 输出永远是单文件,无 -shm /
-wal 噪音。需要短暂 read 锁(~ms~s 级),不阻塞写。

PostgreSQL 走 `pg_dump --format=custom`(`pg_dump_snapshot`,产物 `.dump`,
restore 用 `pg_restore`)。方言选择由 runner.py 按 DATABASE_URL 分派。
"""
from __future__ import annotations

import logging
import os
import shutil
import subprocess
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session

logger = logging.getLogger(__name__)


# 备份默认排除的"运维类"表 — 不属于用户数据,留着只让 tar 变大 + 暴露
# 内部细节:
#   - backup_runs / backup_run_targets:备份运行历史(restore 后没意义)
#   - sync_push_idempotency:24 小时滚动 idempotency 缓存
#   - audit_logs:管理员操作日志,运维痕迹,不属于"账本数据"
#   - refresh_tokens:登录 session,restore 后所有人都得重登,留着没用
#   - mcp_call_logs:MCP tool 调用审计,30 天滚动遥测,跟账本数据无关
#   - ai_analysis_logs:AI 分析调用审计(含全文输入输出)。**不设保留期**
#     —— 数据清理任务不回收该表,体积会一直增长;备份里持续排除,既能控制
#     备份体积,也避免把含 prompt/输出的敏感遥测推到对象存储。
# **PAT 表 (personal_access_tokens) 要保留** — 用户的 LLM 客户端配置依赖
# 这些 token,restore 后 LLM 仍然能连上,不用重新发 token。
# 用户数据相关(必须保留):users / user_profiles / devices / ledgers /
# sync_changes / sync_cursors / read_*_projection / attachment_files /
# personal_access_tokens / backup_remotes / backup_schedules /
# backup_schedule_remotes(配置要保留)
DEFAULT_EXCLUDED_TABLES = (
    "backup_runs",
    "backup_run_targets",
    "sync_push_idempotency",
    "audit_logs",
    "refresh_tokens",
    "mcp_call_logs",
    "ai_analysis_logs",
)


def vacuum_into(
    db: Session,
    target_path: str | Path,
    *,
    exclude_tables: tuple[str, ...] | None = DEFAULT_EXCLUDED_TABLES,
) -> None:
    """跑 VACUUM INTO,把当前数据库一致快照写到 target_path。

    exclude_tables 提供时,VACUUM 完后开 copy 文件,**DELETE 这些表的数据**
    (保留 schema)+ 再 VACUUM 一次释放空间。default 排除运维类表
    (backup_runs / audit_logs 等),用户数据全部保留。

    **注意**:之前版本是 `DROP TABLE` 整张表,restore 后 server 启动会撞
    "no such table" 因为代码里有引用(典型:`mcp_call_logs`)。
    改成 `DELETE FROM` 仅清数据,schema 保留 → restore 后即插即用。

    target_path 父目录必须已存在 + 文件不能已存在(SQLite 要求)。
    """
    target = Path(target_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    safe = str(target).replace("'", "''")
    db.execute(text(f"VACUUM INTO '{safe}'"))
    db.commit()
    if not target.exists():
        raise RuntimeError(f"VACUUM INTO did not produce file: {target}")

    if exclude_tables:
        from sqlalchemy import create_engine, inspect

        copy_engine = create_engine(f"sqlite:///{target}")
        try:
            # **保留 schema,只 DELETE 数据**(原来用 DROP TABLE 会让 restore
            # 出来的 DB 缺表,server 启动后查到这些表就 500 —— 历史 issue:
            # 0008+ 之后 mcp_call_logs 不在表里,导致 GET /profile/pats 报
            # "no such table"。运维类表本身体积也不大,留 schema 不影响
            # 备份大小。)
            inspector = inspect(copy_engine)
            existing_tables = set(inspector.get_table_names())
            with copy_engine.begin() as conn:
                for tbl in exclude_tables:
                    if tbl not in existing_tables:
                        # 表本来就不存在(老 DB 还没跑过这个 migration)— 跳过
                        continue
                    # 表名是常量白名单,无注入风险
                    conn.execute(text(f"DELETE FROM {tbl}"))
            # VACUUM 释放数据占用的空间(SQLite 不会自动收回)
            with copy_engine.connect() as conn:
                conn.execute(text("VACUUM"))
                conn.commit()
            logger.info(
                "vacuum_into: cleared data in %d tables (schema preserved): %s",
                len(exclude_tables), ", ".join(exclude_tables),
            )
        finally:
            copy_engine.dispose()

    size = target.stat().st_size
    logger.info("VACUUM INTO done: %s (%d bytes)", target, size)


def database_backend(database_url: str) -> str:
    """从 DATABASE_URL 提取 SQLAlchemy backend 名('sqlite' / 'postgresql')。

    兼容 `postgresql+psycopg://...` 这类带 driver 后缀的 URL —— make_url 会
    把 '+psycopg' 归一掉;legacy `postgres://` scheme 也归一成 'postgresql'
    (make_url 对它返回字面 'postgres',不翻译)。
    """
    backend = make_url(database_url).get_backend_name()
    return "postgresql" if backend in ("postgres", "postgresql") else backend


def pg_dump_snapshot(
    database_url: str,
    target_path: str | Path,
    *,
    exclude_tables: tuple[str, ...] | None = DEFAULT_EXCLUDED_TABLES,
    pg_dump_binary: str | None = None,
) -> None:
    """用 pg_dump(custom format)把 PostgreSQL 库快照到 target_path(.dump)。

    与 vacuum_into 的对应关系:
      - 产物:单一文件,restore 时用 `pg_restore --dbname=... <file>`;
      - exclude_tables:走 `--exclude-table-data=<tbl>`(schema 保留、数据
        不进 dump),语义与 SQLite 分支"DELETE 运维表数据"一致。

    安全/健壮性约定:
      - 密码**绝不落命令行**(ps 里可见),经 PGPASSWORD 环境变量传给子进程;
      - 连接参数(host/port/user/dbname)从 DATABASE_URL 解析,不从 shell
        拼接,避免特殊字符注入;
      - pg_dump 二进制缺失时抛带修复指引的 RuntimeError(裸镜像没装
        postgresql-client 的安全网;server/Dockerfile 已装 postgresql-client-16)。
    """
    target = Path(target_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()

    url = make_url(database_url)
    if database_backend(database_url) != "postgresql":
        raise RuntimeError(
            f"pg_dump_snapshot only supports postgresql:// URLs, got: "
            f"{url.drivername}"
        )

    binary = pg_dump_binary or shutil.which("pg_dump")
    if binary is None:
        logger.error(
            "pg_dump binary not found on PATH — PostgreSQL backup requires "
            "postgresql-client (the server image installs postgresql-client-16; "
            "custom environments must install a client whose major version >= "
            "the server's, see deploy notes / Dockerfile)"
        )
        raise RuntimeError(
            "pg_dump not found on PATH: PostgreSQL 备份需要 postgresql-client"
            "(镜像内已装 postgresql-client-16;自备环境请安装与服务端大版本"
            "匹配(>=)的客户端)"
        )

    argv = [
        binary,
        "--format=custom",
        "--no-owner",
        "--no-privileges",
        f"--file={target}",
    ]
    if exclude_tables:
        for tbl in exclude_tables:
            # 表名是常量白名单,无注入风险
            argv.append(f"--exclude-table-data={tbl}")
    if url.host:
        argv.append(f"--host={url.host}")
    if url.port:
        argv.append(f"--port={url.port}")
    if url.username:
        argv.append(f"--username={url.username}")
    if url.database:
        argv.append(f"--dbname={url.database}")

    env = os.environ.copy()
    if url.password:
        env["PGPASSWORD"] = url.password

    logger.info(
        "pg_dump started: host=%s port=%s db=%s user=%s -> %s",
        url.host, url.port, url.database, url.username, target,
    )
    proc = subprocess.run(  # noqa: S603 — argv 列表形式,元素均来自受控解析
        argv,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        stderr_tail = (proc.stderr or "")[-500:]
        logger.error("pg_dump failed (rc=%d): %s", proc.returncode, stderr_tail)
        raise RuntimeError(f"pg_dump failed with rc={proc.returncode}: {stderr_tail}")

    if not target.exists() or target.stat().st_size == 0:
        raise RuntimeError(f"pg_dump did not produce output file: {target}")

    size = target.stat().st_size
    logger.info(
        "pg_dump done: %s (%d bytes, excluded %d tables' data)",
        target, size, len(exclude_tables or ()),
    )
