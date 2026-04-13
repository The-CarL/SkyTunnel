#!/bin/bash
# SkyTunnel server bootstrap script
# Called from CloudFormation UserData. Installs and configures all three
# tunnel servers (iodine, hans, chisel) on Amazon Linux 2023.
#
# This script is idempotent — safe to re-run on instance restart.
# All values are injected by CloudFormation Fn::Sub in the UserData block.

set -euo pipefail

# --- Configuration (injected by CloudFormation Fn::Sub) ---
STACK_NAME="${STACK_NAME}"
RESOURCE_NAME="${RESOURCE_NAME:-TunnelServer}"
AWS_REGION="${AWS_REGION}"
IODINE_PASSWORD="${IODINE_PASSWORD}"
IODINE_SUBNET="${IODINE_SUBNET}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
HANS_PASSWORD="${HANS_PASSWORD}"
HANS_SUBNET="${HANS_SUBNET}"
CHISEL_AUTH="${CHISEL_AUTH}"
CHISEL_DOMAIN="${CHISEL_DOMAIN}"
ENABLE_LETSENCRYPT="${ENABLE_LETSENCRYPT:-false}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

# --- Pinned versions ---
IODINE_VERSION="0.8.0"
HANS_VERSION="1.1"
CHISEL_VERSION="1.11.5"

# --- Logging ---
LOG_FILE="/var/log/skytunnel-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== SkyTunnel bootstrap started at $(date -u) ==="

# --- Signal CloudFormation on failure ---
signal_failure() {
    echo "ERROR: Bootstrap failed at line $1"
    /opt/aws/bin/cfn-signal --exit-code 1 \
        --stack "$STACK_NAME" \
        --resource "$RESOURCE_NAME" \
        --region "$AWS_REGION" || true
    exit 1
}
trap 'signal_failure $LINENO' ERR

# ==========================================================
# 1. System preparation
# ==========================================================
echo "--- Installing build dependencies ---"
dnf groupinstall -y "Development Tools"
dnf install -y zlib-devel gcc-c++ net-tools jq iptables-services

echo "--- Loading tun kernel module ---"
modprobe tun
echo "tun" > /etc/modules-load.d/tun.conf

echo "--- Configuring sysctl ---"
cat > /etc/sysctl.d/99-skytunnel.conf <<'SYSCTL'
# Enable IP forwarding for tunnel traffic routing
net.ipv4.ip_forward = 1
# Do NOT set icmp_echo_ignore_all here — use iptables instead
# (global icmp_echo_ignore_all breaks ping on tunnel interfaces)
net.ipv4.icmp_echo_ignore_all = 0
SYSCTL
sysctl --system

# ==========================================================
# 2. Create directories and user
# ==========================================================
echo "--- Setting up skytunnel directories ---"
mkdir -p /etc/skytunnel /opt/skytunnel
useradd --system --no-create-home --shell /sbin/nologin skytunnel 2>/dev/null || true

# ==========================================================
# 3. Build and install iodine
# ==========================================================
if [[ ! -x /usr/local/sbin/iodined ]]; then
    echo "--- Building iodine v${IODINE_VERSION} ---"
    cd /tmp
    rm -rf iodine
    git clone --depth 1 https://github.com/yarrick/iodine.git
    cd iodine
    # Try tagged version, fall back to master if tag doesn't exist
    git fetch --tags
    git checkout "v${IODINE_VERSION}" 2>/dev/null || git checkout "${IODINE_VERSION}" 2>/dev/null || true
    make -j"$(nproc)"
    make install
    cd /
    rm -rf /tmp/iodine
    echo "iodine $(iodined -v 2>&1 | head -1) installed"
else
    echo "--- iodine already installed, skipping build ---"
fi

# ==========================================================
# 4. Build and install hans
# ==========================================================
if [[ ! -x /usr/local/sbin/hans ]]; then
    echo "--- Building hans v${HANS_VERSION} ---"
    cd /tmp
    rm -rf hans-*
    curl -sSL "https://github.com/friedrich/hans/archive/refs/tags/v${HANS_VERSION}.tar.gz" | tar xz
    cd "hans-${HANS_VERSION}"
    make -j"$(nproc)"
    install -m 755 hans /usr/local/sbin/hans
    cd /
    rm -rf /tmp/hans-*
    echo "hans v${HANS_VERSION} installed"
