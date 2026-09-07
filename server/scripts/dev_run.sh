#!/usr/bin/env bash
#
# SmartBook-Cloud 开发测试一键启动脚本(Windows / Git Bash 版)。
#
# 同时启动:
#   1) FastAPI 后端  (uvicorn, http://127.0.0.1:8080, 带 --reload)
#   2) Web 前端      (Vite,       http://localhost:5173, 代理 /api -> 8080)
# 并自动用环境变量覆盖 REGISTRATION_ENABLED=true(便于注册新账号联调)。
#
# 启动前自动:/venv 检查 -> alembic upgrade head(建/迁表) -> frontend 依赖检查。
# Ctrl+C 一次同时停止两端。
#
# 用法:
#   ./scripts/dev_run.sh
#   ./scripts/dev_run.sh --api-only      只起后端 API(Web 不启动)
#   ./scripts/dev_run.sh --web-only      只起 Web 前端(需后端已跑在 8080)
#   ./scripts/dev_run.sh --no-reload    后端禁用 --reload(改代码不自动重启)
#
# 依赖(默认已具备):server/.venv(Windows venv,Scripts/ 下有 python.exe)已装
# requirements;node/pnpm 可执行。若缺,首次会提示安装命令,不自动装。

set -euo pipefail

# --- 定位 server/ 根(无论脚本从哪调用) ----------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- 参数解析 -----------------------------------------------------------
API_ONLY=0
WEB_ONLY=0
RELOAD_FLAG="--reload"

for arg in "$@"; do
  case "$arg" in
    --api-only)  API_ONLY=1 ;;
    --web-only)  WEB_ONLY=1 ;;
    --no-reload) RELOAD_FLAG="" ;;
    -h|--help)
      grep -E '^#' "$0" | head -40
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      echo "用法: $0 [--api-only] [--web-only] [--no-reload]" >&2
      exit 1
      ;;
  esac
done
if [ "$API_ONLY" = 1 ] && [ "$WEB_ONLY" = 1 ]; then
  echo "--api-only 与 --web-only 不能同时使用" >&2
  exit 1
fi

# --- 常量 ---------------------------------------------------------------
PYTHON="$ROOT_DIR/.venv/Scripts/python.exe"
if [ ! -x "$PYTHON" ]; then
  # Unix venv 兜底(上游脚本习惯)
  PYTHON="$ROOT_DIR/.venv/bin/python"
fi

API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-8080}"
WEB_PORT=5173   # frontend/apps/web/vite.config.ts 固定,改这里无效

# 注册开关:self-host 默认关闭;开发联调需要能注册新账号,这里强制打开
export REGISTRATION_ENABLED=true

# pnpm 命令(由 check_web 填充)
PNK_CMD=""
# 后台 PID
API_PID=""
WEB_PID=""

# --- 日志函数 -----------------------------------------------------------
c_green=$'\033[0;32m'; c_yellow=$'\033[0;33m'; c_red=$'\033[0;31m'; c_off=$'\033[0m'
info() { printf '%s[dev_run]%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s[dev_run]%s %s\n' "$c_yellow" "$c_off" "$*"; }
err()  { printf '%s[dev_run]%s %s\n' "$c_red" "$c_off" "$*" >&2; }

# --- 端口占用检测 ---------------------------------------------------------
# Windows 下检查指定端口是否已被监听(含 IPv4/IPv6)。
# 返回 0 = 已占用;1 = 空闲。
port_in_use() {
  local port="$1"
  # netstat -ano;匹配 :PORT 且为 LISTENING(可能同时命中 ipv4/ipv6)
  netstat -ano 2>/dev/null | \
    awk -v p="$port" '$1 ~ /TCP/ {
      host = $2; sub(/^.*:/, "", host)
      if (host == p && $4 == "LISTENING") found = 1
    } END { exit found ? 0 : 1 }'
}

# --- 环境检查 -----------------------------------------------------------
check_backend() {
  if [ ! -f "$PYTHON" ]; then
    err "找不到 venv Python: $PYTHON"
    err "server/.venv 未创建? 请先运行:"
    err "  (cd server && python -m venv .venv && .venv/Scripts/pip install -r requirements.txt)"
    exit 1
  fi
  if [ ! -s "$ROOT_DIR/.env" ]; then
    warn ".env 不存在,复制 .env.example 作占位(启动前务必改 JWT_SECRET)"
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  fi
}

