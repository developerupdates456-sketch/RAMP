#!/usr/bin/env bash
#
# One-command deployment for the RMM Platform.
#
#   ./scripts/run-setup.sh
#
# Prerequisites (NOT handled here):
#   * Docker Engine must already be installed. On Debian/Ubuntu:
#         sudo ./scripts/install-docker-engine.sh
#   * The deployment folder must be in place. No git clone is needed -- the
#     application images are pulled from the registry, so only the deployment
#     files are required (see DEPLOYMENT.md, "What to copy to the client").
#
# This script:
#
#   1. waits for the Docker daemon to answer
#   2. detects the host's LAN address
#   3. generates docker/.env with that address already filled in
#   4. registers a systemd unit so the stack returns after a reboot
#   5. pulls the published image, migrates, starts, and waits for health
#
# There is nothing to edit by hand. It is safe to run repeatedly.
#
# ---------------------------------------------------------------------------
# OPTIONS
# ---------------------------------------------------------------------------
#   --ip=ADDR     override LAN address detection (also: LAN_IP=ADDR)
#   --pull        pull the published image (default)
#   --build       build locally instead of pulling
#   --tag=TAG     image tag to deploy (default: latest)
#   --reinstall   re-create containers even if already running
#   --no-autostart  do not register the systemd unit
#   --print-bundle  list the files this deployment needs, then exit
#   -h|--help     this text

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

PULL_IMAGES=1
AUTOSTART=1
FORCE_RECREATE=0
TAG_OVERRIDE="${TAG:-}"
IP_OVERRIDE="${LAN_IP:-}"
PRINT_BUNDLE=0

while (( $# )); do
    case "$1" in
        --ip=*)         IP_OVERRIDE="${1#--ip=}" ;;
        --pull)         PULL_IMAGES=1 ;;
        --build)        PULL_IMAGES=0 ;;
        --tag=*)        TAG_OVERRIDE="${1#--tag=}" ;;
        --reinstall)    FORCE_RECREATE=1 ;;
        --no-autostart) AUTOSTART=0 ;;
        --print-bundle) PRINT_BUNDLE=1 ;;
        -h|--help)      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

SERVICE_NAME="rmm-stack"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE_BASE="${IMAGE_BASE:-teampresence-production/ramp_linux}"


if (( PRINT_BUNDLE )); then
    cat <<EOF
Copy these to the client machine, preserving the layout:

  docker/          compose files + .env.example
  nginx/           edge proxy configuration
  mysql/           my.cnf, init scripts, TLS certs
  security/        (create; secrets are generated on the host)
  scripts/         automation scripts, incl. docker-autostart.sh

Then on the client:

  sudo ./scripts/install-docker-engine.sh   # install Docker Engine
  sudo ./scripts/run-setup.sh               # detect IP, pull, migrate, start

  backend/ and frontend/ are NOT required -- the images are pulled.
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Detect the host's LAN address.
# ---------------------------------------------------------------------------
# Deliberately not "the first address from `hostname -I`": that also lists the
# Docker bridge (172.17.0.1), and picking the wrong one produces a node that
# reports an address no browser on the network can open.
#
# The reliable signal is the source address the kernel would use to leave the
# machine, or failing that, the address on the interface that owns the default
# route.
detect_lan_ip() {
    local ip=""

    ip="$(ip route get 1.1.1.1 2>/dev/null |
          awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
    if [[ -z "$ip" ]]; then
        local iface
        iface="$(ip route show default 2>/dev/null | awk '/^default/ { print $5; exit }')"
        if [[ -n "$iface" ]]; then
            ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null |
                  awk '{ split($4, a, "/"); print a[1]; exit }')"
        fi
    fi
    if [[ -z "$ip" ]]; then
        # Last resort: first non-loopback IPv4, skipping Docker interfaces.
        ip="$(hostname -I 2>/dev/null | tr ' ' '\n' |
              grep -E '^[0-9]+\.' | grep -v '^127\.' | head -n1)"
    fi
    printf '%s' "$ip"
}

# Root is required: this enables a systemd unit, creates bind-mount directories
# and chowns them to the container UIDs. Without it the script used to fail
# partway through with bare "permission denied" messages.
if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "must run as root: sudo $0 ${*:-}"
    log "re-running with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
step "1/4  Docker"
# ---------------------------------------------------------------------------
# Docker is a prerequisite and is not installed here. If it is missing the
# message points at setup-dashboard.sh rather than offering to install it.
if ! command -v docker >/dev/null 2>&1; then
    die "docker command not found.
       Install Docker Engine first:   sudo ./scripts/install-docker-engine.sh
       then re-run:                   sudo ./scripts/run-setup.sh"
fi

docker compose version >/dev/null 2>&1 \
    || die "docker compose v2 is missing. Install it with:
       sudo ./scripts/install-docker-engine.sh"

wait_for_docker 120 \
    || die "the Docker daemon did not respond within 120s.
       Check:  systemctl status docker
               journalctl -u docker -n 50 --no-pager"
log "docker: $(docker version --format 'server {{.Server.Version}}' 2>/dev/null)"

# ---------------------------------------------------------------------------
step "2/4  configuration"
# ---------------------------------------------------------------------------
[[ -f "$COMPOSE_DIR/.env.example" ]] \
    || die "missing $COMPOSE_DIR/.env.example -- the deployment folder looks incomplete."

LAN_IP_VALUE="${IP_OVERRIDE:-$(detect_lan_ip)}"
[[ -n "$LAN_IP_VALUE" ]] \
    || die "could not detect a LAN address. Pass it explicitly:  $0 --ip=192.168.1.50"
