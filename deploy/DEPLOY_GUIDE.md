# Telemt Deployment Guide

## Architecture (Single IP)

```
Client → vpn.dmn.com:443 (Telemt)
           ├── valid key → MTProxy → Middle-End → Telegram DC
           └── no key   → TCP splice + PROXY_protocol v1 → 127.0.0.1:4123
                                                               │
                                               Angie (ssl + proxy_protocol)
                                               real Let's Encrypt cert for vpn.dmn.com
                                               serves landing page
                                                               │
                                               DPI sees: DNS→SNI→Cert ALL match ✓
                                               Crawlers see: real website ✓
```

---

## 1. Cloudflare DNS Setup

Before running the deployment script, configure DNS in Cloudflare:

| Subdomain | Type | Value | Proxy | Purpose |
|-----------|------|-------|-------|---------|
| `vpn.YOURDOMAIN.com` | A | Server IP | OFF (grey cloud) | Proxy links + SNI masking + Let's Encrypt (one domain for everything) |

**MUST be DNS-only (grey cloud).** Orange cloud (Cloudflare proxy) breaks Telemt — it terminates TLS before it reaches the server.

**One domain for everything** = DPI sees perfect consistency: DNS query → SNI → certificate all match `vpn.YOURDOMAIN.com`. Identical to Xray Reality behavior.

**When switching servers:** change A record to new IP. Links stay valid because they use `vpn.YOURDOMAIN.com`.

---

## 2. Deploy (on each server)

```bash
# Copy deploy/ folder to server, then:
chmod +x setup.sh
sudo ./setup.sh
```

Or run manually step by step (see setup.sh for reference).

**After deployment, verify:**

```bash
# Telemt status
systemctl status telemt

# Angie status
docker ps | grep angie

# Test mask target (from server)
curl -v --resolve vpn.YOURDOMAIN.com:443:YOUR_SERVER_IP https://vpn.YOURDOMAIN.com/

# Get proxy links
curl -s http://127.0.0.1:9091/v1/users | jq

# Check metrics
curl -s http://127.0.0.1:9090/metrics | head -30
```

---

## 3. Monitoring with Prometheus + Grafana

### Install on the server (or a separate monitoring host)

```bash
# Prometheus
apt install prometheus

# Grafana
apt install -y software-properties-common
add-apt-repository -y "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main"
wget -q -O /usr/share/keyrings/grafana.gpg https://apt.grafana.com/gpg.key
apt update && apt install grafana
```

### Prometheus config (/etc/prometheus/prometheus.yml)

```yaml
scrape_configs:
  - job_name: 'telemt'
    scrape_interval: 15s
    static_configs:
      - targets:
          - 'SERVER_IP:9090'    # Server 1
          # - 'SERVER2_IP:9090' # Server 2
          # - 'SERVER3_IP:9090' # Server 3
```

**Note:** Open port 9090 in firewall ONLY for the Prometheus host IP:
```bash
ufw allow from PROMETHEUS_IP to any port 9090 proto tcp
```

### Key metrics to monitor

| Metric | Alert if | Meaning |
|--------|----------|---------|
| `telemt_active_connections` | > 8000 | Approaching max_connections |
| `telemt_total_connections` | rapid growth | Potential DDoS/scanning |
| `telemt_bytes_received` / `bytes_sent` | — | Traffic per user |
| `telemt_handshake_failures` | spike | DPI probing or wrong secrets |

### Grafana dashboard

Telemt provides a pre-built Grafana dashboard JSON in `tools/` directory on GitHub. Import it via Grafana UI → Dashboards → Import.

---

## 4. @MTProxybot — Promoted Channel Setup

1. Open @MTProxybot in Telegram
2. `/newproxy` → send `vpn.YOURDOMAIN.com:443`
3. Send the **user secret** from any user in `[access.users]` (e.g. `s1`'s secret)
4. Bot gives you an **ad_tag** (32 hex chars)
5. Put it in config: `ad_tag = "YOUR_AD_TAG"`
6. Set `use_middle_proxy = true` (already on by default)
7. Restart: `systemctl restart telemt`
8. In bot: `/myproxies` → select → "Set promotion" → send channel link
9. Wait ~1 hour for Telegram to update

**Per-user promoted channels:**
```toml
[access.user_ad_tags]
s1 = "ad_tag_channel_A"
s3 = "ad_tag_channel_B"
```

---

## 5. Operations

### Add a new user (no restart needed)

```bash
# Generate secret
NEW_SECRET=$(openssl rand -hex 16)

# Edit config — add line under [access.users]
# newsource = "NEW_SECRET"
nano /etc/telemt/telemt.toml

# Telemt hot-reloads config automatically
# Verify:
curl -s http://127.0.0.1:9091/v1/users | jq
```

### Rotate secrets

```bash
# Generate new secret, update config, restart
NEW_SECRET=$(openssl rand -hex 16)
# Edit /etc/telemt/telemt.toml
systemctl restart telemt
```

### Migrate to new server

1. Deploy Telemt + Angie on new server (run setup.sh)
2. Copy `/etc/telemt/telemt.toml` to new server (same secrets!)
3. In Cloudflare: change A record → new IP
4. Wait for DNS propagation (minutes with low TTL)
5. Old server can be decommissioned once connections drain

### View per-user stats

```bash
# All users summary
curl -s http://127.0.0.1:9091/v1/users | jq

# Specific user details
curl -s http://127.0.0.1:9091/v1/users | jq '.data[] | select(.username == "s1")'
```

---

## 6. Security Checklist

- [ ] UFW enabled: only 22, 80, 443 open (9090/9091 localhost only)
- [ ] SSH: key-based auth only, no password login
- [ ] `rst_on_close = "errors"` — scanners get RST, not FIN (looks like normal server)
- [ ] `mask_proxy_protocol = 1` — Angie sees real client IP in logs
- [ ] `mask_shape_hardening = true` — padding defeats packet-size fingerprinting
- [ ] `mask_timing_normalization = true` — timing mask defeats timing analysis
- [ ] `unknown_sni_action = "mask"` — wrong SNI gets masked, not dropped
- [ ] `tls_emulation = true` — cert lengths match real server
- [ ] Fail2ban for SSH (optional but recommended): `apt install fail2ban`
- [ ] Automatic security updates: `apt install unattended-upgrades`

---

## 7. Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| "Too many open files" | `ulimit -n` | Should be 1048576 (set in systemd + limits.conf) |
| "Unknown TLS SNI" errors | `tls_domain` mismatch | Ensure links use current `tls_domain` |
| Mask not working | `docker logs angie` | Let's Encrypt cert may not be issued yet |
| Can't connect to proxy | Firewall, DNS | Verify port 443 open, vpn.YOURDOMAIN.com resolves |
| Angie cert error | ACME challenge | Port 80 must be accessible from internet for Let's Encrypt |