else
    echo "--- hans already installed, skipping build ---"
fi

# ==========================================================
# 5. Install chisel (pre-built binary)
# ==========================================================
if [[ ! -x /usr/local/bin/chisel ]]; then
    echo "--- Installing chisel v${CHISEL_VERSION} ---"
    curl -sSL "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_amd64.gz" \
        | gunzip > /usr/local/bin/chisel
    chmod 755 /usr/local/bin/chisel
    echo "chisel $(/usr/local/bin/chisel --version 2>&1 || true) installed"
else
    echo "--- chisel already installed, skipping ---"
fi

# ==========================================================
# 6. Write environment files for systemd services
# ==========================================================
echo "--- Writing service environment files ---"

cat > /etc/skytunnel/iodine.env <<EOF
IODINE_PASSWORD=${IODINE_PASSWORD}
IODINE_SUBNET=${IODINE_SUBNET}
IODINE_DOMAIN=${TUNNEL_DOMAIN}
EOF

cat > /etc/skytunnel/hans.env <<EOF
HANS_PASSWORD=${HANS_PASSWORD}
HANS_SUBNET=${HANS_SUBNET}
EOF

cat > /etc/skytunnel/chisel.env <<EOF
CHISEL_AUTH=${CHISEL_AUTH}
CHISEL_DOMAIN=${CHISEL_DOMAIN}
TLS_CERT_PATH=/etc/letsencrypt/live/${CHISEL_DOMAIN}/fullchain.pem
TLS_KEY_PATH=/etc/letsencrypt/live/${CHISEL_DOMAIN}/privkey.pem
EOF

