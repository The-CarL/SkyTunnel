#!/bin/bash
# SkyTunnel — Let's Encrypt certificate setup for chisel TLS
#
# Usage: setup-certbot.sh <domain> <email>
#
# This script acquires a TLS certificate via certbot standalone mode
# and configures automatic renewal. Chisel is stopped during cert
# acquisition (port 443 contention) and restarted afterward.

set -euo pipefail

DOMAIN="${1:?Usage: setup-certbot.sh <domain> <email>}"
EMAIL="${2:?Usage: setup-certbot.sh <domain> <email>}"

echo "=== Setting up Let's Encrypt for ${DOMAIN} ==="

# Install certbot if not present
if ! command -v certbot &>/dev/null; then
    echo "Installing certbot..."
    dnf install -y certbot
fi

# Check if cert already exists and is valid
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" 2>/dev/null | cut -d= -f2)
    if [[ -n "$EXPIRY" ]]; then
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
        if (( DAYS_LEFT > 30 )); then
            echo "Certificate still valid for ${DAYS_LEFT} days, skipping renewal"
            exit 0
        fi
    fi
fi

# Stop chisel to free port 443
echo "Stopping chisel-server for cert acquisition..."
systemctl stop chisel-server 2>/dev/null || true

# Acquire certificate
echo "Running certbot..."
certbot certonly --standalone \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring

# Restart chisel (it will pick up the new certs via the wrapper script)
echo "Restarting chisel-server..."
systemctl start chisel-server

# Set up renewal systemd timer
echo "Configuring automatic renewal..."

cat > /etc/systemd/system/certbot-renew.service <<'EOF'
[Unit]
Description=Certbot renewal for SkyTunnel

[Service]
Type=oneshot
ExecStartPre=/bin/systemctl stop chisel-server
ExecStart=/usr/bin/certbot renew --quiet
ExecStartPost=/bin/systemctl start chisel-server
EOF

cat > /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Run certbot renewal twice daily

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now certbot-renew.timer

echo "=== Let's Encrypt setup complete ==="
echo "Certificate: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
echo "Private key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
