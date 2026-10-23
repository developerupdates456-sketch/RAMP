#!/usr/bin/env bash
#
# Install Docker Engine + Compose v2 on Debian / Ubuntu.
#
#   sudo ./scripts/install-docker-engine.sh
#
# This is the *unattended server* installer. It uses Docker's official apt
# repository, installs the engine, enables it at boot, and verifies the result.
#
# It deliberately does NOT install Docker Desktop. Docker Desktop is a GUI
# product: it needs a desktop session, consumes more resources, and requires a
# paid subscription for organisations over 250 employees or $10M revenue. If you
# specifically want Docker Desktop on Debian, use ../setup-dashboard.sh instead.
#
# Idempotent: safe to re-run; existing installations are left alone.

set -Eeuo pipefail

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[1;32m[ok]\033[0m  %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "run as root, or install sudo."
    exec sudo -E bash "$0" "$@"
fi
export DEBIAN_FRONTEND=noninteractive

[[ -r /etc/os-release ]] || die "/etc/os-release not found."
. /etc/os-release

case "${ID:-}" in
    debian|ubuntu) : ;;
    *) die "this installer supports Debian and Ubuntu (found: ${ID:-unknown})." ;;
esac

ARCH="$(dpkg --print-architecture)"
CODENAME="${VERSION_CODENAME:-}"
log "detected ${PRETTY_NAME:-?} (${ARCH})"

# Docker's official repository ships amd64 / arm64 / armhf.
case "$ARCH" in
    amd64|arm64|armhf) : ;;
    *) die "unsupported architecture: $ARCH" ;;
esac

# --- Refuse to fight an existing Docker Desktop install ---------------------
if dpkg-query -W -f='${Status}' docker-desktop 2>/dev/null | grep -q "install ok installed"; then
    warn "Docker Desktop is installed."
    warn "Installing Docker Engine alongside it is not supported: both provide"
    warn "a 'docker' binary and they conflict. Choose one:"
    warn "    keep Desktop:  ./scripts/run-setup.sh   (it detects Desktop)"
    warn "    switch to Engine: sudo apt-get purge docker-desktop && sudo $0"
    confirm_ok=0
    [[ $FORCE -eq 1 ]] && confirm_ok=1
    (( confirm_ok )) || die "re-run with --force to install Engine anyway."
fi

# --- Prerequisites ----------------------------------------------------------
log "installing prerequisites"
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg uidmap iptables

# --- Repository + key -------------------------------------------------------
log "adding Docker's official apt repository"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    ok "repository key installed"
else
    ok "repository key already present"
fi

REPO_FILE="/etc/apt/sources.list.d/docker.sources"
cat > "$REPO_FILE" <<EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
ok "repository configured for ${CODENAME}"

# --- Engine -----------------------------------------------------------------
log "installing Docker Engine"
# docker-buildx and docker-compose are what this deployment needs: the
# frontend image uses --mount=type=cache, and compose v2 is required.
apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
ok "engine installed"

log "enabling the daemon at boot"
systemctl enable --now docker
ok "docker.service enabled and started"

# --- Verify -----------------------------------------------------------------
log "verifying"
docker --version
docker compose version
log "waiting for the daemon to answer"
for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then ok "daemon is responding"; break; fi
    printf '.'; sleep 1
done
echo
if ! docker info >/dev/null 2>&1; then
    die "docker is installed but the daemon is not responding.
       Check:  journalctl -u docker -n 50 --no-pager"
fi

# Test the exit code, not the output: an empty `docker ps -q` is what you get
# both when there are no containers and when the command is denied, so testing
# for emptiness reported success in the failing case.
if docker ps >/dev/null 2>&1; then
    ok "permission OK (able to talk to the daemon)"
else
    warn "cannot talk to the daemon as $(id -un); add yourself to the docker group:"
    warn "    sudo usermod -aG docker \$(id -un)   # then log out and back in"
fi

enabled_state="$(systemctl is-enabled docker.service 2>/dev/null || echo unknown)"

cat <<EOF

Docker Engine is installed and starts automatically on boot
(docker.service is enabled: ${enabled_state}).

Next:
  sudo ./scripts/run-setup.sh

EOF
