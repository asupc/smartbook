#!/usr/bin/env bash
# WAL-safe SQLite backup using SQLite Online Backup API (`sqlite3 .backup`).
#
# Why not `cp`?
#   - WAL mode: `cp db.sqlite3` alone loses uncommitted writes still in -wal
#   - DELETE mode: `cp` during active writes can produce a torn / corrupt file
#
# `sqlite3 .backup` works on a running database in any journal mode and
# always produces a clean single-file snapshot (no -wal / -shm needed).
#
# Usage:
#   ./backup_sqlite.sh [DB_PATH] [OUT_DIR]
# Defaults:
#   DB_PATH = /data/smartbook.db
#   OUT_DIR = ./backups/sqlite
set -euo pipefail

DB_PATH="${1:-/data/smartbook.db}"
OUT_DIR="${2:-./backups/sqlite}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_FILE="$OUT_DIR/smartbook-${TS}.db"

mkdir -p "$OUT_DIR"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 CLI not installed. apt: \`apt-get install sqlite3\`" >&2
  exit 1
fi

# Online backup — server can keep writing during this. Output is always a
# single, standalone, clean db file (no -wal / -shm), restorable everywhere.
sqlite3 "$DB_PATH" ".backup '$OUT_FILE'"
echo "backup created: $OUT_FILE"
