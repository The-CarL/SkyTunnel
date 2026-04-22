# SkyTunnel Throughput Guide

## Protocol Comparison

| Protocol | Tunnel | Typical Throughput | Latency | Root Required | Best For |
|----------|--------|--------------------|---------|---------------|----------|
| HTTPS | chisel | 10-50+ Mbps | Low | No | Full connectivity, best performance |
| DNS | iodine | 50-100 KB/s | High | Yes | Captive portals that allow DNS |
| ICMP | hans | 100-300 KB/s | Medium | Yes | Networks that only allow ping |

## HTTPS Tunnel (Chisel)

**Expected**: 10-50+ Mbps (limited by instance bandwidth, not protocol)

Chisel tunnels TCP traffic over an HTTP/WebSocket connection. On a `t3.nano`, the bottleneck is the instance's network bandwidth (~5 Gbps burst), not the protocol overhead.

**Factors affecting throughput**:
- Instance type network performance
- Client's internet connection speed
- TLS overhead (negligible)
- Distance to AWS region

**When it works**: When TCP 443 is open. Most networks allow this, including most captive portals after initial authentication, corporate firewalls, and hotel wifi.

**When it doesn't**: Deep packet inspection (DPI) that detects and blocks non-standard HTTPS traffic. Some enterprise firewalls analyze TLS handshakes and block non-whitelisted destinations.

## DNS Tunnel (iodine)

**Expected**: 50-100 KB/s (highly variable)

iodine encodes data into DNS queries and responses. Each DNS query carries a small payload (up to ~200 bytes in the hostname, more in NULL/TXT responses).

**Factors affecting throughput**:
- Intermediate DNS resolver caching (reduces effective throughput)
- DNS resolver rate limiting
- Query type support (NULL records are fastest, TXT as fallback)
- Downstream encoding (raw > base128 > base64 > base32)
- MTU settings (larger MTU = more data per packet, but less reliable)

**When it works**: Almost everywhere. DNS is required for basic network function, so even the most restrictive captive portals typically allow DNS queries (UDP 53) to pass through.

**When it doesn't**: Networks that force all DNS through a local resolver that strips unknown record types, or networks that rate-limit DNS aggressively.

**Tips**:
- Use `-T NULL` for best throughput (default, but some resolvers block it)
- If NULL fails, iodine auto-falls back to TXT, CNAME, etc.
- Keep the tunnel subdomain short (`t.` rather than `tunnel.`) for more payload per query
- The `-M` flag controls upstream hostname length (default 255, try lowering if unstable)

## ICMP Tunnel (hans)

**Expected**: 100-300 KB/s

hans encodes data in ICMP echo request/reply packets. Each packet carries more payload than a DNS query, giving better throughput than iodine.

**Factors affecting throughput**:
- Network ICMP rate limiting
- Packet loss (ICMP is often deprioritized)
- MTU settings
- Polling window size (`-w` flag)

**When it works**: Networks that allow ICMP (ping). Many networks allow this for diagnostic purposes even when other protocols are blocked.

**When it doesn't**: Networks that block ICMP entirely, or rate-limit it to a few packets per second.

**Tips**:
- Lower MTU (`-m 1200`) if experiencing packet loss
- Increase polling window (`-w 10`) for higher throughput on reliable networks
- hans is more reliable than iodine on networks with aggressive DNS filtering

## Running Your Own Benchmarks

### Built-in Speed Test

The client has a built-in speed test that measures download, upload, and latency through the active tunnel:

```bash
# Connect a tunnel first, then:
skytunnel-client speedtest             # 1MB test (default)
skytunnel-client speedtest 100000      # 100KB — better for dns/icmp tunnels
skytunnel-client speedtest 10000000    # 10MB — better for https tunnel
```

### Manual Speed Test (curl)

```bash
# Download (1MB through SOCKS proxy)
curl --socks5 localhost:1080 -o /dev/null -s \
  -w "Speed: %{speed_download} bytes/sec\nTime: %{time_total}s\n" \
  'https://speed.cloudflare.com/__down?bytes=1000000'

# Latency (tiny request, measures round-trip)
curl --socks5 localhost:1080 -o /dev/null -s \
  -w "Latency: %{time_total}s\n" \
  'https://speed.cloudflare.com/__down?bytes=1'
```

## Throughput by Scenario

| Scenario | HTTPS | DNS | ICMP |
|----------|-------|-----|------|
| Airport free wifi (captive portal, no auth) | Blocked | 50-80 KB/s | Blocked |
| Airport wifi (authenticated) | 20-40 Mbps | 60-100 KB/s | 150-250 KB/s |
| Hotel wifi | 10-30 Mbps | 40-80 KB/s | 100-200 KB/s |
| In-flight wifi (satellite) | 1-5 Mbps | 20-50 KB/s | Blocked |
| Corporate firewall | 5-20 Mbps | 30-60 KB/s | Blocked |
| Coffee shop | 20-50 Mbps | 80-100 KB/s | 200-300 KB/s |

Note: These are rough estimates. Actual throughput depends heavily on the specific network conditions, congestion, and filtering policies.
