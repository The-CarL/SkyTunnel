#!/bin/bash
# SkyTunnel server health check
# Validates that all three tunnel services are running and properly configured.
# Exit code: 0 = all healthy, 1 = one or more issues found.

set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  [OK]   $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }

echo "=== SkyTunnel Health Check ==="
echo ""

# --- Systemd Services ---
echo "Services:"
for svc in iodine-server hans-server chisel-server; do
    if systemctl is-active --quiet "$svc"; then
        pass "$svc is running"
    else
        fail "$svc is not running ($(systemctl is-active "$svc"))"
    fi
done
echo ""

# --- Tunnel Devices ---
echo "Tunnel devices:"
# iodine creates dns0 by default
if ip link show dns0 &>/dev/null; then
    IODINE_IP=$(ip -4 addr show dns0 2>/dev/null | grep -oP 'inet \K[\d.]+')
    pass "dns0 exists (IP: ${IODINE_IP:-unknown})"
else
    fail "dns0 not found — iodine tunnel device missing"
fi

# hans uses explicit device name hans0
if ip link show hans0 &>/dev/null; then
    HANS_IP=$(ip -4 addr show hans0 2>/dev/null | grep -oP 'inet \K[\d.]+')
    pass "hans0 exists (IP: ${HANS_IP:-unknown})"
else
    fail "hans0 not found — hans tunnel device missing"
fi
echo ""

# --- Network Listeners ---
echo "Listeners:"
if ss -ulnp | grep -q ':53 '; then
    pass "UDP port 53 (iodine DNS)"
else
    fail "Nothing listening on UDP 53"
fi

if ss -tlnp | grep -q ':443 '; then
    pass "TCP port 443 (chisel HTTPS)"
else
    fail "Nothing listening on TCP 443"
fi
echo ""

# --- Sysctl Settings ---
echo "Kernel settings:"
IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
if [[ "$IP_FWD" == "1" ]]; then
    pass "IP forwarding enabled"
else
    fail "IP forwarding disabled (net.ipv4.ip_forward=$IP_FWD)"
fi

ICMP_IGN=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)
if [[ "$ICMP_IGN" == "0" ]]; then
    pass "ICMP echo ignore disabled (iptables handles hans instead)"
else
    warn "ICMP echo ignore is global — tunnel pings may not work"
fi

# Check iptables ICMP drop rule on public interface
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if iptables -C OUTPUT -o "$IFACE" -p icmp --icmp-type echo-reply -j DROP 2>/dev/null; then
    pass "ICMP echo-reply dropped on $IFACE (hans compatible)"
else
    fail "Missing iptables ICMP drop rule on $IFACE — hans may not work"
fi
echo ""

# --- NAT Rules ---
echo "NAT/masquerade:"
if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
    RULES=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep "MASQUERADE" | awk '{print $4}')
    pass "NAT rules active for: $(echo "$RULES" | tr '\n' ' ')"
else
    fail "No NAT/masquerade rules found"
fi
echo ""

# --- TLS Certificates ---
echo "TLS:"
if [[ -f /etc/skytunnel/chisel.env ]]; then
    source /etc/skytunnel/chisel.env 2>/dev/null || true
    if [[ -f "${TLS_CERT_PATH:-/nonexistent}" ]]; then
        EXPIRY=$(openssl x509 -enddate -noout -in "$TLS_CERT_PATH" 2>/dev/null | cut -d= -f2)
        pass "TLS certificate present (expires: ${EXPIRY:-unknown})"
    else
        warn "TLS certificate not found — chisel running without TLS"
    fi
else
    warn "chisel env file not found"
fi
echo ""

# --- Summary ---
echo "=== Summary: ${PASS} passed, ${FAIL} failed, ${WARN} warnings ==="

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
