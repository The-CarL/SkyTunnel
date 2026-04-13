# SkyTunnel Setup Guide

## Prerequisites

1. **AWS Account** with permissions to create EC2, EIP, Route 53, Security Group, and IAM resources
2. **AWS CLI** installed and configured (`aws configure`)
3. **Domain** with a hosted zone in Route 53 (note your Hosted Zone ID)
4. **EC2 Key Pair** created in your target region
5. **Passwords** — choose strong passwords for each tunnel protocol

## Deploy the Stack

### 1. Prepare Parameters

Copy the example parameter file and fill in your values:

```bash
cp cloudformation/params/example.json cloudformation/params/my-params.json
```

Edit `my-params.json`:
- `DomainName`: Your domain (e.g., `example.com`)
- `HostedZoneId`: Your Route 53 hosted zone ID
- `KeyPairName`: Your EC2 key pair name
- `IodinePassword`: Strong password for DNS tunnel
- `HansPassword`: Strong password for ICMP tunnel
- `ChiselAuth`: `username:password` for HTTPS tunnel
- Adjust `SSHAllowCIDR` to restrict SSH access

### 2. Deploy

```bash
aws cloudformation create-stack \
  --stack-name skytunnel \
  --template-body file://cloudformation/skytunnel-stack.yaml \
  --parameters file://cloudformation/params/my-params.json \
  --region us-east-1
```

Wait for the stack to complete (15-20 minutes for compilation):

```bash
aws cloudformation wait stack-create-complete --stack-name skytunnel --region us-east-1
```

### 3. Get Connection Info

```bash
aws cloudformation describe-stacks \
  --stack-name skytunnel \
  --query 'Stacks[0].Outputs' \
  --output table \
  --region us-east-1
```

This shows the Elastic IP, SSH command, and connect commands for each tunnel.

## Verify DNS Propagation

The stack creates two DNS records automatically:
- `ns-tunnel.example.com` → A record pointing to the Elastic IP
- `t.example.com` → NS record delegating to `ns-tunnel.example.com`

Verify propagation:

```bash
# Check A record
dig ns-tunnel.example.com A +short

# Check NS delegation
dig t.example.com NS +short

# Test iodine resolution (should get a response from your server)
dig test.t.example.com @ns-tunnel.example.com
```

DNS propagation typically takes 5-15 minutes.

## Verify Server Health

SSH into the instance and run the health check:

```bash
ssh -i your-key.pem ec2-user@<elastic-ip>
sudo /opt/skytunnel/scripts/health-check.sh
```

Or check individual services:

```bash
sudo systemctl status iodine-server hans-server chisel-server
sudo journalctl -u iodine-server --no-pager -n 20
sudo journalctl -u hans-server --no-pager -n 20
sudo journalctl -u chisel-server --no-pager -n 20
```

## Optional: Enable TLS for Chisel

If you set `EnableLetsEncrypt=true` and DNS has propagated:

```bash
ssh -i your-key.pem ec2-user@<elastic-ip>
sudo /opt/skytunnel/scripts/setup-certbot.sh t.example.com you@example.com
```

Or re-deploy the stack with `EnableLetsEncrypt=true` and `LetsEncryptEmail` set.

## Connect a Client

See [CLIENT.md](CLIENT.md) for client setup and usage.

Quick test:

```bash
# HTTPS tunnel (no root needed)
chisel client --auth user:pass https://t.example.com:443 socks

# Then in another terminal:
curl --socks5 localhost:1080 https://ifconfig.me
```

## Tear Down

```bash
aws cloudformation delete-stack --stack-name skytunnel --region us-east-1
```

This removes all resources including the Elastic IP and DNS records. Your domain's hosted zone is not affected.

## Updating the Stack

To change parameters (e.g., instance type, SSH CIDR):

```bash
aws cloudformation update-stack \
  --stack-name skytunnel \
  --template-body file://cloudformation/skytunnel-stack.yaml \
  --parameters file://cloudformation/params/my-params.json \
  --region us-east-1
```

Note: Changing passwords requires the bootstrap script to re-run. The simplest approach is to SSH in and update `/etc/skytunnel/*.env` then restart the services:

```bash
sudo systemctl restart iodine-server hans-server chisel-server
```