check_web() {
  if command -v pnpm >/dev/null 2>&1; then
    PNK_CMD="pnpm"
  elif command -v corepack >/dev/null 2>&1; then
    PNK_CMD="corepack pnpm"
  else
    # nvs 安装目录兜底(Git Bash PATH 可能不含)
    PNK_CMD=""
    for p in /c/Users/*/AppData/Local/nvs/default/pnpm; do
      if [ -x "$p" ]; then PNK_CMD="$p"; break; fi
    done
  fi
  if [ -z "$PNK_CMD" ]; then
    err "找不到 pnpm。请安装后重试: npm install -g pnpm"
    exit 1
  fi
  if [ ! -d "$ROOT_DIR/frontend/node_modules" ]; then
    warn "frontend/node_modules 为空,执行 pnpm install (可改用 --web-only 跳过)"
    (cd "$ROOT_DIR/frontend" && $PNK_CMD install --no-frozen-lockfile)
  fi
}

# --- 迁移 DB ------------------------------------------------------------
migrate() {
  info "执行 alembic 迁移 (alembic upgrade head)..."
  "$PYTHON" -m alembic upgrade head
}

# --- 探活 ---------------------------------------------------------------
wait_http() {
  local name="$1" url="$2" port="$3"
  for _ in $(seq 1 40); do
    if curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null | grep -q '200'; then
      info "$name 就绪: $url (port $port)"
      return 0
    fi
    sleep 0.5
  done
  err "$name 未在预期时间内就绪: $url (port $port)"
  return 1
}

API_URL="http://$API_HOST:$API_PORT/docs"
WEB_URL="http://localhost:$WEB_PORT"

# --- 信号清理 -----------------------------------------------------------
# Windows 下 kill 只杀包装进程,uvicorn --reload / pnpm 的子进程会残留并占住端口。
# 用 taskkill //T 杀整棵进程树。若本机装了 wsl/kill 等,仍回退 kill。
kill_tree() {
  local pid="$1"
  if [ -z "$pid" ]; then return; fi
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
  elif kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  echo ""
  warn "停止开发服务..."
  # 只杀本脚本拉起的进程,避免误杀用户其它 uvicorn/vite
  kill_tree "$WEB_PID"
  kill_tree "$API_PID"
  wait 2>/dev/null || true
  info "已停止"
}
trap cleanup EXIT INT TERM

# ====== 启动 =============================================================
if [ "$WEB_ONLY" = 0 ]; then
  check_backend
  migrate
fi
check_web

# ---- 启动前端口占用检查(避免 start 后撞上残留进程,探活误判"就绪") ----
ensure_port_free() {
  local port="$1" name="$2"
  if port_in_use "$port"; then
    err "端口 $port ($name) 已被占用。可能残留的 dev 进程占用,或你已有服务在跑。"
    err "请先释放该端口,例如:"
    err "  netstat -ano | grep :$port   (找到 PID)"
    err "  taskkill //F //T //PID <PID>"
    exit 1
  fi
}

if [ "$API_ONLY" = 0 ] && [ "$WEB_ONLY" = 0 ]; then
  ensure_port_free "$API_PORT" "后端 API"
  ensure_port_free "$WEB_PORT" "Web 前端"
fi
# 单独启动时只查对应端口
if [ "$WEB_ONLY" = 1 ] && [ "$API_ONLY" = 0 ]; then
  ensure_port_free "$WEB_PORT" "Web 前端"
fi
if [ "$API_ONLY" = 1 ] && [ "$WEB_ONLY" = 0 ]; then
  ensure_port_free "$API_PORT" "后端 API"
fi

if [ "$API_ONLY" = 0 ] && [ "$WEB_ONLY" = 0 ]; then
  info "启动后端 API (uvicorn server:app $RELOAD_FLAG --host $API_HOST --port $API_PORT)"
  info "  REGISTRATION_ENABLED=true (开发覆盖)"
  "$PYTHON" -m uvicorn server:app \
    --reload $RELOAD_FLAG \
    --host "$API_HOST" --port "$API_PORT" &
  API_PID=$!
  wait_http "后端" "$API_URL" "$API_PORT" || true
fi

if [ "$WEB_ONLY" = 0 ] && [ "$API_ONLY" = 0 ]; then
  info "启动 Web 前端 (Vite dev @ port $WEB_PORT, 代理 /api -> $API_PORT)"
  (cd "$ROOT_DIR/frontend" && $PNK_CMD -C apps/web dev) &
  WEB_PID=$!
  wait_http "前端" "$WEB_URL" "$WEB_PORT" || true
fi

echo ""
info "后端:  $API_URL"
info "前端:  $WEB_URL"
info "API 文档: http://$API_HOST:$API_PORT/docs (OpenAPI)"
info "按 Ctrl+C 停止全部服务"

# 最后两种"仅启动"模式:进入前台等待(由 trap 清理)
if [ "$WEB_ONLY" = 1 ]; then
  info "仅启 Web 前端 (假定后端已跑在 $API_PORT)"
  (cd "$ROOT_DIR/frontend" && $PNK_CMD -C apps/web dev)
  wait
  exit 0
fi
if [ "$API_ONLY" = 1 ]; then
  info "仅启后端 API"
  wait
  exit 0
fi

# 全部启动:等待任一端退出,触发 cleanup
wait "$API_PID" "$WEB_PID"
