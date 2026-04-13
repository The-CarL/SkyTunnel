# SkyTunnel

A self-hosted, multi-protocol tunneling toolkit for resilient connectivity in restricted network environments. Deploy a single EC2 instance with DNS, ICMP, and HTTPS tunnels — all managed via systemd, provisioned via CloudFormation, and operated with a simple CLI client.

**Use cases**: Captive portals, in-flight wifi, hotel networks, restrictive corporate firewalls — anywhere your internet access is filtered or paywalled but certain protocols still pass through.

## Architecture

```
                         Restricted Network
                    ┌─────────────────────────┐
                    │                         │
  ┌──────────┐     │   ┌─────────────────┐   │     ┌──────────────────┐
  │  Client   │────┼──>│  DNS (UDP 53)   │───┼────>│                  │
  │           │    │   │  iodine         │   │     │   EC2 Instance   │
  │ skytunnel │────┼──>│  ICMP (ping)    │───┼────>│                  │──> Internet
  │  -client  │    │   │  hans           │   │     │  t3.nano         │
  │           │────┼──>│  HTTPS (443)    │───┼────>│  Amazon Linux    │
  └──────────┘    │   │  chisel         │   │     │                  │
       │          │   └─────────────────┘   │     └──────────────────┘
       │          └─────────────────────────┘            │
       v                                                 │
  SOCKS5 proxy                                    Elastic IP
  localhost:1080                                  Route 53 DNS
```

## Protocol Comparison

| Protocol | Tool | Throughput | Root | Works When |
|----------|------|-----------|------|------------|
| HTTPS | chisel | 10-50+ Mbps | No | TCP 443 is open (most networks) |
| DNS | iodine | 50-100 KB/s | Yes | Only DNS allowed (captive portals) |
| ICMP | hans | 100-300 KB/s | Yes | Only ping allowed |

## Quick Start

### 1. Deploy (5 minutes)

```bash
# Clone the repo
git clone https://github.com/yourusername/skytunnel.git && cd skytunnel

# Copy and edit parameters
cp cloudformation/params/example.json cloudformation/params/my-params.json
# Edit my-params.json with your domain, passwords, key pair, hosted zone ID

# Deploy
aws cloudformation create-stack \
  --stack-name skytunnel \
  --template-body file://cloudformation/skytunnel-stack.yaml \
  --parameters file://cloudformation/params/my-params.json \
  --region us-east-1

# Wait (~15 min for compilation)
aws cloudformation wait stack-create-complete --stack-name skytunnel
```

### 2. Connect

```bash
# Install client dependencies
./scripts/client/install-deps.sh

# Configure
mkdir -p ~/.skytunnel
cp scripts/client/config.example.yaml ~/.skytunnel/config.yaml
# Edit config.yaml with your server details

# Connect via HTTPS (recommended — no root needed)
./scripts/client/skytunnel-client connect https

# Or auto-detect best protocol (needs root for DNS/ICMP fallback)
sudo ./scripts/client/skytunnel-client connect auto

# Or connect via specific protocol
sudo ./scripts/client/skytunnel-client connect dns
sudo ./scripts/client/skytunnel-client connect icmp
```

### 3. Use

All tunnel modes expose a SOCKS5 proxy on `localhost:1080`:

```bash
curl --socks5 localhost:1080 https://ifconfig.me
```

Configure your browser to use SOCKS5 proxy `127.0.0.1:1080`.

## Cost

~$5-8/month for a `t3.nano` instance running 24/7. See [COST.md](docs/COST.md) for full breakdown.

## Prerequisites

- AWS account with Route 53 hosted zone for your domain
- AWS CLI configured
- EC2 key pair in your target region

## Documentation

- [Setup Guide](docs/SETUP.md) — Detailed deployment walkthrough
- [Client Guide](docs/CLIENT.md) — Client installation and usage
- [Cost Breakdown](docs/COST.md) — Monthly cost estimates and optimization
- [Throughput Guide](docs/THROUGHPUT.md) — Performance by protocol and scenario
- [Troubleshooting](docs/TROUBLESHOOTING.md) — Common issues and debugging

## Project Structure

```
skytunnel/
├── cloudformation/
│   ├── skytunnel-stack.yaml       # CloudFormation template
│   └── params/example.json        # Example parameters
├── scripts/
│   ├── server/
│   │   ├── bootstrap.sh           # Server provisioning (UserData)
│   │   ├── setup-certbot.sh       # Let's Encrypt TLS setup
│   │   └── health-check.sh        # Server health diagnostics
│   └── client/
│       ├── skytunnel-client       # Client CLI
│       ├── install-deps.sh        # Client dependency installer
│       └── config.example.yaml    # Example client config
├── systemd/                       # Service unit files
├── docs/                          # Documentation
└── tests/                         # Validation and smoke tests
```

## License

SkyTunnel is licensed under the [Apache License 2.0](LICENSE).

SkyTunnel orchestrates the following third-party tools as separate binaries:
- [iodine](https://github.com/yarrick/iodine) (ISC License)
- [hans](https://github.com/friedrich/hans) (GPL-3.0 License)
- [chisel](https://github.com/jpillora/chisel) (MIT License)

See [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) for details.
