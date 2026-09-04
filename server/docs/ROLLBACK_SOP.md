# Rollback SOP

## SQLite

1. Stop app container.
2. **Remove old WAL helper files** (server runs in WAL mode — these belong to
   the current db, not the backup):
   ```bash
   rm -f /data/smartbook.db-wal /data/smartbook.db-shm
   ```
3. Restore db file (backup is always a clean single file, no -wal / -shm):
   ```bash
   cp backups/sqlite/smartbook-<ts>.db /data/smartbook.db
   ```
4. Start app container. SQLite will auto-create new -wal / -shm on first
   connection.
5. Verify:
   - `GET /ready`
   - Web ledger list and one write smoke test.

> Why step 2? In WAL mode `/data` contains `smartbook.db` + `smartbook.db-wal`
> + `smartbook.db-shm`. If you only overwrite `smartbook.db` and leave the old
> -wal around, SQLite will try to "recover" the old WAL log into the new
> database and corrupt your restore. Always delete them first.

## PostgreSQL

1. Stop app container.
2. Restore SQL dump:
   - `cat backups/postgres/smartbook-<ts>.sql | docker compose -f docker-compose.yml -f docker-compose.postgres.yml exec -T db psql -U smartbook -d smartbook`
3. Start app container.
4. Verify:
   - `GET /ready`
   - one read + one write API smoke test.

## Post-check

- `GET /metrics` is available.
- `admin/sync/errors` has no new critical errors.
- If backup artifacts are used, verify:
  - `GET /api/v1/admin/backups/artifacts?ledger_id=<id>`
  - uploaded `snapshot` artifacts can be restored via `admin/backups/restore`.
