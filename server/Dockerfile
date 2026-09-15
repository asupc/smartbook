# SmartBook-Cloud Dockerfile
# 多阶段构建：frontend (pnpm + Vite) + Python (FastAPI + Alembic)

# ===== Stage 1: frontend 构建 =====
FROM node:20-alpine AS frontend-builder
WORKDIR /workspace/frontend
RUN corepack enable

# 先只拷 lock / workspace / 各 package.json，让依赖层可以被 cache 住。
COPY frontend/package.json frontend/pnpm-lock.yaml frontend/pnpm-workspace.yaml /workspace/frontend/
COPY frontend/apps/web/package.json /workspace/frontend/apps/web/package.json
COPY frontend/packages/api-client/package.json /workspace/frontend/packages/api-client/package.json
COPY frontend/packages/ui/package.json /workspace/frontend/packages/ui/package.json
COPY frontend/packages/web-features/package.json /workspace/frontend/packages/web-features/package.json

# lockfile 与 manifest 必须一致(可复现构建):frozen 失败直接报错终止构建,
# 不再静默降级 --no-frozen-lockfile(那会让镜像内容依赖构建当时网络解析结果,
# 构建不可复现且无告警)。lock 变更请本地 pnpm install 后连 pnpm-lock.yaml 一起提交。
RUN pnpm install --frozen-lockfile

