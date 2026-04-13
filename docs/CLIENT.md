# SkyTunnel Client Guide

## Install Dependencies

### Automatic

```bash
chmod +x scripts/client/install-deps.sh
./scripts/client/install-deps.sh
```

This installs `iodine`, `hans`, and `chisel` for your platform.

### Manual

**macOS:**
```bash
brew install iodine                    # or compile from source
# hans: no brew formula — compiled from source by install-deps.sh
# chisel: no brew formula — downloaded from GitHub releases by install-deps.sh
```

**Ubuntu/Debian:**
```bash
sudo apt-get install iodine
# hans: compile from source
# chisel: download from https://github.com/jpillora/chisel/releases
```

**Fedora/Amazon Linux:**
```bash
# iodine and hans: compile from source (see install-deps.sh)
# chisel: download from GitHub releases
```

## Configuration

### Config File

```bash
mkdir -p ~/.skytunnel
cp scripts/client/config.example.yaml ~/.skytunnel/config.yaml
```

Edit `~/.skytunnel/config.yaml` with your server details and passwords.

**Important**: DNS and ICMP tunnel modes require an SSH key to create the SOCKS proxy. Set the `ssh_key` field to your EC2 key pair's private key path:

```yaml
ssh_key: ~/.ssh/skytunnel.pem
ssh_user: ec2-user
```

### Environment Variables

Alternatively, export environment variables (useful for CI or one-off use):

```bash
export SKYTUNNEL_SERVER_DOMAIN=example.com
export SKYTUNNEL_TUNNEL_SUBDOMAIN=t
export SKYTUNNEL_NS_HOSTNAME=ns-tunnel
export SKYTUNNEL_IODINE_PASSWORD=your_iodine_pass
export SKYTUNNEL_HANS_PASSWORD=your_hans_pass
export SKYTUNNEL_CHISEL_AUTH=user:your_chisel_pass
export SKYTUNNEL_SSH_KEY=~/.ssh/skytunnel.pem   # required for dns/icmp modes
```

### CLI Flags

Flags override both config file and environment:

```bash
skytunnel-client -s example.com connect https
```

## Usage

Make the client executable:

```bash
chmod +x scripts/client/skytunnel-client
# Optionally symlink to PATH:
sudo ln -s "$(pwd)/scripts/client/skytunnel-client" /usr/local/bin/skytunnel-client
```

### Connect via HTTPS (Recommended)

Best throughput, no root required, no SSH key needed. Works when TCP 443 is open.

```bash
skytunnel-client connect https
```

### Connect via DNS

Works when only DNS (UDP 53) is allowed. Requires root and SSH key.

```bash
sudo skytunnel-client connect dns
```

### Connect via ICMP

Works when only ICMP is allowed. Requires root and SSH key.

```bash
sudo skytunnel-client connect icmp
```

### Auto-Connect

Tries HTTPS first, then DNS, then ICMP. Uses the first protocol that works.

```bash
sudo skytunnel-client connect auto
```

### Check Status

```bash
skytunnel-client status
```

### Disconnect

```bash
skytunnel-client disconnect
# or: sudo skytunnel-client disconnect (if connected via dns/icmp)
```

## How It Works

Each tunnel mode establishes a SOCKS5 proxy on `localhost:1080`, but the path to get there differs:

### HTTPS (chisel)

```
Client                          Server
chisel client ──TCP 443──────> chisel server
  └─ SOCKS5 on localhost:1080
```

Chisel handles everything — connects over TCP 443, and the client directly provides a SOCKS5 proxy. No tun device, no SSH key needed.

### DNS (iodine)

```
Client                                          Server
iodine client ──DNS queries (UDP 53)──────────> iodined
  └─ creates utun device (10.53.0.2)              └─ dns0 device (10.53.0.1)
       │                                               │
       └── ssh -D 1080 ec2-user@10.53.0.1 ───────────>│
            (SSH travels through the DNS tunnel)
            └─ SOCKS5 on localhost:1080
```

1. iodine creates a point-to-point IP tunnel over DNS (tun device on each side)
2. Client gets `10.53.0.2`, server is `10.53.0.1` — you now have IP connectivity through DNS
3. The client starts `ssh -D 1080` to the server *through the tunnel IP* — this SSH session rides over the DNS tunnel
4. SSH provides the SOCKS5 proxy on `localhost:1080`

This is why DNS/ICMP modes need your EC2 SSH key.

### ICMP (hans)

```
Client                                          Server
hans client ──ICMP echo/reply─────────────────> hans server
  └─ creates utun device (10.54.0.100+)           └─ hans0 device (10.54.0.1)
       │                                               │
       └── ssh -D 1080 ec2-user@10.54.0.1 ───────────>│
            (SSH travels through the ICMP tunnel)
            └─ SOCKS5 on localhost:1080
```

Same pattern as DNS — hans creates an IP tunnel over ICMP, then SSH over the tunnel provides SOCKS.

## Using the SOCKS Proxy

All tunnel modes expose a SOCKS5 proxy on `localhost:1080` (configurable via `socks_port`).

### Verify it works

```bash
curl --socks5 localhost:1080 https://ifconfig.me
# Should return your server's Elastic IP
```

### curl

```bash
curl --socks5 localhost:1080 https://ifconfig.me
curl --socks5-hostname localhost:1080 https://example.com
```

### Browser

**Firefox:** Settings > Network Settings > Manual proxy > SOCKS Host: `127.0.0.1`, Port: `1080`, SOCKS v5

**Chrome (command line):**
```bash
google-chrome --proxy-server="socks5://127.0.0.1:1080"
```

### System-wide (macOS)

System Settings > Network > (your connection) > Proxies > SOCKS Proxy: `127.0.0.1:1080`

### SSH

```bash
ssh -o ProxyCommand='nc -x 127.0.0.1:1080 %h %p' user@remote-host
```

### git

```bash
git config --global http.proxy socks5://127.0.0.1:1080
```

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues and debugging steps.
