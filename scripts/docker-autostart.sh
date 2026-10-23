#!/usr/bin/env bash
#
# Enable Docker to start automatically on boot, and verify it will.
#
#   sudo ./scripts/docker-autostart.sh
#   sudo ./scripts/docker-autostart.sh --user=alice     # explicit account
#   sudo ./scripts/docker-autostart.sh --check          # report only, change nothing
#
# Why this is a separate script
# ----------------------------
# "Docker" is two different products with two completely different boot models,
# and getting this wrong is the single most common reason a containerised
# service does not come back after a reboot:
#
#   Docker ENGINE   a normal system service (`docker.service`). `systemctl
#                   enable docker` is all that is required. Runs as root,
#                   starts at boot, no desktop session, no licence.
#                   THIS IS THE SUPPORTED PATH for this deployment: it is what
#                   scripts/install-docker-engine.sh installs, and it is the
#                   only option with no interactive first-run step.
#
#   Docker DESKTOP  a *user-session* application. `docker-desktop.service`
#                   lives in the USER's systemd manager, not the system one.
#                   It will not start at boot unless:
#                     1. the account is allowed to run services without logging
#                        in  ->  loginctl enable-linger <user>
#                     2. the unit is enabled in that user manager
#                     3. the Docker Subscription Service Agreement has been
#                        accepted ONCE in the GUI
#                   Miss (3) and the service silently fails on every boot.
#
# This script handles whichever is installed, and reports honestly which case
# it found.
#
# Idempotent: safe to run repeatedly.

set -Eeuo pipefail

MODE="enable"      # enable | check
TARGET_USER=""
WAIT_SECONDS=180

