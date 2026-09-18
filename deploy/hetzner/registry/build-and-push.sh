#!/usr/bin/env bash
#
# Builds every image this deployment runs from the current posthog/ checkout
# (wherever your source edits already live) and pushes them all to the local
# registry. Run this ON THE SERVER, from the deploy root (the registry is
# 127.0.0.1-only, so this can't run from your laptop).
#
# Builds:
#   - posthog        (Django/frontend, root Dockerfile)
#   - posthog-node   (Node ingestion workers, Dockerfile.node)
#   - the 9 Rust services docker-compose.pin.yml runs, each from rust/Dockerfile
#     with --build-arg BIN=<service> (context ./rust/, matching .github/rust-images.yml)
#
# Usage (from /opt/posthog-platform, after deploy.sh has cloned posthog/ at least once):
#   cd /opt/posthog-platform
#   ./posthog/deploy/hetzner/registry/build-and-push.sh
#
# Build only a subset (space-separated service names, matching the keys below):
#   SERVICES="posthog cymbal" ./posthog/deploy/hetzner/registry/build-and-push.sh
#
# Then redeploy pointing at the custom images — this prints the exact command
# at the end, with every *_IMAGE var set to what was just built. Any image left
# unbuilt keeps docker-compose.pin.yml's pinned-digest default.
#
set -euo pipefail

LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5000}"
TAG="${TAG:-custom}"
SOURCE_DIR="${SOURCE_DIR:-./posthog}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: $SOURCE_DIR not found — run this from the deploy root (/opt/posthog-platform) after deploy.sh has run at least once." >&2
    exit 1
fi

export DOCKER_BUILDKIT=1

# Rust service -> env var docker-compose.pin.yml reads for its image override.
# BIN is the same as the service name for all of these (see .github/rust-images.yml —
# none of them set an explicit `bin:` override).
RUST_SERVICES=(
    "capture:CAPTURE_IMAGE"
    "capture-logs:CAPTURE_LOGS_IMAGE"
    "property-defs-rs:PROPERTY_DEFS_RS_IMAGE"
    "feature-flags:FEATURE_FLAGS_IMAGE"
    "personhog-replica:PERSONHOG_REPLICA_IMAGE"
    "personhog-router:PERSONHOG_ROUTER_IMAGE"
    "hypercache-server:HYPERCACHE_SERVER_IMAGE"
    "cyclotron-janitor:CYCLOTRON_JANITOR_IMAGE"
    "cymbal:CYMBAL_IMAGE"
)

ALL_SERVICES="posthog posthog-node capture capture-logs property-defs-rs feature-flags personhog-replica personhog-router hypercache-server cyclotron-janitor cymbal"
SERVICES="${SERVICES:-$ALL_SERVICES}"

wants() {
    [[ " $SERVICES " == *" $1 "* ]]
}

# Collects the env-var assignments to print at the end, only for what was built.
DEPLOY_ENV=()

if wants posthog; then
    IMAGE="${LOCAL_REGISTRY}/posthog:${TAG}"
    echo "=== Building posthog (Django/frontend) -> $IMAGE (expect several minutes) ==="
    docker build -t "$IMAGE" "$SOURCE_DIR"
    docker push "$IMAGE"
    DEPLOY_ENV+=("REGISTRY_URL=${LOCAL_REGISTRY}/posthog" "POSTHOG_APP_TAG=${TAG}")
fi

if wants posthog-node; then
    IMAGE="${LOCAL_REGISTRY}/posthog-node:${TAG}"
    echo "=== Building posthog-node -> $IMAGE ==="
    docker build -t "$IMAGE" -f "$SOURCE_DIR/Dockerfile.node" "$SOURCE_DIR"
    docker push "$IMAGE"
    DEPLOY_ENV+=("POSTHOG_NODE_TAG=${TAG}")
fi

for entry in "${RUST_SERVICES[@]}"; do
    svc="${entry%%:*}"
    env_var="${entry##*:}"
    if wants "$svc"; then
        IMAGE="${LOCAL_REGISTRY}/${svc}:${TAG}"
        echo "=== Building $svc -> $IMAGE ==="
        docker build --build-arg "BIN=${svc}" -t "$IMAGE" -f "$SOURCE_DIR/rust/Dockerfile" "$SOURCE_DIR/rust/"
        docker push "$IMAGE"
        DEPLOY_ENV+=("${env_var}=${IMAGE}")
    fi
done

echo ""
echo "Done. To deploy these images:"
echo "  DOMAIN=<your-domain> ${DEPLOY_ENV[*]} /root/hetzner-deploy/deploy.sh"
echo ""
echo "Any *_IMAGE / *_TAG var left out of this run keeps docker-compose.pin.yml's"
echo "existing default (pinned upstream digest, or previous custom build)."
