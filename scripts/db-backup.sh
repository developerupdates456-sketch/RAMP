#!/usr/bin/env bash
# DB backup for the Docker Compose stack (local-oem_mysql).
# Dumps oem_integration to the /backups volume (mysql_backups) and rotates old dumps.
# For production (oem_mysql) set CONTAINER=oem_mysql and BACKUP_DIR accordingly.
#
# Usage:
#   CONTAINER=local_oem_mysql bash scripts/db-backup.sh
set -euo pipefail

CONTAINER="${CONTAINER:-local_oem_mysql}"
DB_NAME="${DB_NAME:-oem_integration}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
PW_FILE="/run/secrets/mysql_root_password"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: container '$CONTAINER' not running" >&2
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT="$BACKUP_DIR/oem_integration_${TS}.sql.gz"

echo "==> Backing up $DB_NAME from $CONTAINER -> $OUT"
docker exec -i "$CONTAINER" sh -c \
  "mysqldump -u root --password=\"\$(cat $PW_FILE)\" --single-transaction --routines --events $DB_NAME | gzip -c" \
  > "$OUT"

echo "==> Backup written: $OUT ($(du -h "$OUT" | cut -f1))"

# Rotate: delete dumps older than RETENTION_DAYS (best-effort)
docker exec -i "$CONTAINER" sh -c \
  "find $BACKUP_DIR -name 'oem_integration_*.sql.gz' -mtime +${RETENTION_DAYS} -delete" 2>/dev/null || true

echo "==> Done. PITR: binary logs are enabled (log_bin) — combine this dump with mysqlbinlog for point-in-time recovery."
