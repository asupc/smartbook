# Deployment Guide

## 1) Default: SQLite single container

```bash
docker compose up -d --build
```

- Data volume: `smartbook_data` mounted at `/data`
- Default DB URL: `sqlite:////data/smartbook.db`
- Backup artifact dir: `/data/backups` (`BACKUP_STORAGE_DIR`)
- App collaboration read/device scope: `ALLOW_APP_RW_SCOPES` defaults to `true` (set `false` only if you explicitly want to restrict App RW scopes)

## 2) Health checks

- Liveness: `GET /healthz`
- Readiness: `GET /ready`
- Metrics: `GET /metrics`
- Compose includes container health checks (ready probe)

## 3) Backup

SQLite:

```bash
./scripts/backup_sqlite.sh /data/smartbook.db ./backups/sqlite
```

The script uses `sqlite3 .backup` (SQLite Online Backup API), which is **safe
while the server is running** and works in any journal mode. Output is always
a single clean db file — no `-wal` / `-shm` companions.

> ⚠️ Don't `cp` the raw db file: the server runs in WAL mode, and a bare `cp`
> will miss uncommitted writes still sitting in `smartbook.db-wal`. Always use
> the script (or `sqlite3 .backup` directly).

For a full volume snapshot (DB + attachments + JWT secret + previous backups
all together), simply tar the `smartbook_data` volume after stopping the
container, OR use `VACUUM INTO` via the in-app backup runner (admin UI →
"Backup") which integrates with rclone.

### Restore

See [ROLLBACK_SOP.md](./ROLLBACK_SOP.md) — note the **delete `-wal` / `-shm`
before overwriting** step required by WAL mode.

## 4) Security baseline

- First boot auto-generates a 32-byte `JWT_SECRET` into `/data/.jwt_secret`; override the env var if you want to manage the key yourself.
- Put the API behind your own TLS reverse proxy (Caddy / Nginx / Traefik / Cloudflare).
- Keep `/data` on persistent storage — DB, attachments, backups, and the JWT secret all live there.

## 5) App scope troubleshooting

- Symptom: App shows collaboration role as not ready or device page reports `Insufficient scope`.
- Check env: ensure `ALLOW_APP_RW_SCOPES` is not set to `false`.
- Apply changes: restart service/container, then sign out/in again in App to refresh token/session context.
- Device API defaults: `GET /api/v1/devices` now returns `view=deduped` and `active_within_days=30` by default.
  - Full sessions: `GET /api/v1/devices?view=sessions&active_within_days=0`
  - Deduped devices keep `session_count` for readability.

## 6) Self-host member management

- Web collaboration page supports direct member management by email (`add/update/remove`) without requiring invite-code flow.
- Recommended operation path for self-hosting: manage shared ledger members in Web/admin, keep App as collaboration read surface.

## 7) Minimal SOP (self-host)

- If App role shows "Permission not ready", copy diagnostics from App ledger collaboration page and verify:
  - `role_resolve_status`
  - `scope_hint`
  - `deviceId`
- Verify `ALLOW_APP_RW_SCOPES` is enabled (`true`), restart backend, then sign out/in in App.
- If device list looks too large, keep default deduped view first, then switch to all sessions only for revocation.
- If a user has local default ledger `id=1` and remote shared ledger like `ledger_1.json`, the latest App build auto-reconciles identity on startup:
  - personal ledger is remapped to a namespaced local sync id,
  - `sync_queue`/`sync_state` references are migrated automatically,
  - old snapshot path is copied to the new path best-effort when target path is empty.

## 8) Experimental collaboration policy

- Current collaboration capability is treated as **experimental** for self-host deployments.
- Keep backend API compatibility stable; avoid destructive API removal while App/UI continues to iterate.
- Recommended user-facing policy:
  - App keeps collaboration entry visible with beta warnings.
  - Shared member operations remain managed in Web/admin first.

## 9) 2026-09 品牌更名(BeeCount → SmartBook 智记)升级指南

仅对 **存量部署** 升级到新版本时需要。新部署直接使用 `docker-compose.yml` 新名即可。

改名映射(旧 → 新):

| 项 | 旧 | 新 |
|---|---|---|
| Docker compose 服务 | `beecount-cloud` / `beecount-db` | `smartbook-cloud` / `smartbook-db` |
| 数据卷 | `beecount-db-data` / `beecount-data` | `smartbook-db-data` / `smartbook-data` |
| 环境变量 | `BEECOUNT_PORT` / `BEECOUNT_DB_*` / `BEECOUNT_DATABASE_URL` / `BEECOUNT_APP_URL` | `SMARTBOOK_*` |
| PostgreSQL DB / 用户(默认) | `beecount` | `smartbook` |
| SQLite 文件(本地开发) | `beecount.db` | `smartbook.db` |

升级步骤(原卷数据保留):

```bash
cd 项目根目录
docker compose down
# 卷改名为新名(数据保留):
docker volume rename <项目名>_beecount-db-data <项目名>_smartbook-db-data
docker volume rename <项目名>_beecount-data   <项目名>_smartbook-data
# .env 中的 env 键按上表改名(值不变;JWT_SECRET / DB 密码保留原值):
#   BEECOUNT_PORT→SMARTBOOK_PORT、BEECOUNT_DB_DATABASE→SMARTBOOK_DB_DATABASE 等
docker compose up -d
```

> 说明:服务端部署域名保持不变（见 `.env.example`）,仅代码内品牌名更换;客户端 App 本地数据(Drift 数据库 `beecount.sqlite → smartbook.sqlite`、SharedPreferences / Web localStorage 旧 key)由 App 启动时自动迁移,无需手动操作。
