#!/usr/bin/env bash
#
# Deploys PostHog on the Hetzner box. Run as root over SSH (bootstrap.sh must have
# already run at least once — Docker + docker-volume-local-persist need to be up).
#
# Rebuilds the exact directory layout bin/deploy-hobby produces, because
# docker-compose.hobby.yml's bind mounts (./posthog/docker/clickhouse/..., etc.)
# hard-assume it: $DEPLOY_DIR/posthog/ is a full clone, and
# docker-compose.base.yml/docker-compose.yml sit one level up from it. Unlike
# bin/deploy-hobby, this clones OUR fork (OrganicApps/posthog) at a pinned ref, not
# upstream PostHog/posthog — otherwise deploy/hetzner/* itself would never make it
# onto the server.
#
# Secrets: POSTHOG_SECRET / ENCRYPTION_SALT_KEYS / BROWSERLESS_SECRET are generated
# ONCE into .env.secrets on first run and never touched again (mirrors bin/deploy-hobby's
# own guard) — losing this file means losing the ability to decrypt existing encrypted
# DB fields and invalidates all sessions, so regenerating it is never safe on a live
# instance. Everything else (domain, image tags, Sentry DSN, AI keys) is rewritten into
# .env on every deploy from the environment variables below.
#
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/posthog-platform}"

# ---------------------------------------------------------------------------
# 0. Persistent extra config/secrets — so optional values (Sentry, AI keys,
#    Google OAuth, custom image overrides) don't need to be re-typed/re-passed
#    on every invocation. Lives in $DEPLOY_DIR (the actual deploy root, same
#    place as the persistent .env.secrets) — deliberately NOT in
#    ~/hetzner-deploy, which only holds the scripts themselves and gets
#    replaced wholesale by every scp/checkout. Uses `: "${VAR:=value}"` style
#    assignments (see .env.extra.example) so a value explicitly passed to
#    THIS invocation still wins over what's stored here; the file only fills
#    in what's not already set.
# ---------------------------------------------------------------------------
if [ -f "$DEPLOY_DIR/.env.extra" ]; then
    # shellcheck disable=SC1091
    source "$DEPLOY_DIR/.env.extra"
fi

: "${DOMAIN:?set DOMAIN, e.g. example.com}"
POSTHOG_REPO_URL="${POSTHOG_REPO_URL:-https://github.com/OrganicApps/posthog.git}"
POSTHOG_REF="${POSTHOG_REF:-hetzner-deploy}"
POSTHOG_APP_TAG="${POSTHOG_APP_TAG:-latest}"
POSTHOG_NODE_TAG="${POSTHOG_NODE_TAG:-$POSTHOG_APP_TAG}"
REGISTRY_URL="${REGISTRY_URL:-posthog/posthog}"
SESSION_RECORDING_RETENTION="${SESSION_RECORDING_RETENTION:-30d}"
SENTRY_DSN="${SENTRY_DSN:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
SOCIAL_AUTH_GOOGLE_OAUTH2_KEY="${SOCIAL_AUTH_GOOGLE_OAUTH2_KEY:-}"
SOCIAL_AUTH_GOOGLE_OAUTH2_SECRET="${SOCIAL_AUTH_GOOGLE_OAUTH2_SECRET:-}"
MULTI_ORG_ENABLED="${MULTI_ORG_ENABLED:-}"
TLS_STAGING="${TLS_STAGING:-}"          # set to any non-empty value to use LE staging (testing only)
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-60}"   # 60 * 10s = 10 minutes, matches upstream's own budget
HEALTH_CHECK_DELAY="${HEALTH_CHECK_DELAY:-10}"

# Optional per-service Rust image overrides (default: the digest pins baked into
# docker-compose.pin.yml). Set one of these to a locally-built image — e.g.
# CAPTURE_IMAGE=localhost:5000/capture:custom — after running
# registry/build-and-push.sh. Left unset, docker-compose.pin.yml's own
# ${VAR:-digest} defaults apply.
MCP_IMAGE="${MCP_IMAGE:-}"
CAPTURE_IMAGE="${CAPTURE_IMAGE:-}"
CAPTURE_LOGS_IMAGE="${CAPTURE_LOGS_IMAGE:-}"
PROPERTY_DEFS_RS_IMAGE="${PROPERTY_DEFS_RS_IMAGE:-}"
FEATURE_FLAGS_IMAGE="${FEATURE_FLAGS_IMAGE:-}"
PERSONHOG_REPLICA_IMAGE="${PERSONHOG_REPLICA_IMAGE:-}"
PERSONHOG_ROUTER_IMAGE="${PERSONHOG_ROUTER_IMAGE:-}"
HYPERCACHE_SERVER_IMAGE="${HYPERCACHE_SERVER_IMAGE:-}"
CYCLOTRON_JANITOR_IMAGE="${CYCLOTRON_JANITOR_IMAGE:-}"
CYMBAL_IMAGE="${CYMBAL_IMAGE:-}"

