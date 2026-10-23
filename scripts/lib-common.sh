#!/usr/bin/env bash
# Shared helpers for the RMM operational scripts.
#
# Sourced, never executed directly:
#     source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"
#
# Keeping this in one place means the compose invocation, the project name and
# the preflight checks cannot drift apart between the install, update, rollback
# and health scripts.

set -o pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$LIB_DIR/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/docker"
SECURITY_DIR="$REPO_ROOT/security"
SCRIPTS_DIR="$LIB_DIR"

# The data root. Must match RMM_DATA_DIR in docker/.env; it is read from there
# when that file exists so the scripts and the stack cannot disagree.
DEFAULT_DATA_DIR="/opt/rmm"

# Compose is always invoked as base + prod overlay, matching the documented
# deployment command. `migrate` lives behind a profile and is run explicitly.
BASE_COMPOSE="$COMPOSE_DIR/docker-compose.yml"
PROD_COMPOSE="$COMPOSE_DIR/docker-compose.prod.yml"
ENV_FILE="$COMPOSE_DIR/.env"

# dc <args...>  ->  docker compose --env-file .env -f base -f prod <args...>
dc() {
    docker compose --env-file "$ENV_FILE" -f "$BASE_COMPOSE" -f "$PROD_COMPOSE" "$@"
}

# Same, but with the one-shot migrate profile enabled.
dc_migrate() {
    docker compose --env-file "$ENV_FILE" -f "$BASE_COMPOSE" -f "$PROD_COMPOSE" \
        --profile migrate "$@"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _C_RESET=$'\033[0m'; _C_INFO=$'\033[36m'; _C_OK=$'\033[32m'
    _C_WARN=$'\033[33m'; _C_ERR=$'\033[31m'; _C_DIM=$'\033[2m'
else
    _C_RESET=""; _C_INFO=""; _C_OK=""; _C_WARN=""; _C_ERR=""; _C_DIM=""
fi

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log()      { printf '%s %sINFO%s  %s\n'  "$(_ts)" "$_C_INFO" "$_C_RESET" "$*"; }
ok()       { printf '%s %sOK%s    %s\n'  "$(_ts)" "$_C_OK"   "$_C_RESET" "$*"; }
warn()     { printf '%s %sWARN%s  %s\n'  "$(_ts)" "$_C_WARN" "$_C_RESET" "$*" >&2; }
err()      { printf '%s %sERROR%s %s\n'  "$(_ts)" "$_C_ERR"  "$_C_RESET" "$*" >&2; }
die()      { err "$*"; exit 1; }
step()     { printf '\n%s%s==> %s%s\n' "$_C_INFO" "$(_ts)" "$*" "$_C_RESET"; }
dim()      { printf '%s%s%s\n' "$_C_DIM" "$*" "$_C_RESET"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "must run as root (or via sudo): $0"
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

require_docker() {
    require_cmd docker
    docker compose version >/dev/null 2>&1 \
        || die "docker compose v2 is required (the 'docker compose' subcommand)"
    docker info >/dev/null 2>&1 \
        || die "cannot talk to the Docker daemon. Is it running, and do you have permission?"
}

# Wait for the daemon to answer, instead of failing on the first attempt.
#
# This matters most at boot. The rmm-stack systemd unit and the daemon are not
# ordered reliably against each other: Docker Engine is a system service, but
# Docker Desktop is a *user* service that depends on `loginctl enable-linger`,
# so it can still be starting when the system unit runs. A single `docker info`
# check turns that race into "the stack did not come back after the reboot".
wait_for_docker() {
    local seconds="${1:-180}" i
    log "waiting for the Docker daemon (timeout ${seconds}s)"
    for (( i = 1; i <= seconds; i++ )); do
        if docker info >/dev/null 2>&1; then
            ok "daemon ready (${i}s)"
            return 0
        fi
        # Nudge Desktop in case it is enabled but was not started by the unit.
        if [[ -n "${RMM_DOCKER_USER:-}" ]] \
           && [[ -d "/run/user/$(id -u "$RMM_DOCKER_USER" 2>/dev/null)/systemd" ]]; then
            runuser -u "$RMM_DOCKER_USER" -- \
                env XDG_RUNTIME_DIR="/run/user/$(id -u "$RMM_DOCKER_USER")" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$RMM_DOCKER_USER")/bus" \
                systemctl --user start docker-desktop >/dev/null 2>&1 || true
        fi
        printf '.'
        sleep 1
    done
    echo
    return 1
}

# Verify the deployment files exist before anything destructive happens.
require_stack() {
    [[ -f "$COMPOSE_DIR/docker-compose.yml" ]] \
        || die "missing $COMPOSE_DIR/docker-compose.yml"
    [[ -f "$COMPOSE_DIR/docker-compose.prod.yml" ]] \
        || die "missing $COMPOSE_DIR/docker-compose.prod.yml"
    [[ -f "$COMPOSE_DIR/.env" ]] \
        || die "missing $COMPOSE_DIR/.env -- copy .env.example to .env and fill it in first"
}

# All credentials the stack needs must exist before the first start, or mysql
# and the api will crash-loop in a way that is tedious to diagnose.
check_secrets() {
    local f missing=0
    for f in mysql_root_password mysql_app_password jwt_secret_key \
             encryption_key firebase_key.json servicedesk_key.json; do
        if [[ ! -s "$SECURITY_DIR/secrets/$f" ]]; then
            err "missing or empty secret: security/secrets/$f"
            missing=1
        fi
    done
    return $missing
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
env_value() {
    # Read KEY from docker/.env without sourcing it (it is not shell).
    local key="$1" default="${2:-}"
    [[ -f "$COMPOSE_DIR/.env" ]] || { printf '%s' "$default"; return; }
    local line
    line="$(grep -E "^[[:space:]]*${key}=" "$COMPOSE_DIR/.env" | tail -n1 || true)"
    if [[ -z "$line" ]]; then printf '%s' "$default"; return; fi
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && printf '%s' "$line" || printf '%s' "$default"
}

data_dir() { env_value RMM_DATA_DIR "$DEFAULT_DATA_DIR"; }

# ---------------------------------------------------------------------------
# Service helpers
# ---------------------------------------------------------------------------
COMPOSE_PROJECT="$(env_value COMPOSE_PROJECT_NAME teampresence)"

svc_container() {
    # The stack no longer hard-codes container_name, so resolve the real name
    # from compose rather than assuming "oem_api".
    dc ps --format '{{.Name}}' "$1" 2>/dev/null | head -n1
}

  wait_healthy() {
      # wait_healthy <service> [timeout_seconds]
      #
      # Distinguishes a slow start from a crash loop. A container that is
      # restarting reports health "unknown" indefinitely, so a naive loop just
      # burns the whole timeout and exits with no diagnosis -- which is exactly
      # what happened to the api container (gunicorn could not write its
      # heartbeat into a read-only /dev/shm) and to edge-nginx (no
      # certificate, so it refused to start).
      local service="$1" timeout="${2:-240}" waited=0 status restarts state
      log "waiting for $service to become healthy (timeout ${timeout}s)"
      local reported_down=0
      while (( waited < timeout )); do
          status="$(dc ps --format '{{.Health}}' "$service" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
          case "$status" in
              healthy)   ok "$service is healthy"; return 0 ;;
              unhealthy) dim "  $service reported unhealthy; still waiting..." ;;
              starting)  dim "  $service status: starting" ;;
              *)
                  # Not starting, not healthy, not unhealthy: the container is
                  # gone or restarting. Check for a restart loop and bail early
                  # with something actionable instead of polling silently.
                  restarts="$(dc ps --format '{{.Status}}' "$service" 2>/dev/null | tail -n1)"
                  if [[ -z "$restarts" ]]; then
                      err "$service has no container -- it exited and was not restarted"
                      (( reported_down )) || report_service_failure "$service"
                      return 1
                  fi
                  dim "  $service status: ${status:-unknown} (${restarts})"
                  if (( reported_down == 0 )); then
                      report_service_failure "$service"
                      reported_down=1
                  fi
                  ;;
          esac
          sleep 5
          waited=$((waited + 5))
      done
      err "$service did not become healthy within ${timeout}s"
      (( reported_down )) || report_service_failure "$service"
      return 1
  }

  # Show the tail of a service's logs. A failure that is only visible in the
  # logs -- a bad flag, a missing file, an nginx certificate error -- cannot be
  # diagnosed from the health status alone.
  report_service_failure() {
      local service="$1"
      err "last 20 log lines from $service:"
      dc logs --no-color --tail 20 "$service" 2>&1 | sed 's/^/    /' >&2 || \
          warn "  (could not read logs for $service)"
      echo >&2
  }

