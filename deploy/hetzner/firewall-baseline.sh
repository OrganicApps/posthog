#!/usr/bin/env bash
#
# ONE-TIME, MANUAL script. Run from your own machine (NOT from CI, NOT from the server
# itself) after the server has been ordered and has a public IP, before the first
# deploy. Sets the static Hetzner Robot Firewall baseline: 80/443 open, 22 only from
# the VPN egress IP, default discard. The GitHub Actions workflow (hetzner-deploy.yml)
# temporarily punches an extra 22/tcp rule for its own runner IP on top of this baseline
# for the duration of each deploy, then removes it — see that workflow for the dynamic
# half of this.
#
# Usage:
#   HETZNER_ROBOT_USER=... HETZNER_ROBOT_PASSWORD=... SERVER_IP=... VPN_EGRESS_IP=... \
#     ./firewall-baseline.sh
#
set -euo pipefail

: "${HETZNER_ROBOT_USER:?set HETZNER_ROBOT_USER (Robot webservice account, not your Robot login password if 2FA is on — create a webservice user in Robot > Settings > Webservice)}"
: "${HETZNER_ROBOT_PASSWORD:?set HETZNER_ROBOT_PASSWORD}"
: "${SERVER_IP:?set SERVER_IP to the server's public IPv4}"
: "${VPN_EGRESS_IP:?set VPN_EGRESS_IP to the static admin SSH allowlist IP}"

BASE_URL="https://robot-ws.your-server.de/firewall/${SERVER_IP}"

echo "Current firewall state for ${SERVER_IP}:"
curl -s -u "${HETZNER_ROBOT_USER}:${HETZNER_ROBOT_PASSWORD}" "$BASE_URL"
echo

echo "Applying baseline ruleset..."
curl -s -u "${HETZNER_ROBOT_USER}:${HETZNER_ROBOT_PASSWORD}" -X POST "$BASE_URL" \
    --data-urlencode "status=active" \
    --data-urlencode "whitelist_hos=true" \
    --data-urlencode "rules[input][0][name]=Allow HTTPS" \
    --data-urlencode "rules[input][0][dst_port]=443" \
    --data-urlencode "rules[input][0][protocol]=tcp" \
    --data-urlencode "rules[input][0][action]=accept" \
    --data-urlencode "rules[input][1][name]=Allow HTTP" \
    --data-urlencode "rules[input][1][dst_port]=80" \
    --data-urlencode "rules[input][1][protocol]=tcp" \
    --data-urlencode "rules[input][1][action]=accept" \
    --data-urlencode "rules[input][2][name]=Allow SSH from VPN" \
    --data-urlencode "rules[input][2][src_ip]=${VPN_EGRESS_IP}/32" \
    --data-urlencode "rules[input][2][dst_port]=22" \
    --data-urlencode "rules[input][2][protocol]=tcp" \
    --data-urlencode "rules[input][2][action]=accept" \
    --data-urlencode "rules[input][3][name]=Default discard" \
    --data-urlencode "rules[input][3][action]=discard"
echo

echo "Polling until active (Robot Firewall application is asynchronous)..."
for i in $(seq 1 30); do
    STATUS=$(curl -s -u "${HETZNER_ROBOT_USER}:${HETZNER_ROBOT_PASSWORD}" "$BASE_URL" | grep -o '"status":"[a-z]*"' | head -1)
    echo "  [$i/30] $STATUS"
    [[ "$STATUS" == '"status":"active"' ]] && { echo "Firewall active."; exit 0; }
    sleep 5
done

echo "WARNING: firewall did not report 'active' within 150s — check Robot console manually." >&2
exit 1
