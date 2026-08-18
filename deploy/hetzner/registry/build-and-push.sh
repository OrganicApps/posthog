#!/usr/bin/env bash
#
# Builds the Django/frontend image from the current posthog/ checkout (wherever your
# source edits — e.g. swapped logo/branding assets under frontend/src/ — already live)
# and pushes it to the local registry. Run this ON THE SERVER, from the deploy root
# (the registry is 127.0.0.1-only, so this can't run from your laptop).
#
# The Node image (posthog-node) is NOT rebuilt here — it's the backend ingestion
# workers, which don't serve any frontend assets, so the unmodified mirrored copy
# (localhost:5000/posthog-node:latest, from mirror-images.sh) is reused as-is.
#
# Usage (from /opt/posthog-platform, after deploy.sh has cloned posthog/ at least once):
#   cd /opt/posthog-platform
#   ./posthog/deploy/hetzner/registry/build-and-push.sh
#
# Then redeploy pointing at the custom image:
#   DOMAIN=ph.myorganicapps.com REGISTRY_URL=localhost:5000/posthog \
#     POSTHOG_APP_TAG=custom POSTHOG_NODE_TAG=latest \
#     /root/hetzner-deploy/deploy.sh
#
set -euo pipefail

LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5000}"
TAG="${TAG:-custom}"
SOURCE_DIR="${SOURCE_DIR:-./posthog}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: $SOURCE_DIR not found — run this from the deploy root (/opt/posthog-platform) after deploy.sh has run at least once." >&2
    exit 1
fi

IMAGE="${LOCAL_REGISTRY}/posthog:${TAG}"

echo "Building $IMAGE from $SOURCE_DIR (this includes the frontend build — expect several minutes)..."
docker build -t "$IMAGE" "$SOURCE_DIR"

echo "Pushing $IMAGE..."
docker push "$IMAGE"

echo ""
echo "Done. To deploy this image:"
echo "  DOMAIN=<your-domain> REGISTRY_URL=${LOCAL_REGISTRY}/posthog POSTHOG_APP_TAG=${TAG} POSTHOG_NODE_TAG=latest /root/hetzner-deploy/deploy.sh"
