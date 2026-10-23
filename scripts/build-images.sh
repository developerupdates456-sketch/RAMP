#!/usr/bin/env bash
#
# Build the api and frontend images locally.
#
#   ./scripts/build-images.sh              # build both, tagged :local
#   ./scripts/build-images.sh api          # build just the api
#   ./scripts/build-images.sh --no-cache   # rebuild from scratch
#
# The api and worker share one image; there is no separate worker build.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-common.sh"

NO_CACHE=0
ONLY=""
while (( $# )); do
    case "$1" in
        --no-cache) NO_CACHE=1 ;;
        api|frontend) ONLY="$1" ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

require_cmd docker
IMAGE_BASE="${IMAGE_BASE:-teampresence-production/ramp_linux}"
TAG="${TAG:-local}"
CACHE_ARG=""
(( NO_CACHE )) && CACHE_ARG="--no-cache"

build() {
    local name="$1" dockerfile="$2" context="$3"
    step "building $IMAGE_BASE-$name:$TAG"
    # shellcheck disable=SC2086
    docker build $CACHE_ARG \
        -f "$dockerfile" \
        -t "$IMAGE_BASE-$name:$TAG" \
        -t "$IMAGE_BASE-$name:local" \
        "$context" || die "$name build failed"
    ok "$name built"
}

if [[ -z "$ONLY" || "$ONLY" == "api" ]]; then
    build api "$REPO_ROOT/docker/Dockerfile.prod" "$REPO_ROOT"
fi
if [[ -z "$ONLY" || "$ONLY" == "frontend" ]]; then
    build frontend "$REPO_ROOT/docker/Dockerfile.prod.frontend" "$REPO_ROOT/frontend"
fi

ok "done"
echo "Point the stack at these with:  TAG=local (in docker/.env)"
