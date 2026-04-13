#!/usr/bin/env bash
# SkyTunnel — Post-deploy connectivity smoke tests
# Tests each tunnel protocol by connecting and verifying SOCKS proxy.
#
# Usage: test-connectivity.sh [options]
#   -s, --server <domain>    Server domain (or set SKYTUNNEL_SERVER_DOMAIN)
#   -p, --protocol <proto>   Test specific protocol (dns|icmp|https|all, default: all)
#   --skip-cleanup           Don't disconnect after each test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT="${REPO_ROOT}/scripts/client/skytunnel-client"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
PROTOCOL="all"
SKIP_CLEANUP=false
SOCKS_PORT="${SKYTUNNEL_SOCKS_PORT:-1080}"
TIMEOUT=30

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}  $1"; ((SKIP++)); }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--server)   export SKYTUNNEL_SERVER_DOMAIN="$2"; shift 2 ;;
        -p|--protocol) PROTOCOL="$2"; shift 2 ;;
        --skip-cleanup) SKIP_CLEANUP=true; shift ;;
        -h|--help)
            echo "Usage: $(basename "$0") [-s server] [-p dns|icmp|https|all]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "${SKYTUNNEL_SERVER_DOMAIN:-}" ]]; then
    echo "Error: Server domain required. Use -s or set SKYTUNNEL_SERVER_DOMAIN"
    exit 1
fi

if [[ ! -x "$CLIENT" ]]; then
    echo "Error: Client script not found or not executable: $CLIENT"
    echo "Run: chmod +x $CLIENT"
    exit 1
fi

echo -e "${BOLD}=== SkyTunnel Connectivity Tests ===${NC}"
echo "Server: ${SKYTUNNEL_SERVER_DOMAIN}"
echo ""

# --- Test function ---
test_tunnel() {
    local proto="$1"
    local needs_root="${2:-false}"

    echo -e "${BOLD}Testing ${proto} tunnel:${NC}"

    # Check if root is needed
    if [[ "$needs_root" == "true" && $EUID -ne 0 ]]; then
        skip "${proto}: requires root (re-run with sudo)"
        echo ""
        return
    fi

    # Connect
    echo "  Connecting..."
    if timeout "$TIMEOUT" "$CLIENT" connect "$proto" &>/dev/null; then
        pass "Connected via ${proto}"
    else
        fail "Failed to connect via ${proto}"
        echo ""
        return
    fi

    # Verify SOCKS proxy
    sleep 2
    if (echo "" | nc -z 127.0.0.1 "$SOCKS_PORT") &>/dev/null; then
        pass "SOCKS proxy responding on port ${SOCKS_PORT}"
    else
        fail "SOCKS proxy not responding on port ${SOCKS_PORT}"
    fi

    # Test external connectivity through tunnel
    local external_ip
    external_ip=$(curl -s --max-time 10 --socks5 "localhost:${SOCKS_PORT}" https://ifconfig.me 2>/dev/null || true)
    if [[ -n "$external_ip" ]]; then
        pass "External connectivity via ${proto} (IP: ${external_ip})"
    else
        fail "No external connectivity through ${proto} tunnel"
    fi

    # Basic throughput test (download a small file and measure time)
    local start_time end_time duration
    start_time=$(date +%s%N)
    curl -s --max-time 15 --socks5 "localhost:${SOCKS_PORT}" \
        -o /dev/null "https://speed.cloudflare.com/__down?bytes=100000" 2>/dev/null || true
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))
    if (( duration > 0 && duration < 15000 )); then
        local speed=$(( 100000 * 1000 / duration / 1024 ))
        echo -e "  ${YELLOW}INFO${NC}  ~${speed} KB/s (100KB test, ${duration}ms)"
    fi

    # Disconnect
    if [[ "$SKIP_CLEANUP" != "true" ]]; then
        "$CLIENT" disconnect &>/dev/null || true
        sleep 1
    fi

    echo ""
}

# --- Run tests ---
case "$PROTOCOL" in
    https) test_tunnel https false ;;
    dns)   test_tunnel dns true ;;
    icmp)  test_tunnel icmp true ;;
    all)
        test_tunnel https false
        test_tunnel dns true
        test_tunnel icmp true
        ;;
    *)
        echo "Unknown protocol: $PROTOCOL"
        exit 1
        ;;
esac

# --- Summary ---
echo -e "${BOLD}=== Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ===${NC}"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