log() { echo "[deploy] $*"; }

mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# ---------------------------------------------------------------------------
# 1. Clone/update our fork at the pinned ref into ./posthog
# ---------------------------------------------------------------------------
if [ ! -d posthog/.git ]; then
    log "Cloning $POSTHOG_REPO_URL @ $POSTHOG_REF"
    git clone --filter=blob:none --branch "$POSTHOG_REF" "$POSTHOG_REPO_URL" posthog
else
    log "Updating existing checkout to $POSTHOG_REF"
    (cd posthog && git fetch origin "$POSTHOG_REF" && git checkout "$POSTHOG_REF" && git reset --hard "origin/$POSTHOG_REF")
fi
POSTHOG_COMMIT="$(cd posthog && git rev-parse --short HEAD)"
log "posthog/ is at commit $POSTHOG_COMMIT"

# ---------------------------------------------------------------------------
# 2. Stage compose files at deploy root (mirrors bin/deploy-hobby's own layout)
# ---------------------------------------------------------------------------
cp posthog/docker-compose.base.yml docker-compose.base.yml
cp posthog/docker-compose.hobby.yml docker-compose.yml
cp posthog/.env.services .env.services
cp posthog/deploy/hetzner/docker-compose.pin.yml docker-compose.pin.yml

rm -rf compose
cp -r posthog/deploy/hetzner/compose compose
chmod +x compose/start compose/wait compose/temporal-django-worker

# ---------------------------------------------------------------------------
# 3. GeoIP DB (same source as bin/deploy-hobby)
# ---------------------------------------------------------------------------
mkdir -p ./share
if [ ! -f ./share/GeoLite2-City.mmdb ]; then
    log "Downloading GeoLite2-City.mmdb"
    apt-get update -qq && apt-get install -y -qq brotli
    curl -L 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > ./share/GeoLite2-City.mmdb
    chmod 644 ./share/GeoLite2-City.mmdb
fi

# ---------------------------------------------------------------------------
# 4. Secrets — generated once each, never regenerated on a live instance. Each
#    key is checked independently (not "file exists ? skip all : generate all")
#    so a secret added in a later version of this script gets appended to an
#    existing .env.secrets on next deploy, without touching the ones already
#    there — losing/rotating POSTHOG_SECRET or ENCRYPTION_SALT_KEYS invalidates
#    sessions and encrypted DB fields, so that guard has to hold per-key forever.
# ---------------------------------------------------------------------------
touch .env.secrets
umask 077
chmod 600 .env.secrets

ensure_secret() {
    local key="$1" value="$2"
    if ! grep -q "^${key}=" .env.secrets 2>/dev/null; then
        log "Generating $key (first time this deploy tooling has needed it)"
        echo "${key}=${value}" >> .env.secrets
    fi
}

ensure_secret POSTHOG_SECRET "$(head -c 28 /dev/urandom | sha224sum -b | head -c 56)"
ensure_secret ENCRYPTION_SALT_KEYS "$(openssl rand -hex 16)"
ensure_secret BROWSERLESS_SECRET "$(openssl rand -hex 32)"
ensure_secret MCP_SIGNED_STATE_KEY "$(openssl rand -hex 32)"

# ---------------------------------------------------------------------------
# 5. Rebuild .env every deploy: persisted secrets + this run's config. Save the
#    previous .env for rollback.
# ---------------------------------------------------------------------------
[ -f .env ] && cp .env .env.prev

TLS_BLOCK=""
if [ -n "$TLS_STAGING" ]; then
    TLS_BLOCK="acme_ca https://acme-staging-v02.api.letsencrypt.org/directory"
fi

