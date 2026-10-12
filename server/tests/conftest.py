import os

# Keep guardrail tests deterministic regardless of local .env defaults.
os.environ.setdefault("ALLOW_APP_RW_SCOPES", "false")
# Self-hosted registration defaults to off; test suite needs it on so the
# fixture helpers that create users via POST /auth/register keep working.
os.environ.setdefault("REGISTRATION_ENABLED", "true")

# ── 批次 X3:双后端矩阵 ────────────────────────────────────────────────
# 未设置 SMARTBOOK_TEST_DATABASE_URL 时一切照旧(SQLite in-memory,各测试
# 自建 engine)。设置后,标记 @pytest.mark.pg_only 的用例会在真 Postgres 上跑
# (由 scripts/run_pg_tests.sh 起 postgres:16 并导出该变量)。
#
# 注意:本文件不做全局 engine 替换 —— 绝大多数既有测试硬编码
# `create_engine("sqlite://")`,那是它们自己的隔离脚手架;pg_only 用例
# 自己按 env 决定引擎。这里只提供两个 helper。
import pytest  # noqa: E402


def pytest_configure(config):
    """标记注册由 pytest.ini 的 markers= 完成;这里只做启动提示。"""
    url = os.environ.get("SMARTBOOK_TEST_DATABASE_URL", "")
    if url:
        print(f"\n[pytest] 双后端矩阵:SMARTBOOK_TEST_DATABASE_URL 已设置 "
              f"({url.split('@')[-1]}),pg_only 用例将尝试连接真实 Postgres")
    else:
        print("\n[pytest] 单后端模式(SQLite):pg_only 用例将被跳过;"
              "设置 SMARTBOOK_TEST_DATABASE_URL 或运行 scripts/run_pg_tests.sh 跑双后端")


def pytest_collection_modifyitems(config, items):
    """没有 PG URL 时,pg_only 用例自动 skip(而不是 error/失败)。"""
    if os.environ.get("SMARTBOOK_TEST_DATABASE_URL"):
        return
    skip_pg = pytest.mark.skip(
        reason="pg_only: 需要 Postgres(SMARTBOOK_TEST_DATABASE_URL 未设置;"
               "见 scripts/run_pg_tests.sh)"
    )
    for item in items:
        if "pg_only" in item.keywords:
            item.add_marker(skip_pg)


def pg_test_url() -> str | None:
    """pg_only 用例读取的 Postgres DSN;未设置返回 None。"""
    return os.environ.get("SMARTBOOK_TEST_DATABASE_URL") or None
