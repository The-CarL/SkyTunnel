# SkyTunnel Troubleshooting

## Server-Side Issues

### Check overall health

```bash
sudo /opt/skytunnel/scripts/health-check.sh
```

### Service not starting

Check logs for each service:

```bash
sudo journalctl -u iodine-server --no-pager -n 50
sudo journalctl -u hans-server --no-pager -n 50
sudo journalctl -u chisel-server --no-pager -n 50
```

Restart a service:

```bash
sudo systemctl restart iodine-server
```

### Bootstrap log

If the stack creation fails, check the bootstrap log:

```bash
sudo cat /var/log/skytunnel-bootstrap.log
```

---

## iodine (DNS Tunnel)

### "No suitable DNS reply"

**Cause**: DNS delegation is not set up correctly, or DNS hasn't propagated.

**Fix**:
1. Verify the NS record exists:
   ```bash
   dig t.example.com NS +short
   # Should return: ns-tunnel.example.com.
   ```
2. Verify the A record points to the server:
   ```bash
   dig ns-tunnel.example.com A +short
   # Should return the Elastic IP
   ```
3. Wait 15-30 minutes for DNS propagation
4. Try specifying the nameserver directly:
   ```bash
   sudo iodine -f -P password ns-tunnel.example.com t.example.com
   ```

### "Connection refused" or no response

**Cause**: Port 53 UDP is blocked or iodined is not running.

**Fix**:
1. Check the service: `sudo systemctl status iodine-server`
2. Verify the security group allows UDP 53 inbound
3. Test from the server itself: `dig @127.0.0.1 test.t.example.com`

### Extremely slow throughput (< 10 KB/s)

**Cause**: Intermediate DNS resolver caching or rate limiting.

**Fix**:
- Try different encoding: `sudo iodine -f -O raw -P password ns-tunnel.example.com t.example.com`
- Reduce MTU: `sudo iodine -f -m 200 -P password ns-tunnel.example.com t.example.com`
- Try bypassing local resolver: `sudo iodine -f -P password 8.8.8.8 t.example.com`

---

## hans (ICMP Tunnel)

### "Connection timeout"

**Cause**: Network blocks ICMP, or the server isn't configured correctly.

