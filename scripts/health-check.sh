#!/usr/bin/env bash
#
# Check that the RMM Platform is actually serving, not just running.
#
#   ./scripts/health-check.sh          # human readable
#   ./scripts/health-check.sh --quiet  # only report failures (for monitoring)
#
# Exit code 0 = healthy, 1 = something is wrong. Suitable for a cron job or an
# external uptime probe.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

FAILURES=0
pass() { (( QUIET )) || printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES+1)); }
info() { (( QUIET )) || printf '  ....  %s\n' "$*"; }

require_docker
require_stack

# ---------------------------------------------------------------------------
step "containers"
# ---------------------------------------------------------------------------
# Expected services and the image they should be running.
declare -A EXPECTED=(
    [mysql]=healthy
    [api]=healthy
    [worker]=healthy
    [frontend]=healthy
    [edge-nginx]=healthy
)

for svc in "${!EXPECTED[@]}"; do
    state="$(dc ps --format '{{.State}}' "$svc" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    health="$(dc ps --format '{{.Health}}' "$svc" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    if [[ "$state" != "running" ]]; then
        fail "$svc is not running (state=${state:-absent})"
        continue
    fi
    if [[ "${EXPECTED[$svc]}" == "healthy" && "$health" != "healthy" ]]; then
        fail "$svc is running but health=$health"
    else
        pass "$svc running${health:+ (health=$health)}"
    fi
done

# ---------------------------------------------------------------------------
step "api"
# ---------------------------------------------------------------------------
# Reach the API through the edge proxy the same way a browser would, so this
# also proves the proxy and TLS are wired up.
domain="$(env_value DOMAIN '')"
lan="$(env_value LAN_IP '')"
if [[ -n "$domain" ]]; then
    base="https://$domain"
elif [[ -n "$lan" ]]; then
    base="http://$lan"
else
    base="http://localhost"
fi

api_probe() {
    # The database-backed liveness route is registered at /health, not
    # /api/health -- there is no /api prefix on it. Probing /api/health could
    # only ever 404, so a failure here was ambiguous: it looked like a proxy or
    # CORS problem when it was simply the wrong path.
    #
    # /health is answered by nginx itself from proxy-locations.inc, so hitting
    # it through the edge proves the proxy is routing, but not that the app
    # answers. Probe a real API endpoint for that.
    curl -fsS --max-time 10 "$base/api/rate-limiter-status" 2>/dev/null
}

if api_probe >/tmp/rmm-health.$$ 2>/dev/null; then
    pass "GET $base/api/rate-limiter-status -> $(head -c 120 /tmp/rmm-health.$$)"
else
    fail "GET $base/api/rate-limiter-status failed through the edge proxy"
    warn "  this proves the proxy routed /api/ to the API container. If the"
    warn "  containers are healthy, check the route table:"
    warn "    python3 scripts/check_proxy_routes.py nginx/conf.d"
fi
rm -f /tmp/rmm-health.$$

# The database-backed health is the one that matters; a static /health on nginx
# proves nothing.
if dc exec -T mysql mysqladmin ping -h 127.0.0.1 \
        -u root -p"$(cat "$SECURITY_DIR/secrets/mysql_root_password" 2>/dev/null)" >/dev/null 2>&1; then
    pass "mysql responding to admin ping"
else
    fail "mysql admin ping failed"
fi

# ---------------------------------------------------------------------------
step "worker heartbeat"
# ---------------------------------------------------------------------------
# The worker binds no port, so its health is the heartbeat file. If the worker
# thread pool is wedged, this is the only signal that shows it.
hb_file="${WORKER_HEARTBEAT_FILE:-$(data_dir)/logs/worker-heartbeat.json}"
# The file lives on the host at the logs bind mount; the container path differs.
host_hb="$(data_dir)/logs/worker-heartbeat.json"
if [[ -f "$host_hb" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$host_hb") ))
    if (( age < 180 )); then
        pass "worker heartbeat is ${age}s old"
    else
        fail "worker heartbeat is stale (${age}s). The scheduler may be blocked."
    fi
else
    fail "no worker heartbeat at $host_hb (worker may not be running, or logs volume not shared)"
fi

# ---------------------------------------------------------------------------
step "disk"
# ---------------------------------------------------------------------------
DATA="$(data_dir)"
if [[ -d "$DATA" ]]; then
    used_pct=$(df -P "$DATA" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    if   (( used_pct >= 90 )); then fail "disk ${used_pct}% full on $DATA"
    elif (( used_pct >= 80 )); then info "disk ${used_pct}% used on $DATA (watch this)"
    else pass "disk ${used_pct}% used on $DATA"
    fi
else
    info "data dir $DATA not present on this host (remote docker?)"
fi

# ---------------------------------------------------------------------------
step "watchtower"
# ---------------------------------------------------------------------------
# Not fatal if absent (auto-update is optional), but if it IS running it must
# actually be able to poll -- a watchtower that fails every pull looks healthy
# and silently never updates anything.
wt="$(svc_container watchtower)"
if [[ -z "$wt" ]]; then
    info "watchtower not running (automatic image updates are disabled)"
elif [[ ! -f "$COMPOSE_DIR/watchtower-auth.json" ]]; then
    fail "watchtower is running but $COMPOSE_DIR/watchtower-auth.json is missing;"
    fail "  every poll will fail. Run ./scripts/setup-registry-auth.sh"
else
    pass "watchtower running with registry credentials present"
fi

# ---------------------------------------------------------------------------
step "result"
# ---------------------------------------------------------------------------
if (( FAILURES == 0 )); then
    printf '\n\033[32mAll checks passed.\033[0m\n'
    exit 0
else
    printf '\n\033[31m%d check(s) failed.\033[0m\n' "$FAILURES"
    printf 'Diagnostics:  ./scripts/diagnostics.sh\n'
    exit 1
fi