while (( $# )); do
    case "$1" in
        --user=*)      TARGET_USER="${1#--user=}" ;;
        --check)       MODE="check" ;;
        --timeout=*)   WAIT_SECONDS="${1#--timeout=}" ;;
        -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[1;32m[ok]\033[0m  %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m  %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "must run as root: sudo $0"

dpkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# ---------------------------------------------------------------------------
# Which Docker is this?
# ---------------------------------------------------------------------------
DOCKER_KIND=""
detect_kind() {
    if dpkg_installed docker-desktop; then
        DOCKER_KIND="desktop"
    elif [[ -f /etc/systemd/system/docker.service ]] \
         || dpkg_installed docker-ce || dpkg_installed docker.io \
         || command -v dockerd >/dev/null 2>&1; then
        DOCKER_KIND="engine"
    else
        DOCKER_KIND="none"
    fi
}

# ---------------------------------------------------------------------------
# Run a command inside the target user's systemd session.
# ---------------------------------------------------------------------------
UID_OF_USER=""
BUS=""
init_user_session() {
    local user="$1"
    id "$user" >/dev/null 2>&1 || die "user '$user' does not exist."
    UID_OF_USER="$(id -u "$user")"
    loginctl show-user "$user" -p Linger --value 2>/dev/null | grep -q yes || return 1
    # The user manager must actually be up before `systemctl --user` will work.
    systemctl start "user@${UID_OF_USER}.service" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        [[ -S "/run/user/${UID_OF_USER}/bus" ]] && { BUS="/run/user/${UID_OF_USER}/bus"; return 0; }
        sleep 1
    done
    return 1
}

as_user() {
    runuser -u "$1" -- env \
        "XDG_RUNTIME_DIR=/run/user/${UID_OF_USER}" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=${BUS}" \
        "${@:2}"
}

# ---------------------------------------------------------------------------
# Docker ENGINE
# ---------------------------------------------------------------------------
configure_engine() {
    log "Docker Engine detected: /etc/systemd/system/docker.service"

    if (( MODE == check )); then
        local state; state="$(systemctl is-enabled docker.service 2>/dev/null || echo unknown)"
        if [[ "$state" == "enabled" ]]; then
            ok "docker.service is enabled at boot"
        else
            warn "docker.service is '$state' -- it will NOT start on boot"
        fi
        return 0
    fi

    systemctl enable docker.service >/dev/null 2>&1 \
        && ok "docker.service enabled at boot" \
        || die "could not enable docker.service"

    if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
        systemctl enable containerd.service >/dev/null 2>&1 \
            && ok "containerd.service enabled at boot" || warn "could not enable containerd.service"
    fi

    # Make sure it is running now too, not just next boot.
    if ! systemctl is-active --quiet docker.service; then
        log "starting docker.service now"
        systemctl start docker.service || warn "docker.service did not start; check: journalctl -u docker"
    fi
}

# ---------------------------------------------------------------------------
# Docker DESKTOP
# ---------------------------------------------------------------------------
configure_desktop() {
    log "Docker Desktop detected"

    local user="${TARGET_USER:-${SUDO_USER:-}}"
    if [[ -z "$user" || "$user" == "root" ]]; then
        # Pick the first non-system login account rather than giving up.
        user="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1; exit }' /etc/passwd)"
    fi
    [[ -n "$user" ]] || die "no non-root user found.
       Docker Desktop is a per-user application and needs an account to run as.
       Re-run with:  $0 --user=<name>"

    log "enabling boot start for user: $user (uid $(id -u "$user"))"

    if (( MODE == check )); then
        local linger; linger="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || echo no)"
        [[ "$linger" == "yes" ]] && ok "linger is enabled" \
                                || warn "linger is '$linger' -- services will not start at boot"
        if init_user_session "$user"; then
            if as_user "$user" systemctl --user is-enabled --quiet docker-desktop 2>/dev/null; then
                ok "docker-desktop.service is enabled for $user"
            else
                warn "docker-desktop.service is not enabled for $user"
            fi
        else
            warn "could not start the systemd session for $user"
        fi
        return 0
    fi

    # 1. Linger -- without this the user manager never starts at boot, because
    #    nobody logs in on a server.
    if [[ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null || echo no)" == "yes" ]]; then
        ok "linger already enabled for $user"
    else
        loginctl enable-linger "$user" && ok "linger enabled for $user" \
            || die "could not enable linger for $user"
    fi

    # 2. Bring up the user session so `systemctl --user` is usable.
    init_user_session "$user" \
        || die "could not start the systemd session for $user (no /run/user/$(id -u "$user")/bus)"

    # 3. Enable the unit in the USER manager.
    if as_user "$user" systemctl --user is-enabled --quiet docker-desktop 2>/dev/null; then
        ok "docker-desktop.service already enabled for $user"
    elif as_user "$user" systemctl --user enable docker-desktop >/dev/null 2>&1; then
        ok "docker-desktop.service enabled for $user"
    else
        warn "per-user enable failed; falling back to systemctl --global enable"
        systemctl --global enable docker-desktop >/dev/null 2>&1 \
            && ok "docker-desktop.service enabled globally" \
            || die "could not enable docker-desktop.service by any method"
    fi

    # 4. Start it now and confirm it actually comes up.
    if as_user "$user" systemctl --user is-active --quiet docker-desktop 2>/dev/null; then
        ok "docker-desktop is running now"
    else
        log "starting docker-desktop now"
        as_user "$user" systemctl --user start docker-desktop >/dev/null 2>&1 || true
    fi

    # 5. Wait for the daemon to answer. This is also the real test of whether
    #    the subscription agreement has been accepted: Docker Desktop refuses to
    #    run until it has, and the failure is otherwise invisible until reboot.
    log "waiting for the Docker daemon to answer (timeout ${WAIT_SECONDS}s)"
    for i in $(seq 1 "$WAIT_SECONDS"); do
        if docker info >/dev/null 2>&1; then
            ok "daemon is up (${i}s)"
            break
        fi
        if [[ $i -eq $WAIT_SECONDS ]]; then
            warn "the Docker daemon never became ready."
            cat >&2 <<EOF

  Most likely cause: the Docker Subscription Service Agreement has not been
  accepted yet. Docker Desktop will not start until it has, and this is a
  one-time interactive step:

      su - $user
      docker-desktop            # or launch it from the Applications menu
      # accept the agreement in the GUI, then quit

  Re-run this script afterwards to confirm.

  Or, for an unattended server, install plain Docker Engine instead -- no GUI,
  no licence, and it starts at boot on its own:

      sudo ./scripts/install-docker-engine.sh
      sudo ./scripts/docker-autostart.sh
EOF
            return 1
        fi
        printf '.'; sleep 1
    done
    echo
}

# ---------------------------------------------------------------------------
main() {
    detect_kind
    log "found: ${DOCKER_KIND}"

    case "$DOCKER_KIND" in
        engine)  configure_engine ;;
        desktop) configure_desktop ;;
        none)
            die "Docker is not installed.
       Install Docker Engine:   sudo ./scripts/install-docker-engine.sh
       then re-run:             sudo ./scripts/docker-autostart.sh"
            ;;
    esac

    log "Summary"
    printf '  docker kind        : %s\n' "$DOCKER_KIND"
    case "$DOCKER_KIND" in
        engine)
            printf '  docker.service     : %s\n' "$(systemctl is-enabled docker.service 2>/dev/null || echo unknown)"
            printf '  running now        : %s\n' "$(systemctl is-active docker.service 2>/dev/null || echo unknown)"
            ;;
        desktop)
            local u="${TARGET_USER:-${SUDO_USER:-}}"
            printf '  docker-desktop user: %s\n' "${u:-unknown}"
            printf '  linger             : %s\n' "$([[ -n "$u" ]] && loginctl show-user "$u" -p Linger --value 2>/dev/null || echo unknown)"
            printf '  daemon reachable   : %s\n' "$(docker info >/dev/null 2>&1 && echo yes || echo no)"
            ;;
    esac
    printf '\n'
}

main
