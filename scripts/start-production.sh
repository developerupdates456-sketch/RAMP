#!/usr/bin/env bash
#
# Start (or restart) the RMM Platform.
#
#   sudo ./scripts/start-production.sh
#
# This does NOT migrate and does NOT build. For a first install or an upgrade
# use setup-production.sh / update-production.sh, which do both in the correct
# order. This script is for an ordinary "bring it back up" after a reboot.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

require_cmd docker
docker compose version >/dev/null 2>&1 \
    || die "docker compose v2 is required (the 'docker compose' subcommand)"

# The account that owns Docker Desktop, for the rare host that still has it
# installed. Empty on the supported Docker Engine path, so the nudge below is
# simply skipped. To enable it on such a host, set RMM_DOCKER_USER=<name> in
# docker/.env.
#
# Exported (not merely read from docker/.env) because wait_for_docker runs in
# a different function and needs it in its environment.
RMM_DOCKER_USER="$(env_value RMM_DOCKER_USER '')"
export RMM_DOCKER_USER
if [[ -n "$RMM_DOCKER_USER" ]]; then
    dim "Docker Desktop user: $RMM_DOCKER_USER"
fi
# Wait rather than checking once: this script is what the rmm-stack systemd unit
# runs at boot, and the daemon is not guaranteed to be up yet. See
# wait_for_docker() in lib-common.sh.
wait_for_docker 300 \
    || die "the Docker daemon did not become ready within 300s.
       Check it with:  ./scripts/docker-autostart.sh --check
       (on Docker Desktop this is usually the subscription agreement not yet
        accepted -- see the message from that script)"
require_stack

step "starting the stack"
dc up -d || die "docker compose up failed"

for svc in mysql api worker frontend edge-nginx; do
    wait_healthy "$svc" 300 || {
        err "$svc is not healthy:"
        dc logs --tail 40 "$svc" >&2
        exit 1
    }
done

ok "all services healthy"
dc ps
