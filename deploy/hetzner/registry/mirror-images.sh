#!/usr/bin/env bash
#
# Pulls the exact images this deployment depends on from Docker Hub/ghcr.io, retags
# them into the local registry (docker-compose.yml in this directory), and pushes.
# Run from the server, after `docker compose up -d` in this directory.
#
# Prints resolved digests at the end — copy these into ../docker-compose.pin.yml's
# TODO placeholders for the floating :master images (see that file's header comment).
#
set -euo pipefail

LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5000}"
POSTHOG_APP_TAG="${POSTHOG_APP_TAG:-latest}"
POSTHOG_NODE_TAG="${POSTHOG_NODE_TAG:-latest}"

# Django + Node images (posthog/posthog, posthog/posthog-node)
DOCKERHUB_IMAGES=(
    "posthog/posthog:${POSTHOG_APP_TAG}"
    "posthog/posthog-node:${POSTHOG_NODE_TAG}"
)

# The ~10 Rust services hardcoded to :master upstream (see docker-compose.pin.yml)
GHCR_IMAGES=(
    "ghcr.io/posthog/posthog/capture:master"
    "ghcr.io/posthog/posthog/capture-logs:master"
    "ghcr.io/posthog/posthog/property-defs-rs:master"
    "ghcr.io/posthog/posthog/feature-flags:master"
    "ghcr.io/posthog/posthog/personhog-replica:master"
    "ghcr.io/posthog/posthog/personhog-router:master"
    "ghcr.io/posthog/posthog/hypercache-server:master"
    "ghcr.io/posthog/posthog/cyclotron-janitor:master"
    "ghcr.io/posthog/posthog/cymbal:master"
)

echo "digest_report=" > /tmp/mirror-digests.txt

mirror() {
    local src="$1"
    # Strip registry/org prefix, keep image name + tag for the local copy:
    # e.g. posthog/posthog:latest -> localhost:5000/posthog:latest
    #      ghcr.io/posthog/posthog/capture:master -> localhost:5000/capture:master
    local name_tag="${src##*/}"
    local dest="${LOCAL_REGISTRY}/${name_tag}"

    echo "=== $src -> $dest ==="
    docker pull "$src"
    docker tag "$src" "$dest"
    docker push "$dest"

    local digest
    digest=$(docker inspect --format '{{index .RepoDigests 0}}' "$src")
    echo "$src  =>  $digest" | tee -a /tmp/mirror-digests.txt
}

for img in "${DOCKERHUB_IMAGES[@]}" "${GHCR_IMAGES[@]}"; do
    mirror "$img"
done

echo ""
echo "Done. Resolved digests (for pinning :master in ../docker-compose.pin.yml):"
cat /tmp/mirror-digests.txt
