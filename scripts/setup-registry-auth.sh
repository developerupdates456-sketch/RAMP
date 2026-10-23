#!/usr/bin/env bash
#
# Create the registry credentials file that watchtower needs to pull images.
#
#   ./scripts/setup-registry-auth.sh
#
# Watchtower polls the registry itself. If the images are private (the default
# here -- ghcr.io/teampresence-production/...), every poll fails and no update
# is ever applied, silently.
#
# The credential is written to docker/watchtower-auth.json, which is
# .dockerignore'd and must never be committed. Mode 0600.
#
# To revoke access later, delete the file and restart the watchtower container:
#   sudo docker compose --env-file docker/.env -f docker/docker-compose.yml \
#        -f docker/docker-compose.prod.yml restart watchtower
#   ./scripts/roll-back-registry-auth.sh    # see DEPLOYMENT.md

set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

REGISTRY="${REGISTRY:-ghcr.io}"
AUTH_FILE="${WATCHTOWER_AUTH_FILE:-$COMPOSE_DIR/watchtower-auth.json}"

step "registry: $REGISTRY"

# Extract the stored password for a registry from a docker config file.
# Prints nothing if the file is missing, malformed, or has no usable entry.
read_token_from_file() {
    local file="$1" registry="$2"
    python3 - "$file" "$registry" <<'PYEOF' 2>/dev/null || true
import base64, json, sys

path, registry = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    entry = (cfg.get("auths") or {}).get(registry) or {}
    raw = entry.get("auth") or ""
    if raw:
        user, _, password = base64.b64decode(raw).decode().partition(":")
        if user and password:
            print(password)
except Exception:
    pass
PYEOF
}

# Validate the target before writing a credential into it.
if [[ ! "$REGISTRY" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    die "REGISTRY does not look like a hostname: $REGISTRY"
fi

# A GitHub token needs at least read:packages. Prefer an environment variable so
# the token is not typed into a shell history or echoed to the screen.
TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"

# Reuse the token already staged for watchtower, so routine re-runs do not
# prompt again. run-setup.sh is also the "apply a new push" path, and being
# asked for a token every time would be wrong.
if [[ -z "$TOKEN" && -s "$AUTH_FILE" ]]; then
    TOKEN="$(read_token_from_file "$AUTH_FILE" "$REGISTRY")"
    [[ -n "$TOKEN" ]] && ok "reusing the token already stored in $(basename "$AUTH_FILE")"
fi

if [[ -z "$TOKEN" ]] && [[ -t 0 ]]; then
    # Interactive: ask, rather than making the operator open a second shell and
    # remember an export. The images are private, so this is required on a
    # first deploy and again whenever the token is rotated.
    cat <<'EOF'
  The published images are private, so a registry token is required.

  Create a classic personal access token with the 'read:packages' scope:
      https://github.com/settings/tokens

  (A machine token for the repository with 'Read: packages' also works.)

  The token is stored in docker/watchtower-auth.json so that watchtower can
  keep polling for updates. It is not written into docker/.env.

EOF
    printf '  Paste the token (input hidden): '
    read -rs TOKEN
    printf '\n'
    if [[ -z "$TOKEN" ]]; then
        die "no token entered. Re-run when you have one, or set GHCR_TOKEN and re-run."
    fi
fi

if [[ -z "$TOKEN" ]]; then
    cat <<EOF
  No token available and stdin is not a terminal, so it cannot be prompted for.

  Export it and re-run:

      export GHCR_TOKEN='ghp_xxxxxxxxxxxx'
      $0
EOF
    exit 1
fi

if [[ ${#TOKEN} -lt 20 ]]; then
    die "GHCR_TOKEN looks too short to be a real token (${#TOKEN} chars)."
fi

# Verify the token before writing it, so a bad credential fails here with a
# clear message rather than as a silently-failing watchtower later.
if command -v curl >/dev/null 2>&1; then
    log "verifying the token against $REGISTRY ..."
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        -u "RMM_WATCHTOWER:${TOKEN}" \
        "https://${REGISTRY}/v2/" || echo 000)"
    case "$code" in
        200|401) : ;;                       # 200 = valid; 401 = reachable
        000)    die "cannot reach ${REGISTRY} (network/DNS problem?)" ;;
        *)      die "unexpected HTTP ${code} from ${REGISTRY}/v2/" ;;
    esac
    [[ "$code" == "200" ]] && ok "token accepted" \
        || warn "registry answered 401; watchtower may still fail to pull"
fi

umask 077
# `docker login` writes the exact credential format watchtower expects, which
# is not the same shape as a config.json for a specific server.
if docker login "$REGISTRY" --username RMM_WATCHTOWER --password-stdin < <(printf '%s' "$TOKEN") >/dev/null 2>&1; then
    :
else
    die "docker login failed; cannot generate a valid credential file"
fi

# Extract the auths block for just this registry.
python3 - "$AUTH_FILE" <<'PY'
import json, os, sys
dest = sys.argv[1]
src = os.path.join(os.path.expanduser("~"), ".docker", "config.json")
with open(src, encoding="utf-8") as fh:
    full = json.load(fh)
out = {"auths": full.get("auths", {})}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2)
os.chmod(dest, 0o600)
print(f"wrote {dest} ({os.path.getsize(dest)} bytes)")
PY

ok "registry credentials written to $AUTH_FILE (mode 0600)"

# Make sure the credential cannot be committed or baked into an image.
GITIGNORE="$REPO_ROOT/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
    if ! grep -q "watchtower-auth.json" "$GITIGNORE"; then
        printf '\n# watchtower registry credentials - never commit\ndocker/watchtower-auth.json\nwatchtower-auth.json\n' >> "$GITIGNORE"
        ok "added watchtower-auth.json to .gitignore"
    fi
else
    warn "no .gitignore; add docker/watchtower-auth.json manually"
fi

cat <<EOF

  Watchtower can now pull. Verify with:

    sudo docker compose --env-file docker/.env -f docker/docker-compose.yml \\
      -f docker/docker-compose.prod.yml logs -f watchtower

  It logs "Found new image" when an update is available, and "Stopping /
  Removing / Starting" when it applies one.
EOF
