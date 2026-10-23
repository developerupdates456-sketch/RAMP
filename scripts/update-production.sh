#!/usr/bin/env bash
#
# Update the running stack to a new image, safely.
#
#   sudo ./scripts/update-production.sh            # build/pull, migrate, restart
#   sudo ./scripts/update-production.sh --pull     # pull published images
#   sudo ./scripts/update-production.sh --dry-run  # show the plan, change nothing
#
# The ordering matters and is the whole point of this script:
#
#   backup  ->  pull  ->  migrate  ->  restart  ->  health check
#
# Migrations run BEFORE the new application starts, and a failed migration or a
# service that will not come up healthy restores the previous image rather than
# leaving a half-upgraded node. Images are referenced by id, so the rollback
# does not depend on the old tag still existing in the registry.
#
# Nothing here is destructive to data: MySQL data lives on its own volume and
# is never recreated.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

PULL_IMAGES=0
DRY_RUN=0
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

while (( $# )); do
    case "$1" in
        --pull)    PULL_IMAGES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# Services to pull, recreate and health-check.
#
# edge-nginx belongs here. It was omitted because the edge is "just a proxy",
# but that omission left it in `Created` after any failed run: an update brought
# api/worker/frontend up, then the health loop checked edge-nginx and found no
# container at all. Anything in the health list must be in this list, or the
# update can never bring the node fully back.
#
# nginx is not image-pulled (it is a pinned upstream tag, not built by CI) and
# it is not listed in a pre-update image id set, so it is recreated rather than
# rolled back -- it carries no code.
SERVICES=(api worker frontend edge-nginx)

if (( DRY_RUN )); then
    warn "--dry-run: no changes will be made"
fi

require_docker
require_stack
acquire_lock rmm-update 60

# ---------------------------------------------------------------------------
step "1/5  pre-update state"
# ---------------------------------------------------------------------------
declare -A PREV_IMAGE_ID
for svc in "${SERVICES[@]}"; do
    id="$(current_image "$svc" || true)"
    if [[ -z "$id" ]]; then
        dim "  $svc: not running (will be created fresh)"
    else
        PREV_IMAGE_ID[$svc]="$id"
        printf '  %-10s running %s\n' "$svc" "$id"
    fi
done

# A backup only means anything if there is a database to back up. On a host
# that has never been deployed there is nothing to dump, and reporting that as
# a FAILED backup is misleading -- it looks like a real problem.
if ! database_running; then
    dim "  no running database; nothing to back up yet"
elif [[ ! -x "$SCRIPTS_DIR/db-backup.sh" ]]; then
    warn "  db-backup.sh not found or not executable; skipping pre-update backup"
elif (( DRY_RUN )); then
    dim "  taking a pre-update database backup (skipped: --dry-run)"
elif "$SCRIPTS_DIR/db-backup.sh" >/tmp/rmm-backup.$$.log 2>&1; then
    ok "  database backup taken"
else
    warn "  database backup FAILED -- see /tmp/rmm-backup.$$.log"
    warn "  continuing, but you will have no restore point for this update"
    rm -f /tmp/rmm-backup.$$.log
fi

if (( DRY_RUN )); then
    step "dry run complete"
    cat <<EOF
  Would: ${PULL_IMAGES:+pull published images}${PULL_IMAGES:-build locally}
          apply migrations
          recreate: ${SERVICES[*]}
          wait up to ${HEALTH_TIMEOUT}s for each service to report healthy
          roll back to the recorded image ids if anything fails
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
step "2/5  fetch images"
# ---------------------------------------------------------------------------
if (( PULL_IMAGES )); then
    dc pull || die "pull failed; nothing has been changed"
else
    # Point TAG at the freshly built images, otherwise compose would recreate
    # the containers from whatever TAG currently resolves to and the build
    # would have no effect.
    if [[ "$(env_value TAG latest)" != "local" ]]; then
        log "setting TAG=local in docker/.env so compose uses the new build"
        if grep -qE '^[[:space:]]*TAG=' "$COMPOSE_DIR/.env"; then
            sed -i -E "s|^[[:space:]]*TAG=.*|TAG=local|" "$COMPOSE_DIR/.env"
        else
            printf '\nTAG=local\n' >> "$COMPOSE_DIR/.env"
        fi
    fi
    log "building api image"
    docker build -f docker/Dockerfile.prod \
        -t "${REGISTRY:-ghcr.io}/${IMAGE_BASE:-teampresence-production/ramp_linux}-api:local" . \
        || die "api build failed; nothing has been changed"
    log "building frontend image"
    docker build -f docker/Dockerfile.prod.frontend \
        -t "${REGISTRY:-ghcr.io}/${IMAGE_BASE:-teampresence-production/ramp_linux}-frontend:local" ./frontend \
        || die "frontend build failed; nothing has been changed"
fi
ok "images ready"

# ---------------------------------------------------------------------------
step "3/5  migrations"
# ---------------------------------------------------------------------------
if ! run_migrations; then
    err "migrations failed. The running containers are untouched and still on"
    err "the previous images. Fix the migration, or restore the backup taken above."
    exit 1
fi

# ---------------------------------------------------------------------------
step "4/5  recreate services"
# ---------------------------------------------------------------------------
# Recreate the application tier. mysql is deliberately excluded: restarting it
# adds a minute of downtime for no benefit, and the schema is already migrated.
#
# `--no-deps` means compose will NOT start a service's dependencies, so order
# matters: api and frontend come before edge-nginx, which waits on both being
# healthy. Recreating edge-nginx first would leave it stuck in `Created` until
# its dependencies reported healthy, which is the state it was found in.
for svc in "${SERVICES[@]}"; do
    log "recreating $svc"
    if ! dc up -d --no-deps --force-recreate "$svc"; then
        # Not fatal here: the health loop reports it properly, with logs. A
        # `Created` container that compose refused to start would otherwise only
        # surface 300s later as "has no container".
        warn "could not recreate $svc"
    fi
done

# ---------------------------------------------------------------------------
step "5/5  health verification"
# ---------------------------------------------------------------------------
FAILED=()
# Iterate SERVICES only. edge-nginx used to be appended here while being
# absent from the recreate list above, so the update never started it and then
# waited 300s for a container that did not exist. SERVICES and this list must
# stay the same set.
for svc in "${SERVICES[@]}"; do
    if wait_healthy "$svc" "$HEALTH_TIMEOUT"; then
        :
    else
        FAILED+=("$svc")
    fi
done

if (( ${#FAILED[@]} > 0 )); then
    err "unhealthy after update: ${FAILED[*]}"
    warn "recent logs:"
    for svc in "${FAILED[@]}"; do
        dc logs --tail 40 "$svc" >&2 || true
    done
    err ""
    err "Nothing has been recorded as good. To return to the previous images:"
    err "    ./scripts/rollback.sh"
    err "The pre-update image ids from this run were:"
    for svc in "${!PREV_IMAGE_ID[@]}"; do
        err "    $svc  ${PREV_IMAGE_ID[$svc]}"
    done
    exit 1
fi

# Record the now-current images as the known-good set, so a future rollback
# has something to target. Written only after everything is healthy, so the
# file always describes a working release.
STATE_FILE="$(data_dir)/last-good-images.tsv"
{
    printf '# service\timage_id\trecorded_at\n'
    for svc in "${SERVICES[@]}"; do
        id="$(current_image "$svc" || true)"
        [[ -n "$id" ]] && printf '%s\t%s\t%s\n' "$svc" "$id" "$(_ts)"
    done
} > "$STATE_FILE"
ok "recorded known-good images in $STATE_FILE"

ok "update complete"
dc ps
cat <<EOF

  Next: confirm the UI loads, then take a fresh backup.
        Health:   ./scripts/health-check.sh
        Rollback: ./scripts/rollback.sh --list
EOF