**Fix**:
1. Test basic ICMP from client: `ping <server-ip>` (note: server won't reply because `icmp_echo_ignore_all=1`)
2. Verify hans is running on server: `sudo systemctl status hans-server`
3. Verify `icmp_echo_ignore_all=1`: `sysctl net.ipv4.icmp_echo_ignore_all` on the server
4. Check security group allows ICMP inbound

### "hans: can't open tun device"

**Cause**: TUN kernel module not loaded (Linux), or missing permissions (macOS).

**Fix (macOS)**: Ensure you're running with `sudo`. macOS uses the built-in utun interface — no kernel module needed.

**Fix (Linux)**:
```bash
sudo modprobe tun
sudo hans -c <server-ip> -p password -f
```

### Server not responding to hans but ping works

**Cause**: `icmp_echo_ignore_all` is set to 0 — the kernel is responding to pings instead of hans.

**Fix** (on server):
```bash
sudo sysctl net.ipv4.icmp_echo_ignore_all=1
```

---

## chisel (HTTPS Tunnel)

### "TLS handshake failure"

**Cause**: TLS certificate not set up, or certificate doesn't match the domain.

**Fix**:
1. Check if chisel is running with TLS: `sudo journalctl -u chisel-server -n 10`
2. If no TLS, the client should use `http://` instead of `https://`:
   ```bash
   chisel client --auth user:pass http://<server-ip>:443 socks
   ```
3. Or set up certbot:
   ```bash
   sudo /opt/skytunnel/scripts/setup-certbot.sh t.example.com you@example.com
   ```

### "Authentication failed"

**Cause**: Incorrect `--auth` credentials.

**Fix**: Verify the `ChiselAuth` parameter matches what you're using on the client. Format is `user:password`.

### "Connection refused" on port 443

**Cause**: Chisel isn't running or can't bind to port 443.

**Fix**:
1. Check service: `sudo systemctl status chisel-server`
2. Check port binding: `sudo ss -tlnp | grep 443`
3. Check logs: `sudo journalctl -u chisel-server -n 20`
4. If capability issue: `sudo setcap cap_net_bind_service=+ep /usr/local/bin/chisel`

### SOCKS proxy on 1080 not working

**Cause**: chisel client connected but SOCKS proxy not listening.

**Fix**:
1. Check chisel client is running: `ps aux | grep chisel`
2. Check port 1080: `lsof -i :1080` (macOS) or `ss -tlnp | grep 1080` (Linux)
3. Try connecting with verbose output: `chisel client --verbose ...`

---

## Client Script Issues

### "command not found: skytunnel-client"

```bash
chmod +x scripts/client/skytunnel-client
# Add to PATH:
sudo ln -s "$(pwd)/scripts/client/skytunnel-client" /usr/local/bin/skytunnel-client
```

### Config file not found

```bash
mkdir -p ~/.skytunnel
cp scripts/client/config.example.yaml ~/.skytunnel/config.yaml
# Edit with your values
```

### "requires root" error for DNS/ICMP

iodine and hans need to create TUN devices, which requires root:

```bash
sudo skytunnel-client connect dns
```

### SSH SOCKS proxy fails after DNS/ICMP connect

DNS and ICMP tunnels create an IP tunnel (tun device), but apps need a SOCKS proxy. The client bridges this by running `ssh -D 1080` through the tunnel IP. This requires:

1. `ssh_key` set in `~/.skytunnel/config.yaml` (or `SKYTUNNEL_SSH_KEY` env var)
2. SSH server running on the EC2 instance (it is, by default)
3. The tunnel IP is reachable (ping `10.53.0.1` for iodine, `10.54.0.1` for hans)

**Fix**: Set your SSH key in the config:
```yaml
# ~/.skytunnel/config.yaml
ssh_key: ~/.ssh/skytunnel.pem
ssh_user: ec2-user
```

Or via environment:
```bash
export SKYTUNNEL_SSH_KEY=~/.ssh/skytunnel.pem
```

If SSH connects but SOCKS doesn't work, verify manually:
```bash
# After iodine/hans tunnel is up:
ssh -i ~/.ssh/skytunnel.pem -D 1080 -N ec2-user@10.53.0.1
# Then in another terminal:
curl --socks5 localhost:1080 https://ifconfig.me
```

---

## General Debugging

### Check what's running

```bash
# Client (macOS/Linux)
skytunnel-client status
ps aux | grep -E '(iodine|hans|chisel)'
lsof -i :1080                 # macOS
ss -tlnp | grep 1080          # Linux

# Server (SSH in first)
sudo systemctl status iodine-server hans-server chisel-server
sudo ss -tulnp | grep -E '(53|443|1080)'
ip addr show  # Check tun devices
```

### Test connectivity step by step

```bash
# 1. Can you reach the server at all?
ping <elastic-ip>  # May not respond (icmp_echo_ignore_all)
nc -zv <elastic-ip> 443  # TCP 443 (chisel)
nc -zuv <elastic-ip> 53  # UDP 53 (iodine)

# 2. Can you resolve the tunnel domain?
dig t.example.com NS
dig test.t.example.com @ns-tunnel.example.com

# 3. Try connecting with verbose output
chisel client --verbose --auth user:pass https://t.example.com:443 socks
sudo iodine -f -DD -P password ns-tunnel.example.com t.example.com
sudo hans -c <ip> -p password -f -v
```

### CloudFormation stack failed

```bash
# Check stack events for the failure reason
aws cloudformation describe-stack-events \
  --stack-name skytunnel \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table
```

Common causes:
- Key pair doesn't exist in the target region
- Hosted zone ID is incorrect
- Instance type not available in the AZ
- Bootstrap script timeout (increase `CreationPolicy` timeout)