COPY frontend /workspace/frontend
ARG VITE_API_BASE_URL=/api/v1
ARG VERSION=dev
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
ENV VITE_APP_VERSION=$VERSION
# 兜底校验:值必须是 / 相对前缀或 http(s)://。若是 C:/Program Files/Git/...
# 之类,是外层 build_docker.sh 传参时被 Git Bash MSYS 路径转换污染,
# 回退默认值避免 web 端请求打到本地 file:// 地址。
RUN case "$VITE_API_BASE_URL" in \
      /*|http://*|https://*) ;; \
      *) echo "WARN: VITE_API_BASE_URL=«$VITE_API_BASE_URL» 非法(疑似 MSYS 路径转换), 回退 /api/v1"; VITE_API_BASE_URL=/api/v1 ;; \
    esac \
 && pnpm -C apps/web build


# ===== Stage 1.5: docs index 拉取 =====
# 从 BeeCount-Website 拉构建好的 RAG 索引(由 Website CI 维护)。
# Website 在 docs 改动时已经 build 好 sqlite 提交回 main,Cloud 这边只 cp。
# 详见 .docs/web-cmdk-ai-doc-search.md。
FROM alpine/git:latest AS docs-index-fetcher
ARG DOCS_INDEX_REPO=https://github.com/TNT-Likely/BeeCount-Website.git
ARG DOCS_INDEX_BRANCH=main
RUN git clone --depth 1 --branch ${DOCS_INDEX_BRANCH} ${DOCS_INDEX_REPO} /website || \
    mkdir -p /website/data
RUN ls /website/data 2>/dev/null || echo 'no docs index found (Website CI 未跑或 repo private,A1 文档 Q&A 将降级)'


# ===== Stage 2: Python 运行环境 =====
FROM python:3.12-slim

ARG VERSION=dev

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# 系统依赖:
#  - tzdata: 时区数据
#  - curl: HEALTHCHECK 用(比 Python urllib 省事)
#  - rclone: 备份模块用,subprocess 调用推数据到对象存储。
#    Debian 12 仓库版本 1.60.x,S3/R2/WebDAV/B2/GDrive/OneDrive 全支持。
# 注:age 加密走 pyrage Python binding(见 requirements.txt),不需要装
# age CLI。用户灾难恢复在自己机器装 age 即可。
RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
    curl \
    rclone \
    && rm -rf /var/lib/apt/lists/*

# postgresql-client-16:备份模块 PG 方言走 pg_dump(custom format,见
# src/services/backup/db_snapshot.py)。Debian 主仓库的客户端版本跟随 base
# 发行版,固定 16 需 PGDG 官方仓库;suite 从 /etc/os-release 动态取 ——
# python:3.12-slim 已切到 trixie,写死 bookworm-pgdg 会装出依赖冲突的
# libpq。**大版本必须与 compose 里 postgres:16-alpine 的服务端大版本匹配
# (客户端 >= 服务端)** —— pg_dump 老客户端会拒连新服务端,升级 compose
# PG 大版本时这里要同步改。
RUN set -eux; \
    install -d -m 0755 /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-client-16; \
    rm -rf /var/lib/apt/lists/*

# 先装 Python 依赖（单独一层，改业务代码时不用重装）
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# 后端代码
COPY alembic.ini /app/alembic.ini
COPY alembic /app/alembic
COPY src /app/src
COPY server.py /app/server.py
COPY scripts /app/scripts

# 静态资源（前端构建产物）
COPY --from=frontend-builder /workspace/frontend/apps/web/dist /app/static

# RAG docs 索引(没拉到时是空目录,server 会优雅降级到 fallback 提示)
COPY --from=docs-index-fetcher /website/data /app/data

# 数据目录:服务端产生的**所有**持久化数据(DB / 附件 / AI 记账截图 /
# 备份 / rclone 配置 / .jwt_secret)统一放 /data —— 各存储路径未显式配置时
# 由 src/config.py 从 DATA_DIR 派生子目录(backups / attachments /
# ai_log_images / backup-staging / restore / rclone.conf),容器部署直接挂一个
# volume 到 /data 就能全量备份。本地开发走默认 DATA_DIR=./data,两种场景
# 互不干扰。/app/data 只剩 docs-index 的只读 RAG 索引,不再承载任何运行时写入。
RUN mkdir -p /data /app/logs
ENV APP_ENV=production \
    DATA_DIR=/data \
    DATABASE_URL=sqlite:////data/smartbook.db \
    WEB_STATIC_DIR=/app/static \
    ALLOW_APP_RW_SCOPES=true \
    APP_VERSION=${VERSION}

# 记下版本号便于排查
RUN echo "${VERSION}" > /app/VERSION

# 默认时区(docker run 可通过 -e TZ=... 覆盖)。
# APScheduler 通过 tzlocal 自动从 TZ env 读取,镜像里 tzdata 已装,
# "0 4 * * *" 在容器本地 4 点触发。如 tzlocal 极少数情况失效(自定义
# minimal base),可显式设置 SCHEDULER_TIMEZONE=<IANA TZ> 兜底。
ENV TZ=Asia/Shanghai

EXPOSE 8080

# 健康检查:打根路径的 /healthz(app.get('/healthz') 直接挂在根,不在
# /api/v1/ 前缀下)。以前写成 /api/v1/healthz + fallback 到 /,每 30s 日志
# 里都多一条 404 噪声;这里直接打对的路径,/ 作二次兜底。
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -fsSL http://localhost:8080/healthz \
     || curl -fsSL http://localhost:8080/ \
     || exit 1

# --proxy-headers:外部反代(nginx/caddy,最小样例见 docs/deploy/reverse-proxy.md)
# 场景下,uvicorn 从 X-Forwarded-For / X-Forwarded-Proto 还原真实客户端 IP ——
# 登录限流 key(src/routers/auth.py)与审计 client_ip 都依赖它;不开时所有请求
# 的 client 都是反代/网桥网关 IP,限流退化为全站共享桶(一个来源可打满全站 429)。
# 可信来源由 FORWARDED_ALLOW_IPS env 控制(compose 已设 docker 网段;不设则
# uvicorn 默认只信任 127.0.0.1,即不认任何外部反代头,行为与旧版一致)。
CMD ["sh", "-c", "alembic upgrade head && uvicorn server:app --host 0.0.0.0 --port 8080 --proxy-headers"]