ok "LAN address: $LAN_IP_VALUE"

BOOTSTRAP_ORIGIN="http://${LAN_IP_VALUE}"

if [[ -f "$COMPOSE_DIR/.env" ]]; then
    log "docker/.env exists; updating the LAN address if it changed"
    FIRST_INSTALL=0
else
    FIRST_INSTALL=1
    log "generating docker/.env"
    cp "$COMPOSE_DIR/.env.example" "$COMPOSE_DIR/.env"
    chmod 600 "$COMPOSE_DIR/.env"
fi

# A .env on its own does not mean the stack was ever deployed. If the api
# container has never existed, this is still a first install -- and it must take
# the install path, because the update path starts by backing up a database
# that is not running yet.
if (( ! FIRST_INSTALL )) && ! stack_exists; then
    FIRST_INSTALL=1
    log "no containers have ever been created -- treating this as a first install"
fi

# Set-or-replace a KEY=value in the env file.
set_env() {
    local key="$1" value="$2" file="$COMPOSE_DIR/.env"
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        # Escape & and | in the replacement so sed does not treat them specially.
        local esc; esc="$(printf '%s' "$value" | sed -e 's/[&|]/\\&/g')"
        sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${esc}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# The origin the browser will actually use, so the SPA and the API agree.
set_env LAN_IP            "$LAN_IP_VALUE"
set_env BOOTSTRAP_ORIGINS  "$BOOTSTRAP_ORIGIN"
set_env REGISTRY          "$REGISTRY"
set_env IMAGE_BASE        "$IMAGE_BASE"
set_env TAG               "${TAG_OVERRIDE:-latest}"

# ---------------------------------------------------------------------------
# Registry credentials
# ---------------------------------------------------------------------------
# The images are private, so a pull without a token fails with a bare
# "unauthorized" from the registry. Prompt for the token here, before the
# deploy, and stage it for watchtower at the same time -- one step covers both.
if (( PULL_IMAGES )); then
    # Idempotent: if docker/watchtower-auth.json already holds a working token
    # this only re-logs the daemon in, and does not prompt again. That matters
    # because run-setup.sh is also the "apply a new push" path.
    "$SCRIPTS_DIR/setup-registry-auth.sh" \
        || die "could not obtain registry credentials, so the images cannot be pulled."
fi

# Watchtower polls the same tag the containers run. 300s == every 5 minutes.
set_env WATCHTOWER_POLL_INTERVAL "300"

# Credentials the platform cannot generate for itself.
missing=0
for f in firebase_key.json servicedesk_key.json; do
    [[ -s "$SECURITY_DIR/secrets/$f" ]] || { err "missing security/secrets/$f"; missing=1; }
done
if (( missing )); then
    die "Copy the service-account JSON files into security/secrets/ and re-run:
         cp <firebase_key.json>    security/secrets/firebase_key.json
         cp <servicedesk_key.json> security/secrets/servicedesk_key.json
         chmod 600 security/secrets/*.json"
fi
ok "service-account credentials present"

# The remaining credentials are generated on first run by setup-production.sh.
[[ -d "$SECURITY_DIR/secrets" ]] && chmod 700 "$SECURITY_DIR/secrets"

# ---------------------------------------------------------------------------
step "3/4  boot persistence"
# ---------------------------------------------------------------------------
register_autostart() {
    if (( ! AUTOSTART )); then
        dim "autostart disabled (--no-autostart)"; return 0
    fi
    if [[ ! -d /run/systemd/system ]]; then
        dim "systemd is not PID 1; start the stack manually after a reboot"
        return 0
    fi
    # With Docker Engine, docker.service is a system service, so
    # `After=docker.service` is meaningful and the daemon is normally up before
    # this unit runs.
    #
    # start-production.sh still waits for the daemon rather than assuming it.
    # That wait is the actual guarantee: systemd ordering is best-effort, and a
    # host that still has Docker Desktop installed (a per-USER service a root
    # unit cannot be ordered against) would otherwise race every reboot.
    cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=RMM Platform (TeamPresence)
Documentation=file://${REPO_ROOT}/DEPLOYMENT.md
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${REPO_ROOT}
ExecStart=${REPO_ROOT}/scripts/start-production.sh
ExecStop=${REPO_ROOT}/scripts/stop-production.sh
TimeoutStartSec=1200

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME.service" >/dev/null 2>&1 \
        && ok "enabled ${SERVICE_NAME}.service (starts on boot)" \
        || warn "could not enable ${SERVICE_NAME}.service; start it manually"
}
register_autostart

# ---------------------------------------------------------------------------
step "4/4  deploy"
# ---------------------------------------------------------------------------
# Already up and healthy? Nothing to do.
running="$(dc ps --services --filter status=running 2>/dev/null | wc -l || echo 0)"
if (( running >= 4 )) && (( ! FORCE_RECREATE )); then
    log "stack already running ($running services); verifying"
    if "$SCRIPTS_DIR/health-check.sh"; then
        ok "nothing to do"
        printf '\n  URL: %s\n' "$BOOTSTRAP_ORIGIN"
        exit 0
    fi
    warn "health check failed; re-deploying"
fi

if (( FIRST_INSTALL )); then
    (( PULL_IMAGES )) && exec "$SCRIPTS_DIR/setup-production.sh" --pull
    exec "$SCRIPTS_DIR/setup-production.sh"
fi

if (( PULL_IMAGES )); then
    exec "$SCRIPTS_DIR/update-production.sh" --pull
fi
exec "$SCRIPTS_DIR/start-production.sh"
