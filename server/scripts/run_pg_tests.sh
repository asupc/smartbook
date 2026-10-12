#!/usr/bin/env bash
# 批次 X3:Postgres 双后端矩阵一键运行器。
#
# 作用:起一个临时 postgres:16 容器 → 等待就绪 → 导出
# SMARTBOOK_TEST_DATABASE_URL → 跑 pytest(tests/ 全量,含 @pytest.mark.pg_only)
# → 退出时清理容器。
#
# 用法(在 server/ 目录或任意位置均可,脚本自行定位仓库):
#   bash scripts/run_pg_tests.sh                     # 跑 tests/ 全量
#   bash scripts/run_pg_tests.sh tests/test_pg_only_contracts.py -q
#   KEEP=1 bash scripts/run_pg_tests.sh              # 跑完保留容器(便于排查)
#   PG_PORT=55433 bash scripts/run_pg_tests.sh       # 换宿主端口(默认 55432)
#
# 前置:本机有 Docker 且守护进程可用(`docker info`)。没有 Docker 时脚本
# 直接报错退出 —— 不会静默跳过,避免"以为跑了双后端其实只跑了 SQLite"。
#
# 说明:未设置 SMARTBOOK_TEST_DATABASE_URL 时,`pytest tests/` 是纯 SQLite
# 单后端模式,pg_only 用例由 tests/conftest.py 统一 skip。本脚本是拿到
# Postgres 证据的唯一入口。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$SERVER_DIR/.." && pwd)"

PG_PORT="${PG_PORT:-55432}"
PG_USER="${PG_USER:-smartbook}"
PG_PASSWORD="${PG_PASSWORD:-smartbook}"
PG_DB="${PG_DB:-smartbook_test}"
CONTAINER_NAME="${CONTAINER_NAME:-smartbook-pgtest}"
PG_IMAGE="${PG_IMAGE:-postgres:16}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 未找到 docker —— 本脚本需要 Docker 起 postgres:16。" >&2
  echo "       如已自备 Postgres,可直接导出 SMARTBOOK_TEST_DATABASE_URL 后跑 pytest:" >&2
  echo "         export SMARTBOOK_TEST_DATABASE_URL='postgresql+psycopg://user:pass@host:5432/db'" >&2
  echo "         python -m pytest tests/ -q" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker 守护进程不可用(docker info 失败)。" >&2
  exit 1
fi

cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo "[pg-tests] KEEP=1 → 保留容器 $CONTAINER_NAME(端口 $PG_PORT)"
    return
  fi
  echo "[pg-tests] 清理容器 $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 复用/重建容器
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "[pg-tests] 复用既有容器 $CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
else
  echo "[pg-tests] 启动 $PG_IMAGE($CONTAINER_NAME,宿主端口 $PG_PORT)"
  docker run -d --name "$CONTAINER_NAME" \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -e POSTGRES_DB="$PG_DB" \
    -p "$PG_PORT:5432" \
    "$PG_IMAGE" >/dev/null
fi

# 等待就绪(pg_isready 最多 ~60s)
echo -n "[pg-tests] 等待 Postgres 就绪"
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    echo " → ready"
    break
  fi
  echo -n "."
  sleep 1
done
if ! docker exec "$CONTAINER_NAME" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
  echo "" >&2
  echo "ERROR: Postgres 60s 内未就绪,容器日志尾部:" >&2
  docker logs --tail 40 "$CONTAINER_NAME" >&2 || true
  exit 1
fi

export SMARTBOOK_TEST_DATABASE_URL="postgresql+psycopg://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_PORT}/${PG_DB}"
echo "[pg-tests] SMARTBOOK_TEST_DATABASE_URL=postgresql+psycopg://${PG_USER}:***@127.0.0.1:${PG_PORT}/${PG_DB}"

# 默认跑 tests/ 全量(含 pg_only);有额外参数则原样透传给 pytest。
# 注意:必须显式给路径 —— 裸 `pytest -q` 会连 src/ 一起收集
# (src/routers/ai/test_provider.py 名字以 test_ 开头,会触发
#  PytestCollectionWarning 甚至把 src 当测试包导入)。
cd "$SERVER_DIR"
if [[ $# -gt 0 ]]; then
  exec python -m pytest "$@"
else
  exec python -m pytest tests/ -q
fi
