#!/usr/bin/env bash
# DB restore for the Docker Compose stack (local-oem_mysql).
# Restores a gzip dump produced by db-backup.sh into oem_integration.
#
# Usage:
#   RESTORE_FILE=/backups/oem_integration_20260716_120000.sql.gz \
#   CONTAINER=local_oem_mysql bash scripts/db-restore.sh
set -euo pipefail

CONTAINER="${CONTAINER:-local_oem_mysql}"
DB_NAME="${DB_NAME:-oem_integration}"
RESTORE_FILE="${RESTORE_FILE:-}"
PW_FILE="/run/secrets/mysql_root_password"

if [ -z "$RESTORE_FILE" ]; then
  echo "ERROR: set RESTORE_FILE (e.g. /backups/oem_integration_YYYYMMDD_HHMMSS.sql.gz)" >&2
  exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: container '$CONTAINER' not running" >&2
  exit 1
fi

echo "==> Restoring $RESTORE_FILE into $DB_NAME on $CONTAINER"
docker exec -i "$CONTAINER" sh -c \
  "gunzip -c | mysql -u root --password=\"\$(cat $PW_FILE)\" $DB_NAME" \
  < "$RESTORE_FILE"

echo "==> Restore complete."

# PITR continuation: to roll forward to a point in time, replay binary logs:
#   docker exec -i "$CONTAINER" sh -c "mysqlbinlog --stop-datetime='YYYY-MM-DD HH:MM:SS' /var/lib/mysql/mysql-bin.XXXXXX | mysql -u root --password=\"\$(cat $PW_FILE)\""
