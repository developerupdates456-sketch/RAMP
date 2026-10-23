#!/usr/bin/env bash
#
# Install / bootstrap the RMM Platform on a Linux Docker Engine host.
#
#   sudo ./scripts/setup-production.sh
#
# This is idempotent: running it again on an existing install re-applies the
# configuration and recreates the containers without touching data.
#
# What it does, in order:
#   1. preflight        (host, Docker, memory, required files)
#   2. secrets          create any missing credential files
#   3. storage          create the data directories with correct ownership
#   4. build            build the images (or pull them if --pull is given)
#   5. migrate          apply schema revisions explicitly
#   6. start            bring the stack up and wait for health
#   7. report           print the URLs and the next steps
#
# It does NOT configure TLS. That is a separate, deliberate step
# (scripts/domain-ssl-apply.sh) so the node is usable over plain HTTP on the
# LAN before a certificate exists.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

PULL_IMAGES=0
SKIP_BUILD=0
while (( $# )); do
    case "$1" in
        --pull)   PULL_IMAGES=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
step "1/7  preflight"
# ---------------------------------------------------------------------------
require_root
require_cmd docker
require_docker

if [[ ! -f "$COMPOSE_DIR/.env" ]]; then
    err "docker/.env is not configured."
    err "Start from the example and set at least LAN_IP / BOOTSTRAP_ORIGINS:"
    err "    cp docker/.env.example docker/.env"
    err "    \${EDITOR:-vi} docker/.env"
    exit 1
fi

total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ -n "$total_mb" ]] && (( total_mb < 3072 )); then
    warn "only ${total_mb} MiB of RAM detected."
    warn "api + worker + mysql + 2 nginx will contend; 4 GiB is a practical floor."
fi

cpu_count=$(nproc 2>/dev/null || echo 1)
log "host: $(nproc 2>/dev/null || echo '?') cpu, ${total_mb:-?} MiB RAM, docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
log "data dir: $(data_dir)"

# ---------------------------------------------------------------------------
step "2/7  secrets"
# ---------------------------------------------------------------------------
mkdir -p "$SECURITY_DIR/secrets"
chmod 700 "$SECURITY_DIR/secrets"

gen_secret() {
    # gen_secret <file> [bytes]
    local file="$SECURITY_DIR/secrets/$1" bytes="${2:-48}"
    if [[ -s "$file" ]]; then
        dim "  present: $1"
        return 0
    fi
    # openssl if available, else the kernel CSPRNG via /dev/urandom.
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes" > "$file"
    else
        head -c $((bytes * 2)) /dev/urandom | od -An -tx1 | tr -d ' \n' > "$file"
        printf '\n' >> "$file"
    fi
    chmod 600 "$file"
    ok "  created: $1"
}

gen_secret mysql_root_password 32
gen_secret mysql_app_password 32
gen_secret jwt_secret_key 48
gen_secret encryption_key 32

# The two JSON service-account files cannot be generated; they must be supplied.
for f in firebase_key.json servicedesk_key.json; do
    if [[ ! -s "$SECURITY_DIR/secrets/$f" ]]; then
        err "missing $f"
        err "  Copy the service-account JSON from the credential owner into"
        err "  security/secrets/$f and chmod 600 it, then re-run."
        exit 1
    fi
    chmod 600 "$SECURITY_DIR/secrets/$f"
    dim "  present: $f"
done

# ---------------------------------------------------------------------------
step "3/7  storage directories"
# ---------------------------------------------------------------------------
DATA="$(data_dir)"
mkdir -p "$DATA"/{mysql/data,mysql/backups,logs,uploads,certs,domain-ssl-backups}

# The api and worker run as uid 1000. The bind mounts must be writable by them
# or the worker will fail its heartbeat probe at startup.
if [[ -n "$DATA" ]]; then
    chown -R 1000:1000 "$DATA"/{logs,uploads} 2>/dev/null \
        || warn "could not chown logs/uploads; set $(id -u):$(id -g) on them manually"
    chmod 0750 "$DATA"/{logs,uploads}
