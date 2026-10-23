#!/usr/bin/env bash
#
# Roll the stack back to a previously recorded image.
#
#   sudo ./scripts/rollback.sh              # roll back using the saved state
#   sudo ./scripts/rollback.sh --list       # show what is recorded
#   sudo ./scripts/rollback.sh --to <sha>   # roll back to a specific build
#
# The state file is written by update-production.sh on every successful update,
# and records image *ids* rather than tags. That matters: after a bad release is
# overwritten in the registry, the old tag may no longer resolve, but the id is
# still present locally and can be started directly.
#
# Rolling back the application does NOT roll back the schema. Migrations are
# forward-only by design -- see the "Rollback limitations" note in DEPLOYMENT.md.
# If the new release ran a destructive migration, restoring the database from a
# backup is the only way back.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

STATE_FILE=""
LIST_ONLY=0
TARGET=""

while (( $# )); do
    case "$1" in
        --list) LIST_ONLY=1 ;;
        --to)   TARGET="${2:-}"; shift ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

require_docker
require_stack
acquire_lock rmm-rollback 60

STATE_FILE="$(data_dir)/last-good-images.tsv"

if (( LIST_ONLY )); then
    step "recorded image state"
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        warn "no state file at $STATE_FILE"
    fi
    exit 0
fi

if [[ -z "$TARGET" ]] && [[ ! -f "$STATE_FILE" ]]; then
    die "no recorded state at $STATE_FILE, and no --to given."
    die "Use --to <image-id> to roll back to a specific build."
fi

# ---------------------------------------------------------------------------
step "current state"
# ---------------------------------------------------------------------------
dc ps || true

# ---------------------------------------------------------------------------
step "determine target images"
# ---------------------------------------------------------------------------
declare -A TARGET_IMAGE
if [[ -n "$TARGET" ]]; then
    TARGET_IMAGE[api]="$TARGET"
    TARGET_IMAGE[frontend]="$TARGET"
    log "rolling back to explicitly requested image: $TARGET"
elif [[ -f "$STATE_FILE" ]]; then
    while IFS=$'\t' read -r svc img recorded; do
        # Skip the comment header written by update-production.sh.
        [[ "$svc" == \#* ]] && continue
        [[ -n "$svc" && -n "$img" ]] && TARGET_IMAGE[$svc]="$img"
    done < "$STATE_FILE"
    log "using recorded state from $STATE_FILE"
fi

if (( ${#TARGET_IMAGE[@]} == 0 )); then
    die "could not determine any image to roll back to"
fi

for svc in "${!TARGET_IMAGE[@]}"; do
    printf '  %-10s -> %s\n' "$svc" "${TARGET_IMAGE[$svc]}"
done

# ---------------------------------------------------------------------------
step "backing up the current database"
# ---------------------------------------------------------------------------
if [[ -x "$SCRIPTS_DIR/db-backup.sh" ]]; then
    "$SCRIPTS_DIR/db-backup.sh" && ok "backup taken" \
        || warn "backup failed; rolling back anyway (see the backup script output)"
else
    warn "db-backup.sh not found; no backup taken"
fi

# ---------------------------------------------------------------------------
step "applying rollback"
# ---------------------------------------------------------------------------
# Compose cannot take a per-service image override from the environment, so
# write a throwaway override file and add it as a third -f. The repository
# compose files are never modified, and the file is removed on exit.
OVERRIDE="$(mktemp -t rmm-rollback-XXXXXX.yml)"
trap 'rm -f "$OVERRIDE"' EXIT INT TERM

emit_override() {
    # emit_override <service> <image>
    local svc="$1" image="$2"
    [[ -n "$image" ]] || return 0
    cat >> "$OVERRIDE" <<YAML
  $svc:
    image: $image
YAML
}

printf 'services:\n' > "$OVERRIDE"
api_image="${TARGET_IMAGE[api]:-}"
front_image="${TARGET_IMAGE[frontend]:-}"
emit_override api "$api_image"
emit_override frontend "$front_image"
# The worker runs the same image as the api; overriding api does not touch it.
emit_override worker "$api_image"

dim "override file:"
sed 's/^/    /' "$OVERRIDE"

for svc in api worker frontend; do
    log "recreating $svc"
    if docker compose --env-file "$ENV_FILE" \
            -f "$BASE_COMPOSE" -f "$PROD_COMPOSE" -f "$OVERRIDE" \
            up -d --no-deps --force-recreate "$svc"; then
        dim "  $svc recreated"
    else
        err "  failed to roll back $svc"
    fi
done

# ---------------------------------------------------------------------------
step "health verification"
# ---------------------------------------------------------------------------
FAILED=()
for svc in api worker frontend edge-nginx; do
    wait_healthy "$svc" 300 || FAILED+=("$svc")
done

if (( ${#FAILED[@]} > 0 )); then
    err "still unhealthy after rollback: ${FAILED[*]}"
    for svc in "${FAILED[@]}"; do dc logs --tail 40 "$svc" >&2 || true; done
    err ""
    err "If this is a schema problem, restore the database:"
    err "    ./scripts/db-restore.sh <backup-file>"
    exit 1
fi

ok "rollback complete"
dc ps
cat <<EOF

  Remember: this restored the application images only. Any migration applied by
  the version you rolled back from is still in effect. If that version made a
  destructive change, restore the database with scripts/db-restore.sh.
EOF
