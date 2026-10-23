#!/usr/bin/env bash
#
# Validate and reload the edge Nginx after the application has written a new
# TLS/domain configuration.
#
# The API container does NOT do this itself. It has no access to the Docker
# socket (that was a root-equivalent capability inside the application) and
# cannot signal the host's Nginx process. Instead the application drops a
# marker file; this script, run on the host with the operator's own
# privileges, performs the reload.
#
# Usage:
#   ./scripts/domain-ssl-reload.sh          # validate, then reload
#   ./scripts/domain-ssl-reload.sh --check  # validate only, do not reload
#
# Environment:
#   COMPOSE_PROJECT_DIR  directory holding docker-compose.yml (default: <repo>/docker)
#   COMPOSE_FILE         compose file to use (default: $COMPOSE_PROJECT_DIR/docker-compose.prod.yml)
#   EDGE_SERVICE         edge nginx service name (default: edge-nginx)
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

COMPOSE_PROJECT_DIR="${COMPOSE_PROJECT_DIR:-$REPO_ROOT/docker}"
COMPOSE_FILE="${COMPOSE_FILE:-$COMPOSE_PROJECT_DIR/docker-compose.prod.yml}"
EDGE_SERVICE="${EDGE_SERVICE:-edge-nginx}"

CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

log()  { printf '[domain-ssl-reload] %s\n' "$*"; }
fail() { printf '[domain-ssl-reload] ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker CLI not found on PATH"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required (not found)"
[[ -f "$COMPOSE_FILE" ]] || fail "compose file not found: $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" ps --status running --services 2>/dev/null \
    | grep -qx "$EDGE_SERVICE" \
    || fail "service '$EDGE_SERVICE' is not running; run 'docker compose -f $COMPOSE_FILE up -d $EDGE_SERVICE' first"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

log "validating nginx configuration in '$EDGE_SERVICE'"
if ! config_out="$(compose exec -T "$EDGE_SERVICE" nginx -t 2>&1)"; then
    printf '%s\n' "$config_out" >&2
    fail "nginx configuration test FAILED — not reloading (running config is unchanged)"
fi
printf '%s\n' "$config_out"

if (( CHECK_ONLY )); then
    log "configuration is valid (--check given, not reloading)"
    exit 0
fi

log "reloading nginx"
if ! reload_out="$(compose exec -T "$EDGE_SERVICE" nginx -s reload 2>&1)"; then
    printf '%s\n' "$reload_out" >&2
    fail "nginx reload FAILED — the previous configuration is still live"
fi
printf '%s\n' "$reload_out"

# The application writes this marker; clear it so the next request is visible.
marker="${DOMAIN_SSL_CERT_DIR:-$REPO_ROOT/docker/certs}/reload-requested"
if [[ -f "$marker" ]]; then
    rm -f "$marker"
    log "cleared reload marker: $marker"
fi

log "done — edge TLS configuration is live"