chmod 600 /etc/skytunnel/*.env

# ==========================================================
# 7. Write chisel wrapper script (conditional TLS)
# ==========================================================
cat > /etc/skytunnel/start-chisel.sh <<'WRAPPER'
#!/bin/bash
# Chisel startup wrapper — adds TLS flags only if certs exist
set -euo pipefail

source /etc/skytunnel/chisel.env

CHISEL_ARGS="server --port 443 --socks5 --reverse --auth ${CHISEL_AUTH}"

if [[ -f "$TLS_CERT_PATH" && -f "$TLS_KEY_PATH" ]]; then
    CHISEL_ARGS="${CHISEL_ARGS} --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"
    echo "Starting chisel with TLS"
else
    echo "WARNING: TLS certificates not found, starting chisel without TLS"
fi

exec /usr/local/bin/chisel ${CHISEL_ARGS}
WRAPPER
chmod 755 /etc/skytunnel/start-chisel.sh

# ==========================================================
# 8. Configure NAT/masquerade for tunnel traffic
# ==========================================================
echo "--- Configuring NAT ---"
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)

# Extract network from iodine subnet (e.g., 10.53.0.1/24 -> 10.53.0.0/24)
IODINE_NET=$(echo "$IODINE_SUBNET" | sed 's/\.[0-9]*\//.0\//')
# Hans subnet is just an IP (e.g., 10.54.0.1), make it a /24
HANS_NET=$(echo "$HANS_SUBNET" | sed 's/\.[0-9]*$/.0/')"/24"

for NET in "$IODINE_NET" "$HANS_NET"; do
    if ! iptables -t nat -C POSTROUTING -s "$NET" -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$NET" -o "$IFACE" -j MASQUERADE
        echo "Added NAT rule for $NET via $IFACE"
    fi
done

# Block kernel ICMP echo-replies on public interface only (hans needs this)
# This lets hans handle ICMP on the public interface while tunnel interfaces still respond to ping
if ! iptables -C OUTPUT -o "$IFACE" -p icmp --icmp-type echo-reply -j DROP 2>/dev/null; then
    iptables -A OUTPUT -o "$IFACE" -p icmp --icmp-type echo-reply -j DROP
    echo "Added ICMP echo-reply drop on $IFACE for hans"
fi

# Persist iptables rules
iptables-save > /etc/sysconfig/iptables
systemctl enable iptables

# ==========================================================
# 9. Install and enable systemd services
# ==========================================================
echo "--- Installing systemd units ---"
cp /opt/skytunnel/systemd/*.service /etc/systemd/system/ 2>/dev/null || true

# If units weren't pre-staged, write them inline
for SVC in iodine-server hans-server chisel-server; do
    if [[ ! -f "/etc/systemd/system/${SVC}.service" ]]; then
        echo "WARNING: ${SVC}.service not found in /opt/skytunnel/systemd/, writing inline"
    fi
done

# Write units inline as fallback (the CF UserData stages them here)
if [[ ! -f /etc/systemd/system/iodine-server.service ]]; then
cat > /etc/systemd/system/iodine-server.service <<'UNIT'
[Unit]
Description=iodine DNS tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/skytunnel/iodine.env
ExecStartPre=/sbin/modprobe tun
ExecStart=/usr/local/sbin/iodined -f -c -P ${IODINE_PASSWORD} ${IODINE_SUBNET} ${IODINE_DOMAIN}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
ProtectProc=invisible

[Install]
WantedBy=multi-user.target
UNIT
fi

if [[ ! -f /etc/systemd/system/hans-server.service ]]; then
cat > /etc/systemd/system/hans-server.service <<'UNIT'
[Unit]
Description=hans ICMP tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/skytunnel/hans.env
ExecStartPre=/sbin/modprobe tun
ExecStart=/usr/local/sbin/hans -s ${HANS_SUBNET} -p ${HANS_PASSWORD} -f -d hans0
Restart=on-failure
RestartSec=5
ProtectProc=invisible

[Install]
WantedBy=multi-user.target
UNIT
fi

if [[ ! -f /etc/systemd/system/chisel-server.service ]]; then
cat > /etc/systemd/system/chisel-server.service <<'UNIT'
[Unit]
Description=chisel HTTPS tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/skytunnel/chisel.env
ExecStart=/etc/skytunnel/start-chisel.sh
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectProc=invisible

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload
systemctl enable iodine-server hans-server chisel-server
systemctl start iodine-server hans-server chisel-server

# ==========================================================
# 10. Optional: Let's Encrypt TLS for chisel
# ==========================================================
if [[ "$ENABLE_LETSENCRYPT" == "true" && -n "$LETSENCRYPT_EMAIL" ]]; then
    echo "--- Setting up Let's Encrypt ---"
    if [[ -x /opt/skytunnel/scripts/setup-certbot.sh ]]; then
        /opt/skytunnel/scripts/setup-certbot.sh "$CHISEL_DOMAIN" "$LETSENCRYPT_EMAIL"
    else
        # Inline certbot setup
        dnf install -y certbot
        systemctl stop chisel-server
        certbot certonly --standalone \
            -d "$CHISEL_DOMAIN" \
            --email "$LETSENCRYPT_EMAIL" \
            --agree-tos \
            --non-interactive
        systemctl start chisel-server

        # Set up renewal timer
        cat > /etc/systemd/system/certbot-renew.service <<'RENEW_SVC'
[Unit]
Description=Certbot renewal for SkyTunnel

[Service]
Type=oneshot
ExecStartPre=/bin/systemctl stop chisel-server
ExecStart=/usr/bin/certbot renew --quiet
ExecStartPost=/bin/systemctl start chisel-server
RENEW_SVC

        cat > /etc/systemd/system/certbot-renew.timer <<'RENEW_TMR'
[Unit]
Description=Run certbot renewal twice daily

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
RENEW_TMR

        systemctl daemon-reload
        systemctl enable --now certbot-renew.timer
    fi
    echo "Let's Encrypt setup complete"
fi

# ==========================================================
# 11. Signal CloudFormation success
# ==========================================================
echo "=== SkyTunnel bootstrap completed at $(date -u) ==="
/opt/aws/bin/cfn-signal --exit-code 0 \
    --stack "$STACK_NAME" \
    --resource "$RESOURCE_NAME" \
    --region "$AWS_REGION"
