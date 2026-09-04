#!/usr/bin/env bash
# ============================================================================
# SmartBook(智记)服务端 —— 完整 Docker 镜像构建脚本
#
# 用途:构建本地自建镜像,完全脱离官方 sunxiao0721/beecount-cloud;等价完成
# 本地三阶段构建(frontend + docs index + Python)。启动时 CMD 自动
# `alembic upgrade head && uvicorn`,迁移不用手动跑。
#
# 覆盖 Dockerfile 的全部 ARG:
#   ARG VERSION            → 注入 /api/v1/version 与 VITE_APP_VERSION
#   ARG VITE_API_BASE_URL  → 前端 API 前缀(反向代理不变时别动)
#   ARG DOCS_INDEX_REPO    → 文档 RAG 索引(Website 仓库)来源
#   ARG DOCS_INDEX_BRANCH  → 索引分支
#
# 用法(仓库根任意目录执行;成功后自动 docker save 镜像 tar 到 deploy/):
#   ./deploy/build_docker.sh                      # 无版本号时自动：首次 1.0.0，每次构建 +1
#   ./deploy/build_docker.sh 1.6.4                # 显式版本
#   ./deploy/build_docker.sh --tag dev --skip-tests
#   ./deploy/build_docker.sh --push --min-tag     # 发布:推版本 tag + latest
#
# 常用选项:
#   --repo NAME          镜像仓库名(默认 smartbook-server)
#   --tag TAG            镜像 tag(默认 = 版本号)
#   --push               构建后 docker push
#   --min-tag            同时打 <repo>:latest 并一起推(发布时用)
#   --skip-tests         跳过后端 pytest(默认检测到 .venv 就会跑)
#   --no-cache           docker build 不用缓存
#   --api-base URL       前端 API 前缀(默认 /api/v1)
#   --docs-index-repo URL / --docs-index-branch NAME
#   -h / --help          帮助
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------- 定位脚本与根
# 脚本位于 deploy/,上一级为工作区根;服务端源码固定为工作区根/server
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$REPO_ROOT/server"
cd "$ROOT"

# ── 默认 ────────────────────────────────────────────────────────────────────
DEFAULT_REPO="smartbook-server"
DEFAULT_DOCS_INDEX_REPO="https://github.com/TNT-Likely/BeeCount-Website.git"
REPO="$DEFAULT_REPO"
VERSION=""
TAG=""
PUSH=0
MIN_TAG=0
SKIP_TESTS=0
NO_CACHE=0
VITE_API_BASE_URL="/api/v1"
DOCS_INDEX_REPO="$DEFAULT_DOCS_INDEX_REPO"
DOCS_INDEX_BRANCH="main"

usage() {
  sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── 参数解析 ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --tag)           TAG="$2"; shift 2 ;;
    --push)          PUSH=1; shift ;;
    --min-tag)       MIN_TAG=1; shift ;;
    --skip-tests)    SKIP_TESTS=1; shift ;;
    --no-cache)      NO_CACHE=1; shift ;;
    --api-base)      VITE_API_BASE_URL="$2"; shift 2 ;;
    --docs-index-repo)   DOCS_INDEX_REPO="$2"; shift 2 ;;
    --docs-index-branch) DOCS_INDEX_BRANCH="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    -*)
      echo "未知参数: $1" >&2; usage; exit 1 ;;
    *)
      # 位置参数 = 版本号(只能一个)
      [[ -n "$VERSION" ]] && { echo "版本号重复: $VERSION 与 $1" >&2; usage; exit 1; }
      VERSION="$1"; shift ;;
  esac
done

# ── 版本号:首次 1.0.0,每次构建 +1(工作区根 .build-version-server 记录)──
# 未传版本号时自动递增(1.0.0 → 1.0.1 → …);显式传位置参数版本则使用该值、不写记录。
VERSION_FILE="$REPO_ROOT/.build-version-server"
if [[ -z "$VERSION" ]]; then
  if [[ -f "$VERSION_FILE" ]]; then
    VERSION="$(cat "$VERSION_FILE")"
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "✗ 版本记录文件无效: $VERSION_FILE ($VERSION);删除后自动回到 1.0.0" >&2; exit 1
    fi
    IFS='.' read -r VMAJ VMIN VPAT <<< "$VERSION"
    VERSION="$VMAJ.$VMIN.$((VPAT + 1))"
  else
    VERSION="1.0.0"
  fi
  echo "$VERSION" > "$VERSION_FILE"
  echo "ℹ 版本自动递增: $VERSION(记录 $VERSION_FILE)"
else
  echo "ℹ 版本(显式): $VERSION"
fi
[[ -z "$TAG" ]] && TAG="$VERSION"

# ── 预检 ────────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { echo "✗ 找不到 docker" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
  echo "✗ docker daemon 不可用(没启动? 权限不够?)" >&2; exit 1
fi
if [[ ! -f Dockerfile ]]; then
  echo "✗ 当前目录不是 server 仓库根(缺 Dockerfile)" >&2; exit 1
fi

