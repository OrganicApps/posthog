#!/usr/bin/env bash
#
# Builds the PostHog MCP server (services/mcp) from the current posthog/ checkout and
# pushes it to the local registry. Not part of upstream's published images at all —
# PostHog runs their own copy of this as a separate hosted service, so this is always
# a local build, unlike the digest-pinned Rust services which have a real upstream
# default to fall back to.
#
# Build context is the REPO ROOT (not services/mcp/), same as the Dockerfile requires
# (it installs through the pnpm workspace, so it needs the workspace manifests).
#
# Usage (from /opt/posthog-platform, after deploy.sh has cloned posthog/ at least once):
#   cd /opt/posthog-platform
#   ./posthog/deploy/hetzner/registry/build-mcp.sh
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

IMAGE="${LOCAL_REGISTRY}/posthog-mcp:${TAG}"

echo "=== Building posthog-mcp -> $IMAGE (pnpm workspace install + Hono bundle, expect several minutes) ==="
docker build -f "$SOURCE_DIR/services/mcp/Dockerfile" -t "$IMAGE" "$SOURCE_DIR"
docker push "$IMAGE"

echo ""
echo "Done. docker-compose.pin.yml's mcp service defaults to exactly this image/tag"
echo "(localhost:5000/posthog-mcp:custom) — no extra env var needed on the next deploy"
echo "unless you used a different TAG, in which case pass MCP_IMAGE=${IMAGE}."
