# AGENTS.md

Guidance for ZCode agents working in `D:\github\smartbook`.

## What this is

Workspace for **智记 SmartBook** — a vivo Android 自动记账 solution built on two upstream open-source projects:

- **BeeCount** (Flutter 客户端;二开品牌 **SmartBook**) — reuses notification-listening, screenshot OCR, AI bookkeeping, local stats. The full working copy is at **`client/`** (tracked by the root repo; no separate `.git`).
- **BeeCount-Cloud** (FastAPI + React, self-hosted;二开品牌 **SmartBook-Cloud**) — the chosen backend. **Source is cloned at `server/`; this is the 二开 (fork) target.** Deployments run a self-built image **`smartbook-server`** (built by `deploy/build_docker.sh`) — fully detached from the official `sunxiao0721/beecount-cloud`.

Firefly III was the old choice, now **deprecated** (selection notes lived in a previous workspace and are not in this repo).

**Git:** the workspace root is a git repo (history re-initialized; **neither `client/` nor `server/` has a `.git` of its own** — everything is tracked via the root repo). Commit only after confirming with the user.

## Communication

- **与用户沟通一律使用中文**（简体中文，除非用户明确指定其它语言）。

## Layout

```text
AGENTS.md            this file
client/              SmartBook client SOURCE (Flutter; upstream BeeCount 二开)
server/              SmartBook-Cloud SOURCE (FastAPI + React) — main codebase for 二开
docker-compose.yml   SmartBook-Cloud + PostgreSQL deployment (root; canonical)
.env.example         env template — copy to .env, replace CHANGE_ME
deploy/              build scripts only (build.sh 客户端 / build_docker.sh 服务端镜像) — no compose copy here; deployment always uses the root docker-compose.yml
docs/                web-side plans & audits only (app-performance-audit / ux-performance-optimization-plan / asset-page-layout-plan 等 + icon/images 资源);部署文档在 docs/deploy/(反代样例 reverse-proxy.md);早期选型/规划文档不在本仓,勿按旧引用查找
```

## Commands

- **No workspace-root build/test** — no `package.json`/`pubspec` at the root. Backend tooling lives inside `server/`; e.g. server tests run `python -m pytest tests/` from there.
- Deploy: build the image first (`./deploy/build_docker.sh`), then `docker compose up -d` at the root (copy `.env.example` to `.env` first). Fails fast if `JWT_SECRET` or `SMARTBOOK_DB_PASSWORD` is unset.
- The Flutter client is built from `client/` via `deploy/build.sh` (`bash deploy/build.sh` for prod APK; `--flavor dev` for dev; needs `FLUTTER_HOME`/`JAVA_HOME` per CLAUDE.md, and `flutter build` hits the known Kotlin incremental-cache cross-drive issue — clean `client/android/app/build` + `client/android/.gradle` first).

## SmartBook-Cloud — before 二开

**Read `server/CLAUDE.md` before any server-side change.** It is the upstream project's own dev guide and the single source for:

- **Sync architecture contracts** (`server/docs/SYNC_ARCHITECTURE.md`): `ledger_id` channel distinction, LWW / rename cascade, `change_id` monotonicity, lock granularity. This code has a history of hard-to-reproduce bugs — read it before touching sync.
- **Routing conventions**: `src/routers/<group>/` packages (`__init__.py` / `_shared.py` / `<entity>.py`).
- **Storage forms**: `sync_changes` (event log, insert-only) vs `read_*_projection` (read path) vs `ledger_snapshot` (deprecated, don't write).
- **Adding a sync entity**: the 6-step checklist.
- **Logging** structured-format conventions.

Web (React) frontend is `server/frontend/`. **UI stack: antd 5** (PC 管理后台风格;2026-09 完成 shadcn/ui + Tailwind → antd 重构)。Tailwind 仍保留用于布局/间距 utility 类。Mobile (Flutter) source and the mobile↔server sync contracts live in `client/` (upstream `SmartBook` repo, cloned locally).

**Web packages (2026-09, caveat resolved):** `server/frontend/packages/{api-client,ui,web-features}` 源码已完整入库(git 跟踪),pnpm workspace + tsconfig alias 直接解析 `@smartbook/*`,干净克隆可正常构建。

## Key facts

- **Deployed server (default):** set `CORS_ORIGINS` in your own `.env` (see `.env.example`); HTTPS only 由外部反向代理实现(样例见 `docs/deploy/reverse-proxy.md`,plain `http://` returns 400)。`SMARTBOOK_APP_URL` 是已删除的死变量(服务端/compose 均不消费),勿再使用。
- **Auth:** JWT + Personal Access Token (PAT). Transaction writes support `Idempotency-Key` for dedup.
- **Custom LLM architecture (2026-09 中转改造后):**
  1. *App AI 记账全部经服务端中转* — 客户端不再直连 LLM;API Key 只存服务端(`UserProfile.ai_config_json`),任何接口不下发明文(`GET /profile/me` 与 `/ai/providers` 均掩码)。App 调 `/api/v1/ai/relay/{chat,vision,stt}`,服务商配置走 `/api/v1/ai/providers` CRUD;AI 调用日志由服务端在中转现场落 `ai_analysis_logs`,旧客户端自报通道 `POST /ai/logs*` 已删除。
  2. *Web 端* — `/ai/parse-tx-*`(贴图/贴文记账)、`/ai/ask`(RAG)、`/ai/test-provider`(内联配置测试)不变。
  3. *Embedding* → server-side "问 AI" document RAG (`EMBEDDING_*`). Optional.
- **Secrets:** `.env*` is git-ignored — never commit real values. `JWT_SECRET` / DB passwords must be strong.
- **License:** BSL — free for personal/non-profit/research; commercial use needs a paid license.

## Gotchas

- **Custom fork work status:** 已实现的二开功能 —— 短信监听、自动记账四路(截图/支付通知/短信/账单详情页无障碍)、"待确认/疑似重复"确认队列。上游的大额/异常支出提醒在二开时**主动移除**,勿当作待办重新引入(见 CLAUDE.md「有意移除的既有功能」)。
- Client paths ARE present here: `client/lib/ai/...`, `client/android/.../NotificationReceiver.kt` etc. resolve under `client/` (full upstream source). Paths **inside `server/`** (`src/routers/sync/`, `src/sync_applier.py`, `docs/SYNC_ARCHITECTURE.md`) are likewise real and resolvable within that subtree. The `server/docs/SYNC_ARCHITECTURE.md` contract reference still points into `server/`.