# ── VITE_API_BASE_URL 防 MSYS 污染 ──────────────────────────────────────────
# Git Bash 会把以 / 开头的命令行参数转成 Windows 路径(MSYS path conversion):
# `docker build --build-arg VITE_API_BASE_URL=/api/v1` 传给 docker.exe 时,
# /api/v1 会被改写为 C:/Program Files/Git/api/v1(Git 安装目录)。该值进入镜像
# 后被 vite 编译进 bundle,web 端登录请求就变成 file:///C:/... 本地地址。
# 这里显式校验,构建时再用 MSYS_NO_PATHCONV=1 禁掉转换。
if ! [[ "$VITE_API_BASE_URL" =~ ^/ || "$VITE_API_BASE_URL" =~ ^https?:// ]]; then
  echo "✗ VITE_API_BASE_URL 非法: «$VITE_API_BASE_URL»" >&2
  echo "  期望以 /(相对前缀,默认 /api/v1)或 http(s):// 开头。" >&2
  echo "  若值是 C:\\\\/file:/// 等本地路径,是被 Git Bash 的 MSYS 路径转换" >&2
  echo "  污染了 —— 本脚本已用 MSYS_NO_PATHCONV=1 禁掉转换,直接重新构建即可。" >&2
  exit 1
fi
if [[ "$VITE_API_BASE_URL" =~ %20 || "$VITE_API_BASE_URL" == *\\* || "$VITE_API_BASE_URL" == *file:* ]]; then
  echo "✗ VITE_API_BASE_URL 疑似被路径转换污染: «$VITE_API_BASE_URL»" >&2
  echo "  重新构建即可(本脚本已用 MSYS_NO_PATHCONV=1 禁掉转换)。" >&2
  exit 1
fi

# ── (可选)后端测试 — 有 .venv 就跑,构建前把关 ──────────────────────────────────
if [[ "$SKIP_TESTS" -eq 0 ]]; then
  if [[ -f .venv/Scripts/python.exe ]]; then PY=".venv/Scripts/python.exe"; fi
  if [[ -f .venv/bin/python ]]; then PY=".venv/bin/python"; fi
  if [[ -n "${PY:-}" ]]; then
    echo "→ 运行后端测试(pytest tests/)…"
    "$PY" -m pytest tests/ -q
  else
    echo "ℹ 未发现 .venv,跳过测试(用 --skip-tests 显式跳过)" >&2
  fi
fi

# ── 构建 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────"
echo "镜像: $REPO:$TAG"
echo "版本: $VERSION    API 前缀: $VITE_API_BASE_URL"
echo "docs 索引: $DOCS_INDEX_REPO @ $DOCS_INDEX_BRANCH"
echo "──────────────────────────────────────────────────"

BUILD_ARGS=(
  --progress=plain
  -t "$REPO:$TAG"
  --build-arg VERSION="$VERSION"
  --build-arg VITE_API_BASE_URL="$VITE_API_BASE_URL"
  --build-arg DOCS_INDEX_REPO="$DOCS_INDEX_REPO"
  --build-arg DOCS_INDEX_BRANCH="$DOCS_INDEX_BRANCH"
)
[[ "$NO_CACHE" -eq 1 ]] && BUILD_ARGS+=(--no-cache)

# MSYS_NO_PATHCONV=1:禁掉 Git Bash 对这次参数(如 VITE_API_BASE_URL=/api/v1)
# 的路径转换,否则 /api/v1 会变成 C:/Program Files/Git/api/v1 污染镜像。
# 非 MSYS 环境(纯 Linux / WSL)下该变量无副作用。
MSYS_NO_PATHCONV=1 docker build "${BUILD_ARGS[@]}" .

# 发布时同时打 latest 标签
if [[ "$MIN_TAG" -eq 1 ]]; then
  docker tag "$REPO:$TAG" "$REPO:latest"
  echo "→ 已加标签 $REPO:latest"
fi

# ── 导出镜像 tar 到 deploy/ ─────────────────────────────────────────────────
# docker save 导出镜像 tar 便于离线/内网部署;旧 tar 清掉,避免堆积。
DEPLOY_DIR="$REPO_ROOT/deploy"
mkdir -p "$DEPLOY_DIR"
rm -f "$DEPLOY_DIR"/smartbook-server-*.tar
TAR_PATH="$DEPLOY_DIR/smartbook-server-$TAG.tar"
docker save -o "$TAR_PATH" "$REPO:$TAG"
echo "→ 镜像已导出:$TAR_PATH"

# ── 推送 ────────────────────────────────────────────────────────────────────
if [[ "$PUSH" -eq 1 ]]; then
  # docker login 失败会立即暴露,不吞错
  docker push "$REPO:$TAG"
  if [[ "$MIN_TAG" -eq 1 ]]; then
    docker push "$REPO:latest"
  fi
fi

# ── 摘要 ────────────────────────────────────────────────────────────────────
SIZE_MB="$(docker image inspect --format '{{.Size}}' "$REPO:$TAG" | awk '{printf "%.1f", $1/1024/1024}')"
echo ""
echo "✅ 构建完成:$REPO:$TAG (${SIZE_MB} MB)"
echo "   镜像 tar:$TAR_PATH"
echo "   镜像内已包含 0019_ai_analysis_logs 等最新 migration,容器启动时自动 alembic upgrade head。"
echo ""
echo "  本地试跑:"
echo "    docker run -p 8080:8080 -v smartbook_data:/data \\"
echo "      -e JWT_SECRET=dev-secret-at-least-32-bytes-long $REPO:$TAG"
echo ""
echo "  compose 部署(自建镜像时把 compose 的 image 指到本镜像):"
echo "    image: $REPO:$TAG"
echo "    docker compose up -d   # 或已有容器: docker compose up -d --force-recreate"
