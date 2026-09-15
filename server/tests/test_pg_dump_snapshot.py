"""db_snapshot.pg_dump_snapshot / database_backend 单测(PostgreSQL 备份分支)。

无真实 PG 实例,mock 掉 shutil.which + subprocess.run,静态核查契约:
  - argv:custom format / no-owner / no-privileges / 连接参数 / exclude-table-data;
  - 密码只经 PGPASSWORD 子进程 env 传递,**绝不落命令行**;
  - pg_dump 缺失 / 非零退出 / 空产物 / 非_pg URL 的错误路径。
"""
from __future__ import annotations

import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from src.services.backup.db_snapshot import (
    DEFAULT_EXCLUDED_TABLES,
    database_backend,
    pg_dump_snapshot,
)

PG_URL = (
    "postgresql+psycopg://smartbook:p%40ss%20w0rd@db-host:5433/smartbook"
)


def test_database_backend_recognizes_dialects():
    assert database_backend(PG_URL) == "postgresql"
    assert database_backend("postgres://u:p@h/db") == "postgresql"
    assert database_backend("sqlite:///./smartbook.db") == "sqlite"


def _make_run_mock(target: Path, *, returncode: int = 0, stderr: str = ""):
    """造一个 subprocess.run 替身:按 argv 里的 --file= 落一个非空文件。"""
    calls: list[dict] = []

    def fake_run(argv, env=None, **kwargs):
        calls.append({"argv": list(argv), "env": dict(env or {})})
        if returncode == 0:
            file_arg = next(a for a in argv if a.startswith("--file="))
            out = Path(file_arg.split("=", 1)[1])
            out.write_bytes(b"PGDMP-fake-dump")
        return SimpleNamespace(returncode=returncode, stderr=stderr, stdout="")

    return fake_run, calls


def test_pg_dump_snapshot_argv_and_env(tmp_path, monkeypatch):
    """argv/env 契约:连接参数正确、密码只在 env、排除表逐个传参。"""
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.shutil.which", lambda _: "/usr/bin/pg_dump"
    )
    fake_run, calls = _make_run_mock(tmp_path / "db.dump")
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.subprocess.run", fake_run
    )

    target = tmp_path / "db.dump"
    pg_dump_snapshot(PG_URL, target)

    assert len(calls) == 1
    argv = calls[0]["argv"]
    env = calls[0]["env"]

    assert argv[0] == "/usr/bin/pg_dump"
    for flag in ("--format=custom", "--no-owner", "--no-privileges"):
        assert flag in argv
    assert f"--file={target}" in argv
    # 连接参数从 DATABASE_URL 解析(host/port/user/dbname)
    assert "--host=db-host" in argv
    assert "--port=5433" in argv
    assert "--username=smartbook" in argv
    assert "--dbname=smartbook" in argv
    # 排除表:与 SQLite 分支 DEFAULT_EXCLUDED_TABLES 语义对齐
    for tbl in DEFAULT_EXCLUDED_TABLES:
        assert f"--exclude-table-data={tbl}" in argv
    # 密码只经 PGPASSWORD env(make_url 已做 percent-decode),绝不落 argv
    assert env["PGPASSWORD"] == "p@ss w0rd"
    assert not any("p@ss" in a for a in argv), "密码泄漏到命令行"
    # 其余环境继承自当前进程(rclone 等子进程依赖)
    for k, v in os.environ.items():
        assert env.get(k) == v

    assert target.exists() and target.stat().st_size > 0


def test_pg_dump_snapshot_missing_binary(tmp_path, monkeypatch):
    """pg_dump 不在 PATH:抛带修复指引的 RuntimeError,且不起子进程。"""
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.shutil.which", lambda _: None
    )
    called = []

    def _fail_run(*a, **kw):  # pragma: no cover - 不应被调到
        called.append(a)
        raise AssertionError("subprocess.run must not be called")

    monkeypatch.setattr(
        "src.services.backup.db_snapshot.subprocess.run", _fail_run
    )

    with pytest.raises(RuntimeError, match="postgresql-client"):
        pg_dump_snapshot(PG_URL, tmp_path / "db.dump")
    assert not called


def test_pg_dump_snapshot_nonzero_exit(tmp_path, monkeypatch):
    """pg_dump 非零退出:错误信息带 stderr 尾部,方便排障。"""
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.shutil.which", lambda _: "/usr/bin/pg_dump"
    )
    fake_run, _ = _make_run_mock(
        tmp_path / "db.dump", returncode=1, stderr="connection refused"
    )
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.subprocess.run", fake_run
    )

    with pytest.raises(RuntimeError, match="connection refused"):
        pg_dump_snapshot(PG_URL, tmp_path / "db.dump")


def test_pg_dump_snapshot_empty_output(tmp_path, monkeypatch):
    """rc=0 但产物为空/缺失:视为失败,不让空文件进备份包。"""
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.shutil.which", lambda _: "/usr/bin/pg_dump"
    )

    def fake_run(argv, env=None, **kwargs):
        return SimpleNamespace(returncode=0, stderr="", stdout="")

    monkeypatch.setattr(
        "src.services.backup.db_snapshot.subprocess.run", fake_run
    )

    with pytest.raises(RuntimeError, match="did not produce output"):
        pg_dump_snapshot(PG_URL, tmp_path / "db.dump")


def test_pg_dump_snapshot_rejects_non_pg_url(tmp_path):
    """方言守卫:sqlite URL 不允许走 pg_dump 分支。"""
    with pytest.raises(RuntimeError, match="postgresql"):
        pg_dump_snapshot("sqlite:///./smartbook.db", tmp_path / "db.dump")


def test_pg_dump_snapshot_none_exclude_no_table_flags(tmp_path, monkeypatch):
    """exclude_tables=None:不传任何 --exclude-table-data(完整备份)。"""
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.shutil.which", lambda _: "/usr/bin/pg_dump"
    )
    fake_run, calls = _make_run_mock(tmp_path / "db.dump")
    monkeypatch.setattr(
        "src.services.backup.db_snapshot.subprocess.run", fake_run
    )

    pg_dump_snapshot(PG_URL, tmp_path / "db.dump", exclude_tables=None)
    argv = calls[0]["argv"]
    assert not [a for a in argv if a.startswith("--exclude-table-data=")]