current_image() {
    # current_image <service> -> the image id the container is actually running
    local service="$1" container
    container="$(svc_container "$service")"
    [[ -n "$container" ]] || return 1
    docker inspect -f '{{.Image}}' "$container" 2>/dev/null
}

# Has this host ever had the stack deployed?
#
# Deliberately asks compose for container IDs rather than combining
# `ps -a --services --filter status=running`, which does not behave
# consistently across compose versions. An empty ID list means nothing was
# ever created, which is what distinguishes a first install from an update --
# the presence of docker/.env alone does not.
stack_exists() {
    local ids
    ids="$(dc ps -aq 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$ids" ]]
}

# Is the database up and reachable? Used to avoid pointless backup warnings on
# a machine that has never been deployed.
database_running() {
    local id
    id="$(dc ps -q mysql 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$id" ]]
}

# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------
run_migrations() {
    step "applying schema migrations"
    if dc_migrate run --rm migrate; then
        ok "migrations applied"
    else
        err "migration failed; leaving the running containers untouched"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Mutual exclusion
# ---------------------------------------------------------------------------
LOCK_FILE=""
acquire_lock() {
    local name="${1:-rmm}" ttl_minutes="${2:-60}"
    LOCK_FILE="$(data_dir)/${name}.lock"
    mkdir -p "$(dirname "$LOCK_FILE")"

    if [[ -f "$LOCK_FILE" ]]; then
        local age_minutes
        age_minutes=$(( ( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ) / 60 ))
        if (( age_minutes < ttl_minutes )); then
            die "another $(basename "$name") operation is already running (lock: $LOCK_FILE, age ${age_minutes}m)"
        fi
        warn "removing stale lock from ${age_minutes}m ago: $LOCK_FILE"
        rm -f "$LOCK_FILE"
    fi
    printf 'pid=%s\nstarted=%s\nhost=%s\n' "$$" "$(_ts)" "$(hostname)" > "$LOCK_FILE"
    trap 'release_lock' EXIT INT TERM
}

release_lock() {
    [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    return 0
}

confirm() {
    local prompt="$1"
    if [[ -t 0 ]]; then
        local reply
        read -r -p "${prompt} [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]]
    else
        # Non-interactive: require an explicit opt-in.
        [[ "${RMM_ASSUME_YES:-0}" == "1" ]]
    fi
}
