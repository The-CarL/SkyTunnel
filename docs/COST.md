# SkyTunnel Cost Breakdown

All prices are US East (N. Virginia) on-demand as of 2026. Actual costs may vary by region.

## Monthly Cost Estimate (Always-On)

| Resource | Cost/Month | Notes |
|----------|-----------|-------|
| EC2 t3.nano | ~$3.80 | 2 vCPU, 0.5 GiB RAM |
| EBS gp3 10GB | ~$0.80 | Root volume |
| Elastic IP | $0.00 | Free when attached to running instance |
| Route 53 hosted zone | $0.50 | Per hosted zone (you likely already have this) |
| Route 53 queries | ~$0.40 | ~1M DNS queries/month (iodine tunnel traffic) |
| Data transfer | ~$0.00-$4.50 | First 100 GB/month free, then $0.09/GB |
| **Total** | **~$5-10/mo** | Depends on data transfer |

## Cost Details

### EC2 Instance

| Instance Type | vCPU | Memory | Cost/Month |
|---------------|------|--------|-----------|
| t3.nano | 2 | 0.5 GiB | $3.80 |
| t3.micro | 2 | 1.0 GiB | $7.59 |
| t3.small | 2 | 2.0 GiB | $15.18 |

**Recommendation**: `t3.nano` is sufficient for tunnel traffic. Upgrade to `t3.micro` only if you experience memory pressure during compilation on first boot (the bootstrap script compiles iodine and hans from source).

### Elastic IP

- **Attached to running instance**: $0.00/hr
- **Detached or attached to stopped instance**: $0.005/hr (~$3.65/month)

If you stop the instance, the EIP still costs money. Either release it (but you'll get a new IP on next deploy) or keep the instance running.

### Data Transfer

- **Inbound**: Free
- **Outbound first 100 GB/month**: Free (AWS free tier)
- **Outbound beyond 100 GB**: $0.09/GB

For typical tunnel usage (web browsing, SSH), you're unlikely to exceed 100 GB/month. Heavy use like streaming or large downloads will incur transfer costs.

### Route 53

- **Hosted zone**: $0.50/month (shared with your other DNS records)
- **Standard queries**: $0.40 per million queries
- **DNS tunnel traffic**: Each DNS tunnel packet is a DNS query. At ~100 KB/s throughput, that's roughly 500-1000 queries/second, or ~2.6 billion/month at sustained use. Realistically, intermittent use generates far fewer queries.

## Cost Optimization

### Spot Instances

You can modify the CF template to use a spot instance for up to 90% savings. Add to the instance properties:

```yaml
InstanceMarketOptions:
  MarketType: spot
  SpotOptions:
    MaxPrice: "0.005"
    SpotInstanceType: persistent
```

Risk: Spot instances can be terminated with 2-minute notice. Not ideal for always-on tunnel availability.

### Scheduled Start/Stop

If you only need the tunnel during travel, use AWS Instance Scheduler or a simple cron-based Lambda to start/stop the instance. Remember: the EIP costs $3.65/month when the instance is stopped.

### Reserved Instances

For a 1-year commitment on t3.nano: ~$2.19/month (42% savings). Probably not worth the commitment for a personal tunnel server.

## Bottom Line

**Run it 24/7 for ~$5-8/month.** The EIP penalty for stopping ($3.65/mo) means there's little savings in turning it off. The cheapest approach is `t3.nano` always-on with minimal data transfer.
