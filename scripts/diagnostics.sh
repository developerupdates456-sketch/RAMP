#!/usr/bin/env bash
#
# Collect diagnostics for a misbehaving deployment.
#
#   ./scripts/diagnostics.sh            # summary
#   ./scripts/diagnostics.sh --logs 200 # include more log lines
#
# Read-only: this script inspects and reports, and never changes state. It is
# safe to run on a live production node. Output is redacted -- see the note
# before pasting it into a ticket.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

LOG_LINES=50
[[ "${1:-}" == "--logs" ]] && LOG_LINES="${2:-200}"

require_docker
require_stack

hr() { printf '\n\033[36m%s\033[0m\n' "=== $* ==="; }

# ---------------------------------------------------------------------------
hr "host"
# ---------------------------------------------------------------------------
printf 'host      : %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'kernel    : %s\n' "$(uname -r)"
printf 'os        : %s\n' "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
printf 'cpus      : %s\n' "$(nproc 2>/dev/null || echo '?')"
printf 'memory    : %s\n' "$(awk '/MemTotal|MemAvailable/ {printf "%s=%dMiB ", $1, $2/1024}' /proc/meminfo)"
printf 'docker    : %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
printf 'compose   : %s\n' "$(docker compose version --short 2>/dev/null || echo unavailable)"
printf 'date      : %s\n' "$(date -Is)"

hr "disk"
df -hT / /var/lib/docker 2>/dev/null | sort -u || df -hT /

# ---------------------------------------------------------------------------
hr "compose config (rendered)"
# ---------------------------------------------------------------------------
dc config 2>/dev/null | grep -E "^\s*(image|container_name|user|read_only|privileged|network_mode):" \
    | head -60 || warn "could not render compose config"

# ---------------------------------------------------------------------------
hr "services"
# ---------------------------------------------------------------------------
dc ps 2>/dev/null || warn "could not list services"

# ---------------------------------------------------------------------------
hr "health detail"
# ---------------------------------------------------------------------------
for svc in mysql api worker frontend edge-nginx; do
    container="$(svc_container "$svc")"
    if [[ -z "$container" ]]; then
        printf '%-12s (not created)\n' "$svc"
        continue
    fi
    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$container" 2>/dev/null)"
    restarts="$(docker inspect -f '{{.RestartCount}}' "$container" 2>/dev/null)"
    printf '%-12s state=%-10s health=%-10s restarts=%s\n' "$svc" "$state" "$health" "$restarts"

    # Show the last few healthcheck probe results; a failing probe is usually
    # the whole story.
    docker inspect -f '{{range .State.Health.Log}}    {{.ExitCode}} {{.Output}}{{"\n"}}{{end}}' \
        "$container" 2>/dev/null | tail -n 6 | sed 's/^/      /'
done

# ---------------------------------------------------------------------------
hr "resource usage"
# ---------------------------------------------------------------------------
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null \
    | head -20 || warn "docker stats unavailable"

# ---------------------------------------------------------------------------
hr "recent logs"
# ---------------------------------------------------------------------------
for svc in edge-nginx api worker mysql; do
    hr "$svc (last ${LOG_LINES})"
    dc logs --tail "$LOG_LINES" --no-color "$svc" 2>&1 | tail -n "$LOG_LINES" || true
done

# ---------------------------------------------------------------------------
hr "worker heartbeat"
# ---------------------------------------------------------------------------
hb="$(data_dir)/logs/worker-heartbeat.json"
if [[ -f "$hb" ]]; then
    printf 'path : %s\n' "$hb"
    printf 'age  : %ss\n' "$(( $(date +%s) - $(stat -c %Y "$hb") ))"
    printf 'body : %s\n' "$(cat "$hb")"
else
    warn "no heartbeat at $hb"
fi

# ---------------------------------------------------------------------------
hr "database size"
# ---------------------------------------------------------------------------
if [[ -s "$SECURITY_DIR/secrets/mysql_root_password" ]]; then
    pw="$(cat "$SECURITY_DIR/secrets/mysql_root_password")"
    dc exec -T mysql mysql -u root -p"$pw" -e 'SHOW DATABASES;' 2>/dev/null | sed 's/^/  /' || true
    dc exec -T mysql mysql -u root -p"$pw" -N -e \
        "SELECT table_schema, ROUND(SUM(data_length+index_length)/1048576) FROM information_schema.tables GROUP BY 1;" 2>/dev/null \
        | sed 's/^/  /' || true
else
    info "root password file not readable; skipping database size"
fi

cat <<'EOF'

=== REDACTION NOTICE ===
The output above may contain host names, IP addresses, internal URLs, and
container log lines that include customer identifiers or device addresses.
Review it before attaching to a ticket or pasting into a chat.
EOF
