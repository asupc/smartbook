#!/usr/bin/env bash
# SmartBook PostgreSQL 手动备份(运维兜底脚本)。
#
# 面向仓库根目录的 canonical 部署(docker-compose.yml,服务名 smartbook-db)。
# 注意:server/docker-compose.postgres.yml 是本地开发 overlay(服务名 db),
# 与本脚本无关,别混用。
#
# 产物为明文 SQL(psql < dump.sql 即可恢复);内置定时备份(rclone 推远端、
# pg_dump custom 格式)见 server/src/services/backup/。
#
# cron 示例(每天 04:30 备份,日志追加到 /var/log):
#   30 4 * * * cd /opt/smartbook && bash server/scripts/backup_postgres.sh >> /var/log/smartbook-pg-backup.log 2>&1
# 旧备份请自行清理(例:find /opt/smartbook/backups/postgres -name '*.sql' -mtime +14 -delete)。
#
# 用法:
#   bash server/scripts/backup_postgres.sh [输出目录]   # 默认 <仓库根>/backups/postgres
# 环境变量(与根 docker-compose.yml 插值一致,可覆盖):
#   SMARTBOOK_DB_USERNAME(默认 smartbook)
#   SMARTBOOK_DB_DATABASE(默认 smartbook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

OUT_DIR="${1:-${REPO_ROOT}/backups/postgres}"
TS="$(date +%Y%m%d-%H%M%S)"
DB_USER="${SMARTBOOK_DB_USERNAME:-smartbook}"
DB_NAME="${SMARTBOOK_DB_DATABASE:-smartbook}"

mkdir -p "$OUT_DIR"
docker compose -f "${REPO_ROOT}/docker-compose.yml" exec -T smartbook-db \
  pg_dump -U "$DB_USER" -d "$DB_NAME" >"$OUT_DIR/smartbook-${TS}.sql"
echo "backup created: $OUT_DIR/smartbook-${TS}.sql"
