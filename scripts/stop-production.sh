#!/usr/bin/env bash
#
# Stop the RMM Platform (containers are kept, data is untouched).
#
#   sudo ./scripts/stop-production.sh
#
# Use this for a planned shutdown. For an update use update-production.sh,
# which recycles services one at a time instead of taking the whole node down.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

KEEP_RUNNING=0
while (( $# )); do
    case "$1" in
        --keep-running) KEEP_RUNNING=1 ;;   # stop autostart, leave it up
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

require_docker
require_stack

if (( KEEP_RUNNING )); then
    step "disabling boot autostart"
    if [[ -d /run/systemd/system ]]; then
        systemctl disable rmm-stack.service >/dev/null 2>&1 \
            && ok "rmm-stack.service disabled (it will not start on boot)" \
            || dim "no systemd unit to disable"
    fi
fi

step "stopping services"
# Stop the application tier before the data tier so in-flight requests drain
# while the database is still available.
for svc in edge-nginx frontend api worker mysql; do
    dc stop "$svc" 2>/dev/null && dim "  stopped $svc" || warn "  could not stop $svc"
done

ok "stack stopped; volumes and data are untouched"
cat <<EOF

  Start again with:  ./scripts/start-production.sh
EOF
