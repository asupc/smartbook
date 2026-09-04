# AGENTS.md

Guidance for ZCode agents working in `D:\gitee\auto-ledger`.

## What this is

Workspace for **智记 SmartBook** — a vivo Android 自动记账 solution built on two upstream open-source projects:

- **BeeCount** (Flutter 客户端;二开品牌 **SmartBook**) — reuses notification-listening, screenshot OCR, AI bookkeeping, local stats. The full working copy is at **`client/`** (tracked by the root repo; no separate `.git`).
- **BeeCount-Cloud** (FastAPI + React, self-hosted;二开品牌 **SmartBook-Cloud**) — the chosen backend. **Source is cloned at `server/`; this is the 二开 (fork) target.** Deployments run a self-built image **`smartbook-server`** (built by `deploy/build_docker.sh`) — fully detached from the official `sunxiao0721/beecount-cloud`.

Firefly III was the old choice, now **deprecated**. Rationale: `docs/backend-selection.md`.

**Git:** the workspace root is a git repo (history re-initialized; **neither `client/` nor `server/` has a `.git` of its own** — everything is tracked via the root repo). Commit only after confirming with the user.

## Layout

```text
AGENTS.md            this file
client/              SmartBook client SOURCE (Flutter; upstream BeeCount 二开)
server/              SmartBook-Cloud SOURCE (FastAPI + React) — main codebase for 二开
docker-compose.yml   SmartBook-Cloud + PostgreSQL deployment (root; canonical)
.env.example         env template — copy to .env, replace CHANGE_ME
deploy/              deployment copies (docker-compose.yml + .env) + build scripts (build.sh 客户端 / build_docker.sh 服务端镜像)
docs/                design decisions for THIS workspace. See "Gotchas".
```

## Commands

- **No workspace-root build/test** — no `package.json`/`pubspec` at the root. Backend tooling lives inside `server/`; e.g. server tests run `python -m pytest tests/` from there.
- Deploy: build the image first (`./deploy/build_docker.sh`), then `docker compose up -d` at the root (copy `.env.example` to `.env` first). Fails fast if `JWT_SECRET` is unset.
- The Flutter client is built from `client/` via `deploy/build.sh` (`bash deploy/build.sh` for prod APK; `--flavor dev` for dev; needs `FLUTTER_HOME`/`JAVA_HOME` per CLAUDE.md, and `flutter build` hits the known Kotlin incremental-cache cross-drive issue — clean `client/android/app/build` + `client/android/.gradle` first).

## SmartBook-Cloud — before 二开

**Read `server/CLAUDE.md` before any server-side change.** It is the upstream project's own dev guide and the single source for:

- **Sync architecture contracts** (`server/docs/SYNC_ARCHITECTURE.md`): `ledger_id` channel distinction, LWW / rename cascade, `change_id` monotonicity, lock granularity. This code has a history of hard-to-reproduce bugs — read it before touching sync.
- **Routing conventions**: `src/routers/<group>/` packages (`__init__.py` / `_shared.py` / `<entity>.py`).
- **Storage forms**: `sync_changes` (event log, insert-only) vs `read_*_projection` (read path) vs `ledger_snapshot` (deprecated, don't write).
- **Adding a sync entity**: the 6-step checklist.
- **Logging** structured-format conventions.

Web (React) frontend is `server/frontend/`. **UI stack: antd 5** (PC 管理后台风格;2026-09 完成 shadcn/ui + Tailwind → antd 重构,过程见 `docs/frontend-antd-refactor-plan.md`)。Tailwind 仍保留用于布局/间距 utility 类。Mobile (Flutter) source and the mobile↔server sync contracts live in `client/` (upstream `SmartBook` repo, cloned locally).

⚠️ **Web build caveat (2026-09):** the workspace packages `server/frontend/packages/{api-client,ui,web-features}` are **not git-tracked** (directories empty; sources exist only in gitignored `node_modules/@smartbook/*` copies). A clean clone cannot resolve `@smartbook/*` imports — fix/populate before trusting any web build/test run.

## Key facts

- **Deployed server (default):** set `SMARTBOOK_APP_URL` / `CORS_ORIGINS` in your own `.env` (see `.env.example`), HTTPS only (plain `http://` returns 400).
- **Auth:** JWT + Personal Access Token (PAT). Transaction writes support `Idempotency-Key` for dedup.
- **Custom LLM = two independent paths:**
  1. *Chat/Vision* → AI bookkeeping (client "AI 服务商管理" page; syncs to server).
  2. *Embedding* → server-side "问 AI" document RAG (`EMBEDDING_*`). Optional.
- **Secrets:** `.env*` is git-ignored — never commit real values. `JWT_SECRET` / DB passwords must be strong.
- **License:** BSL — free for personal/non-profit/research; commercial use needs a paid license.

## Gotchas

- **Obsoleted workspace docs** (must NOT be treated as current): `docs/android-technical-architecture.md`, `docs/data-model-and-parser-pipeline.md`, `docs/ui-and-mvp-plan.md` (all marked 原自研方案/已废止). Authoritative: `backend-selection.md`, `app-feature-plan.md`, `ai-custom-model.md`, `development-plan.md`.
- **`development-plan.md` is the main plan** — read before planning implementation; it lists the gap vs what SmartBook already does + milestone ordering (M0 → M0.5 → M1…).
- **Planned customizations are new, not upstream:** SMS listening, a "待确认/疑似重复" confirmation queue, and large/abnormal-spend alerts — these are the actual 二开 fork work.
- Client paths ARE present here: `client/lib/ai/...`, `client/android/.../NotificationReceiver.kt` etc. resolve under `client/` (full upstream source). Paths **inside `server/`** (`src/routers/sync/`, `src/sync_applier.py`, `docs/SYNC_ARCHITECTURE.md`) are likewise real and resolvable within that subtree. The `server/docs/SYNC_ARCHITECTURE.md` contract reference still points into `server/`.