umask 077
{
    cat .env.secrets
    echo "DOMAIN=$DOMAIN"
    echo "TLS_BLOCK=$TLS_BLOCK"
    echo "CADDY_TLS_BLOCK=$TLS_BLOCK"
    echo "CADDY_HOST=$DOMAIN, http://, https://"
    echo "REGISTRY_URL=$REGISTRY_URL"
    echo "POSTHOG_APP_TAG=$POSTHOG_APP_TAG"
    echo "POSTHOG_NODE_TAG=$POSTHOG_NODE_TAG"
    [ -n "$SENTRY_DSN" ] && echo "SENTRY_DSN=$SENTRY_DSN"
    [ -n "$ANTHROPIC_API_KEY" ] && echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
    [ -n "$OPENAI_API_KEY" ] && echo "OPENAI_API_KEY=$OPENAI_API_KEY"
    [ -n "$SOCIAL_AUTH_GOOGLE_OAUTH2_KEY" ] && echo "SOCIAL_AUTH_GOOGLE_OAUTH2_KEY=$SOCIAL_AUTH_GOOGLE_OAUTH2_KEY"
    [ -n "$SOCIAL_AUTH_GOOGLE_OAUTH2_SECRET" ] && echo "SOCIAL_AUTH_GOOGLE_OAUTH2_SECRET=$SOCIAL_AUTH_GOOGLE_OAUTH2_SECRET"
    [ -n "$MULTI_ORG_ENABLED" ] && echo "MULTI_ORG_ENABLED=$MULTI_ORG_ENABLED"
    [ -n "$MCP_IMAGE" ] && echo "MCP_IMAGE=$MCP_IMAGE"
    [ -n "$CAPTURE_IMAGE" ] && echo "CAPTURE_IMAGE=$CAPTURE_IMAGE"
    [ -n "$CAPTURE_LOGS_IMAGE" ] && echo "CAPTURE_LOGS_IMAGE=$CAPTURE_LOGS_IMAGE"
    [ -n "$PROPERTY_DEFS_RS_IMAGE" ] && echo "PROPERTY_DEFS_RS_IMAGE=$PROPERTY_DEFS_RS_IMAGE"
    [ -n "$FEATURE_FLAGS_IMAGE" ] && echo "FEATURE_FLAGS_IMAGE=$FEATURE_FLAGS_IMAGE"
    [ -n "$PERSONHOG_REPLICA_IMAGE" ] && echo "PERSONHOG_REPLICA_IMAGE=$PERSONHOG_REPLICA_IMAGE"
    [ -n "$PERSONHOG_ROUTER_IMAGE" ] && echo "PERSONHOG_ROUTER_IMAGE=$PERSONHOG_ROUTER_IMAGE"
    [ -n "$HYPERCACHE_SERVER_IMAGE" ] && echo "HYPERCACHE_SERVER_IMAGE=$HYPERCACHE_SERVER_IMAGE"
    [ -n "$CYCLOTRON_JANITOR_IMAGE" ] && echo "CYCLOTRON_JANITOR_IMAGE=$CYCLOTRON_JANITOR_IMAGE"
    [ -n "$CYMBAL_IMAGE" ] && echo "CYMBAL_IMAGE=$CYMBAL_IMAGE"
} > .env
chmod 600 .env

# ---------------------------------------------------------------------------
# 6. Bring the stack up
# ---------------------------------------------------------------------------
COMPOSE="docker compose -f docker-compose.base.yml -f docker-compose.yml -f docker-compose.pin.yml"

log "Pulling images and starting stack..."
if ! $COMPOSE up -d --pull always --remove-orphans; then
    log "docker compose up failed — attempting rollback to previous .env"
    if [ -f .env.prev ]; then
        mv .env.prev .env
        $COMPOSE up -d --remove-orphans || true
    fi
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Health check, with rollback on failure
# ---------------------------------------------------------------------------
log "Waiting for /_health (up to $((HEALTH_CHECK_RETRIES * HEALTH_CHECK_DELAY))s)..."
healthy=false
for i in $(seq 1 "$HEALTH_CHECK_RETRIES"); do
    if curl -sf -o /dev/null "http://localhost/_health"; then
        healthy=true
        break
    fi
    sleep "$HEALTH_CHECK_DELAY"
done

if [ "$healthy" = true ]; then
    log "Healthy after deploy (commit $POSTHOG_COMMIT, tag $POSTHOG_APP_TAG)"
else
    log "ERROR: /_health did not return 200 in time"
    $COMPOSE logs --tail 100
    if [ -f .env.prev ] && ! cmp -s .env .env.prev; then
        log "Rolling back to previous .env"
        mv .env.prev .env
        $COMPOSE up -d --remove-orphans
        sleep 30
        if curl -sf -o /dev/null "http://localhost/_health"; then
            log "Rollback succeeded"
        else
            log "ERROR: rollback did not recover health — manual intervention needed"
        fi
    else
        log "No usable .env.prev — cannot roll back automatically"
    fi
    exit 1
fi

# ---------------------------------------------------------------------------
# 8. Session-replay retention — self-hosted defaults new teams to 5y, which is
#    effectively "keep forever" at this event volume. Idempotent: safe to run
#    every deploy.
# ---------------------------------------------------------------------------
log "Setting session_recording_retention_period=$SESSION_RECORDING_RETENTION for all teams"
$COMPOSE exec -T web python manage.py shell -c "
from posthog.models import Team
Team.objects.exclude(session_recording_retention_period='$SESSION_RECORDING_RETENTION').update(session_recording_retention_period='$SESSION_RECORDING_RETENTION')
print('done')
" || log "WARNING: could not set retention (non-fatal, check manually)"

log "Deploy complete: https://$DOMAIN"