fi
# mysql writes as its own uid (999 in the official image).
chown -R 999:999 "$DATA"/mysql 2>/dev/null || warn "could not chown mysql dirs (set uid 999)"
# Certificates and their backups are read by nginx; keep them private.
chmod 0700 "$DATA"/certs "$DATA"/domain-ssl-backups
ok "storage ready under $DATA"

# ---------------------------------------------------------------------------
step "4/7  images"
# ---------------------------------------------------------------------------
if (( PULL_IMAGES )); then
    log "pulling published images for TAG=$(env_value TAG latest)"
    dc pull || die "image pull failed; check REGISTRY/IMAGE_BASE/TAG in docker/.env"
    ok "images pulled"
elif (( SKIP_BUILD )); then
    log "skipping build (--skip-build)"
else
    log "building api image"
    docker build -f docker/Dockerfile.prod \
        -t "${REGISTRY:-ghcr.io}/${IMAGE_BASE:-teampresence-production/ramp_linux}-api:local" . \
        || die "api build failed"
    log "building frontend image"
    docker build -f docker/Dockerfile.prod.frontend \
        -t "${REGISTRY:-ghcr.io}/${IMAGE_BASE:-teampresence-production/ramp_linux}-frontend:local" ./frontend \
        || die "frontend build failed"

    # Compose resolves the image tag from TAG in docker/.env. The images just
    # built are tagged :local, so point TAG at them -- otherwise the stack would
    # start a different (pulled, or stale) image and this build would be wasted.
    if [[ "$(env_value TAG latest)" != "local" ]]; then
        log "setting TAG=local in docker/.env so the stack uses what we just built"
        if grep -qE '^[[:space:]]*TAG=' "$COMPOSE_DIR/.env"; then
            sed -i -E "s|^[[:space:]]*TAG=.*|TAG=local|" "$COMPOSE_DIR/.env"
        else
            printf '\nTAG=local\n' >> "$COMPOSE_DIR/.env"
        fi
    fi
    ok "images built (TAG=local)"
fi

# ---------------------------------------------------------------------------
step "5/7  schema migrations"
# ---------------------------------------------------------------------------
dc up -d mysql
if ! wait_healthy mysql 120; then
    err "mysql did not become healthy; cannot continue."
    err "Inspect with: docker compose ... logs mysql"
    exit 1
fi
run_migrations || exit 1

# ---------------------------------------------------------------------------
step "6/7  start"
# ---------------------------------------------------------------------------
dc up -d
ok "containers created"

for svc in mysql api worker frontend edge-nginx; do
    if ! wait_healthy "$svc" 240; then
        err "$svc is not healthy. Recent logs:"
        dc logs --tail 50 "$svc" >&2
        err ""
        err "The stack is up but not serving. Fix the cause and re-run, or"
        err "roll back with: ./scripts/rollback.sh"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
step "7/7  done"
# ---------------------------------------------------------------------------
lan="$(env_value LAN_IP '')"
domain="$(env_value DOMAIN '')"
if [[ -n "$domain" ]]; then
    base_url="https://$domain"
elif [[ -n "$lan" ]]; then
    base_url="http://$lan"
else
    base_url="http://localhost"
fi

ok "RMM Platform is running"
printf '\n'
printf '  URL        %s\n' "$base_url"
printf '  API health %s/api/health\n' "$base_url"
printf '  Compose    %s\n' "cd $REPO_ROOT && docker compose --env-file docker/.env -f docker/docker-compose.yml -f docker/docker-compose.prod.yml ps"
printf '\n'
cat <<EOF
  Next steps
    1. Check it from a browser:   $base_url
    2. Add TLS once DNS is ready:
         ./scripts/domain-ssl-apply.sh rmm.example.com
       then set ALLOW_BOOTSTRAP_ORIGINS=false in docker/.env and re-run
       this script to enforce the strict allowlist.
    3. Schedule a database backup (see scripts/db-backup.sh).
    4. Read DEPLOYMENT.md for the operational runbook.

  The credentials in security/secrets/ were generated just now. Back them up
  off-host: they are not recoverable from the containers, and rotating them
  invalidates every stored session and encrypted value.
EOF
