#!/usr/bin/env bash
#
# Idempotent OS-level preparation for the PostHog Hetzner box. Runs as root over SSH,
# on every deploy (not just once) — everything here is guarded so a no-op re-run is cheap.
#
# Assumes: fresh Ubuntu 24.04 LTS installed via Hetzner's installimage with software
# RAID10 across all NVMe drives as the single root filesystem (see ../README.md).
#
set -euo pipefail

VPN_EGRESS_IP="${VPN_EGRESS_IP:-}"   # static admin SSH allowlist entry, optional

log() { echo "[bootstrap] $*"; }

# ---------------------------------------------------------------------------
# 1. Non-root deploy user
# ---------------------------------------------------------------------------
if ! id deploy_user &>/dev/null; then
    log "Creating deploy_user"
    useradd -m -s /bin/bash deploy_user
fi
getent group docker &>/dev/null || groupadd docker
usermod -aG docker deploy_user

# ---------------------------------------------------------------------------
# 2. SSH hardening — root stays key-only (appleboy/ssh-action connects as root),
#    just remove password auth as an accepted login path.
# ---------------------------------------------------------------------------
SSHD_HARDENING=/etc/ssh/sshd_config.d/99-hardening.conf
DESIRED_SSHD_CONTENT='PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no'
if [ ! -f "$SSHD_HARDENING" ] || [ "$(cat "$SSHD_HARDENING")" != "$DESIRED_SSHD_CONTENT" ]; then
    log "Writing $SSHD_HARDENING"
    echo "$DESIRED_SSHD_CONTENT" > "$SSHD_HARDENING"
    systemctl reload ssh || systemctl reload sshd
fi

# ---------------------------------------------------------------------------
# 3. ufw baseline — defense in depth behind the Hetzner Robot Firewall, which is
#    the real perimeter control (see ../firewall-baseline.sh). ufw allows 80/443
#    permanently for Caddy; port 22 is NOT dynamically gated here (ufw has no way
#    to open itself for an unauthenticated CI runner) — it stays permanently open
#    at the ufw layer and relies on the Robot Firewall's temp-open/close per deploy
#    to actually control who can reach it from outside.
# ---------------------------------------------------------------------------
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp comment 'Caddy HTTP' || true
    ufw allow 443/tcp comment 'Caddy HTTPS' || true
    ufw allow 22/tcp comment 'SSH (real gate is Hetzner Robot Firewall)' || true
    if [ -n "$VPN_EGRESS_IP" ]; then
        ufw allow from "$VPN_EGRESS_IP" to any port 22 proto tcp comment 'VPN admin access' || true
    fi
    ufw --force enable
    ufw status verbose
else
    log "WARNING: ufw not installed, installing"
    apt-get update -qq && apt-get install -y -qq ufw
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 22/tcp
    [ -n "$VPN_EGRESS_IP" ] && ufw allow from "$VPN_EGRESS_IP" to any port 22 proto tcp
    ufw --force enable
fi

# ---------------------------------------------------------------------------
# 4. unattended-upgrades — security patches apply automatically, auto-reboot
#    stays OFF (a live 25-container prod stack should not reboot itself; reboots
#    for kernel updates happen manually in a maintenance window).
# ---------------------------------------------------------------------------
if ! dpkg -s unattended-upgrades &>/dev/null; then
    log "Installing unattended-upgrades"
    apt-get update -qq
    apt-get install -y -qq unattended-upgrades
fi
cat > /etc/apt/apt.conf.d/51-posthog-auto-reboot.conf <<'EOF'
// Explicitly disabled: this box runs a live multi-service stack, kernel/security
// updates must not trigger an unattended reboot. Reboot manually in a maintenance window.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable --now unattended-upgrades.service

# ---------------------------------------------------------------------------
# 5. sysctl tuning for Kafka/Redpanda + ClickHouse + Postgres + Redis coexistence
# ---------------------------------------------------------------------------
cat > /etc/sysctl.d/99-posthog.conf <<'EOF'
# Elasticsearch-style mmap ceiling; harmless even though ES isn't in this stack today.
vm.max_map_count = 262144
# Minimize swap use by ClickHouse/Kafka/Postgres without disabling swap outright.
vm.swappiness = 1
# Redis needs this for background-save fork() to succeed under memory pressure.
vm.overcommit_memory = 1
fs.file-max = 1000000
# Listener backlog headroom for Kafka/Caddy under burst load.
net.core.somaxconn = 4096
EOF
sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# 6. File descriptor limits — Docker's own default (1024) is too low for
#    Kafka/ClickHouse; raise both the host ulimit and the container default.
# ---------------------------------------------------------------------------
cat > /etc/security/limits.d/99-posthog.conf <<'EOF'
*  soft  nofile  1000000
*  hard  nofile  1000000
EOF

# ---------------------------------------------------------------------------
# 7. Disable Transparent Huge Pages at boot (documented latency-spike source
#    for ClickHouse/Kafka-style memory access patterns). /sys writes don't
#    survive reboot, hence a oneshot unit rather than a one-off `echo`.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service

# ---------------------------------------------------------------------------
# 8. Docker Engine + compose plugin (modern gpg-dearmor method), log rotation,
#    and default ulimits so ~25 containers don't inherit the 1024-fd default
#    or fill the RAID10 array with unrotated json-file logs.
# ---------------------------------------------------------------------------
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1000000, "Soft": 1000000 }
  }
}
EOF

if ! command -v docker &>/dev/null; then
    log "Installing Docker Engine"
    apt-get update -qq
    apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    log "Docker already installed"
fi
systemctl restart docker

# ---------------------------------------------------------------------------
# 9. docker-volume-local-persist — pins ClickHouse's data volume to a specific
#    path on the RAID10 root filesystem instead of an anonymous Docker volume.
#    Installed from the upstream project's GitHub releases (not a vendored
#    binary of unknown provenance).
# ---------------------------------------------------------------------------
LOCAL_PERSIST_VERSION="1.4.0"
if [ ! -x /usr/bin/docker-volume-local-persist ]; then
    log "Installing docker-volume-local-persist v${LOCAL_PERSIST_VERSION}"
    curl -fsSL -o /usr/bin/docker-volume-local-persist \
        "https://github.com/CWSpear/local-persist/releases/download/v${LOCAL_PERSIST_VERSION}/docker-volume-local-persist-linux-amd64"
    chmod +x /usr/bin/docker-volume-local-persist
fi

cat > /etc/systemd/system/docker-volume-local-persist.service <<'EOF'
[Unit]
Description=Local Persist Docker Volume Driver
Documentation=https://github.com/CWSpear/local-persist
Before=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker-volume-local-persist
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now docker-volume-local-persist.service

mkdir -p /mnt/volumes/root_clickhouse-data/_data
chown -R root:root /mnt/volumes

log "bootstrap.sh done"
