# install-telemt

Hardened Telemt MTProxy deployment with deep anti-DPI masking, per-user tracking, and single-IP architecture.

## What This Is

A production-ready deployment stack for [Telemt](https://github.com/telemt/telemt) — a Rust/Tokio MTProxy server for Telegram. This repo wraps Telemt with a hardened configuration, a masking reverse proxy (Angie), a one-click deployment script, and documentation born from real deployment experience on EU VPS infrastructure targeting Russian users behind TSPU censorship.

## How It Differs from Vanilla Telemt

| | Vanilla Telemt (quick start) | This Project |
|---|---|---|
| **Masking** | Optional, basic | Full-stack: Angie + PROXY protocol + real Let's Encrypt cert |
| **Anti-DPI** | Default or off | Tuned: SNI/ALPN enforcement, ServerHello delay, shape hardening, timing normalization |
| **Architecture** | Telemt on 443, separate mask domain/IP | Single IP, single domain — DNS/SNI/cert all match (like Xray Reality) |
| **Per-user tracking** | One shared secret | 5 named users with individual secrets and optional ad_tags |
| **Metrics** | Not configured | Prometheus-compatible metrics endpoint |
| **Desktop compat** | Works out of the box | Documented pitfall: `tls_new_session_tickets` breaks Telegram Desktop |
| **Deployment** | Manual | One script: `setup.sh` |

## Architecture

```
                    Internet (DPI / TSPU)
                           │
                           ▼
                  ┌─────────────────┐
                  │  VPS :443       │
                  │  Telemt         │
                  └────┬───────┬────┘
                       │       │
              MTProto  │       │  Unknown / Scanner
              client   │       │  (no valid secret)
                       ▼       ▼
              ┌──────────┐  ┌──────────────────────┐
              │ Middle-  │  │ TCP splice            │
              │ End Pool │  │ + PROXY protocol v1   │
              │          │  │ → 127.0.0.1:4123      │
              │ Telegram │  └──────────┬────────────┘
              │ DCs      │             │
              └──────────┘  ┌──────────▼────────────┐
                            │  Angie :4123          │
                            │  SSL + proxy_protocol │
                            │  Let's Encrypt cert   │
                            │  Landing page         │
                            └───────────────────────┘
```

**Single domain, single IP.** DPI sees: DNS query for `example.com` → TLS SNI `example.com` → certificate `example.com` — perfect consistency. Same principle as Xray Reality, but for MTProxy.

**How Telemt classifies connections:**
- Client sends TLS ClientHello with a secret embedded in the first packet → Telemt recognizes it as MTProto → handles internally → Middle-End pool → Telegram DCs
- Client sends TLS ClientHello without valid secret → Telemt splices the TCP connection to Angie on `127.0.0.1:4123`, prepending PROXY protocol v1 header so Angie knows the real client IP

**Why Angie, not Nginx:**
Angie is a drop-in Nginx fork with built-in ACME (Let's Encrypt) support — no certbot, no cron jobs, no manual renewals. Angie auto-renews certificates inside the container.

## Anti-DPI Configuration Deep-Dive

Every parameter in the `[censorship]` section was tested against real TSPU infrastructure. Here's what each one does and why:

### TLS Fingerprinting Defense

```toml
tls_emulation = true              # Mimic real TLS server behavior
server_hello_delay_min_ms = 8     # Random delay before ServerHello
server_hello_delay_max_ms = 24    # Real servers don't respond in 0ms
alpn_enforce = true               # Require consistent ALPN negotiation
tls_new_session_tickets = 0       # MUST be 0 (see "Desktop Bug" below)
```

**`tls_new_session_tickets = 0`** — This is the critical finding. Real TLS servers send NewSessionTicket records after the handshake. We originally set this to `2` to match real Angie behavior. However, Telegram Desktop strictly validates post-handshake data: it expects the first bytes after handshake to be the 64-byte MTProto key exchange. Extra NewSessionTicket records cause Desktop to close the connection with `expected 64 bytes, got 0`. Mobile clients are more lenient. **Default in Telemt is 0; do not set it to 2.**

**`server_hello_delay`** — DPI systems measure response timing. A 0ms ServerHello is suspicious (proxy processing, no real app logic). 8-24ms mimics a real web server with some processing overhead. Tested safe with Telegram Desktop at these values.

**`alpn_enforce = true`** — Forces ALPN negotiation to match what a real TLS server would offer. Prevents ALPN-based probing by DPI.

### Traffic Shape Hardening

```toml
mask_shape_hardening = true                 # Pad packets to defeat size fingerprinting
mask_shape_hardening_aggressive_mode = false
mask_shape_bucket_floor_bytes = 512        # Minimum padded size
mask_shape_bucket_cap_bytes = 4096         # Maximum padded size
```

DPI can identify MTProxy by packet sizes — MTProto has distinctive 64-byte handshake, then specific chunk sizes. Shape hardening pads all packets into buckets (512-4096 bytes), making traffic indistinguishable from normal HTTPS.

`aggressive_mode = false` — aggressive mode adds more padding but significantly increases bandwidth (2-3x). For most use cases, standard mode is sufficient and costs less traffic.

### Timing Normalization

```toml
mask_timing_normalization_enabled = true
mask_timing_normalization_floor_ms = 50     # Minimum delay between packets
mask_timing_normalization_ceiling_ms = 500  # Maximum delay
```

DPI can fingerprint protocols by inter-packet timing patterns. MTProto has a distinctive burst pattern. This normalizes timing to look like typical web browsing (request-response with 50-500ms gaps).

### Connection Handling

```toml
unknown_sni_action = "mask"       # Wrong SNI → forward to mask, don't drop
rst_on_close = "errors"           # Send RST (not FIN) on error — looks like normal server
```

**`unknown_sni_action = "mask"`** — If a scanner or DPI probe connects with a different SNI, don't reject it. Forward to Angie, which serves a real website. This makes the server indistinguishable from a normal web server under probe.

**`rst_on_close`** — When Telemt closes an error connection, it sends TCP RST instead of FIN. This matches normal web server behavior (nginx/apache send RST on malformed requests). FIN on error would be unusual and detectable.

### Mask Target (Angie)

```toml
mask = true
mask_host = "127.0.0.1"
mask_port = 4123
mask_proxy_protocol = 1           # Send PROXY protocol v1 header
```

`mask_host = "127.0.0.1"` — Direct IP, no DNS resolution. This is like `dest` in Xray Reality — no separate mask domain needed, no DNS leak.

`mask_proxy_protocol = 1` — Telemt prepends PROXY protocol v1 header before splicing the TCP stream to Angie. Angie reads the real client IP from this header (`set_real_ip_from 127.0.0.1; real_ip_header proxy_protocol;`), so access logs show actual client IPs, not 127.0.0.1.

## Why EU VPS (Not RU)

Russian TSPU blocks Telegram Data Centers by **IP address** (SYN drop), not just by DPI on TLS. Tools like zapret/NoDPI/dpibreak cannot bypass IP-level blocking — they work only against DPI (packet inspection). A proxy inside Russia still needs to reach Telegram DCs, which are IP-blocked. Therefore, the proxy must be outside Russia (EU VPS), where Telegram DC IPs are reachable.

## Lessons Learned (Bugs Found)

### 1. `tls_new_session_tickets` Breaks Telegram Desktop

**Symptom:** Mobile connects fine, Desktop shows "not available". Logs: `Connection closed during initial handshake error=IO error: expected 64 bytes, got 0`

**Cause:** `tls_new_session_tickets = 2` sends extra TLS records after handshake. Desktop Telegram expects immediate MTProto data (64 bytes) and closes the connection when it sees unexpected TLS records instead.

**Fix:** `tls_new_session_tickets = 0` (Telemt default). Mobile clients tolerate extra records; Desktop does not.

### 2. `[server.metrics]` Is Not a Valid Section

**Symptom:** Metrics endpoint returns empty response on `:9090/metrics`.

**Cause:** Telemt expects `metrics_port`, `metrics_listen`, `metrics_whitelist` as fields **inside** `[server]`, not as a separate `[server.metrics]` section. In TOML, `[server.metrics]` creates a nested object which Telemt doesn't parse.

**Fix:**
```toml
[server]
port = 443
max_connections = 10000
metrics_port = 9090
metrics_listen = "127.0.0.1:9090"
metrics_whitelist = ["127.0.0.1/32", "::1/128"]
```

### 3. Angie `acme_client` Syntax

**Symptom:** Angie fails to start with config parse error.

**Cause:** Angie's `acme_client` directive uses semicolon syntax, not block syntax:
```
# WRONG (Nginx-style block — Angie rejects this):
acme_client le https://acme-v02.api.letsencrypt.org/directory {
    challenge /tmp/acme;
}

# CORRECT (Angie syntax):
acme_client le https://acme-v02.api.letsencrypt.org/directory;
```

### 4. `WatchdogSec=60` Kills Telemt During ME Pool Init

**Symptom:** Telemt starts, then systemd kills it after ~60 seconds. Repeated restart loop.

**Cause:** Middle-End pool initialization (connecting to Telegram DCs) can take over 60 seconds, especially on first start or slow networks. `WatchdogSec=60` tells systemd the process is hung if it doesn't notify within 60s.

**Fix:** `WatchdogSec=300` — gives ME pool 5 minutes to initialize.

### 5. Metrics Fields Must Be in `[server]`, Not `[server.api]`

**Symptom:** Metrics still not working after fix #2.

**Cause:** In TOML, all key-value pairs after a section header belong to that section until the next header. If `metrics_*` fields are placed after `[server.api]`, they become part of the API config, not the server config.

**Fix:** Place `metrics_*` fields immediately after `max_connections`, before `[server.api]`.

## Quick Start

### 1. DNS Setup (Cloudflare)

| Record | Type | Value | Proxy |
|--------|------|-------|-------|
| `tg.yourdomain.org` | A | Your VPS IP | **OFF** (grey cloud) |

**Must be DNS-only.** Cloudflare proxy (orange cloud) terminates TLS before it reaches Telemt, breaking MTProto.

### 2. Deploy

```bash
git clone https://github.com/rxlxmpxgx/install-telemt.git
cd install-telemt/deploy
chmod +x setup.sh
sudo ./setup.sh
```

The script will prompt for:
- **Domain** — used for both proxy links and SNI masking (e.g. `tg.yourdomain.org`)
- **Admin IP** — your IP for API/metrics access (optional, leave blank for localhost-only)

It will automatically:
- Install Docker + Telemt binary
- Generate 5 per-user secrets (`s1`-`s5`)
- Write Telemt config with hardened anti-DPI settings
- Deploy Angie in Docker with auto-issuing Let's Encrypt certificates
- Configure systemd, kernel tuning, UFW firewall
- Print proxy links

### 3. Verify

```bash
systemctl status telemt          # Telemt running
docker ps | grep angie           # Angie running
curl -s http://127.0.0.1:9091/v1/users | jq   # API works
curl -s http://127.0.0.1:9090/metrics | head -5  # Metrics work
```

Test from outside:
```bash
# From another machine — should see the landing page
curl -v https://tg.yourdomain.org/
```

### 4. Monetization (@MTProxybot)

1. Open [@MTProxybot](https://t.me/MTProxybot) in Telegram
2. `/newproxy` → send `tg.yourdomain.org:443`
3. Send the secret for any user (e.g. `s1`'s value from `/etc/telemt/telemt.toml`)
4. Bot gives you an `ad_tag` (32 hex chars)
5. Set it in config: `ad_tag = "YOUR_AD_TAG"` (uncomment the line)
6. `systemctl restart telemt`
7. In bot: `/myproxies` → select proxy → "Set promotion" → send your channel link
8. Wait ~1 hour for Telegram to propagate

**Per-user promoted channels:**
```toml
[access.user_ad_tags]
s1 = "ad_tag_for_channel_A"
s3 = "ad_tag_for_channel_B"
```

This lets you run different ads for different user segments.

## Configuration Reference

### Per-User Secrets

Each user gets a unique 32-hex-char secret. Proxy links are generated per-user:

```bash
# Generate a new secret
openssl rand -hex 16
# e.g. a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6

# Add to [access.users]
newuser = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"

# Telemt hot-reloads config — no restart needed
# Verify:
curl -s http://127.0.0.1:9091/v1/users | jq
```

### Proxy Link Format

TLS links encode the domain into the secret:
```
tg://proxy?server=tg.yourdomain.org&port=443&secret=eeSECRET_HEX7467732e796f7572646f6d61696e2e6f7267
```

The `ee` prefix + secret + hex-encoded domain = TLS-mode link. Telemt API generates these automatically.

### Metrics

Prometheus-compatible endpoint at `:9090/metrics`. Key metrics:

| Metric | Meaning |
|--------|---------|
| `telemt_build_info` | Version |
| `telemt_uptime_seconds` | Proxy uptime |
| `telemt_active_connections` | Current connections |
| `telemt_total_connections` | Cumulative connections |
| `telemt_handshake_failures` | Failed MTProto handshakes (DPI probing or wrong secrets) |

## File Structure

```
deploy/
├── telemt.toml          # Production config template (replace secrets & domain)
├── setup.sh             # One-click deployment script
├── DEPLOY_GUIDE.md      # Detailed deployment & operations guide
├── systemd/
│   └── telemt.service   # systemd unit file
└── angie/
    ├── angie.conf       # Angie config (not used by setup.sh, reference only)
    ├── docker-compose.yml
    └── index.html       # Landing page
```

`setup.sh` writes all configs inline (Angie, systemd, etc.) — the files in `angie/` and `systemd/` are for reference and manual deployment.

## Security Checklist

- [ ] UFW: only 22, 80, 443 open (9090/9091 localhost only)
- [ ] SSH: key-based auth only, no passwords
- [ ] `mask_proxy_protocol = 1` — Angie logs real client IPs
- [ ] `unknown_sni_action = "mask"` — probes see a real website
- [ ] `rst_on_close = "errors"` — scanners can't distinguish from normal server
- [ ] `mask_shape_hardening = true` — defeats packet-size fingerprinting
- [ ] `mask_timing_normalization = true` — defeats timing analysis
- [ ] Fail2ban: `apt install fail2ban`
- [ ] Auto security updates: `dpkg-reconfigure -plow unattended-upgrades`

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Desktop: "not available", mobile works | `tls_new_session_tickets > 0` | Set to `0` |
| Metrics empty on `:9090` | `metrics_*` in wrong TOML section | Move to `[server]`, before `[server.api]` |
| Angie won't start | `acme_client` block syntax | Use semicolon: `acme_client le https://... ;` |
| Telemt restart loop | `WatchdogSec=60` | Set to `300` |
| "expected 64 bytes, got 0" in logs | Desktop client rejecting post-handshake data | `tls_new_session_tickets = 0` |
| Can't reach Telegram DCs | RU-based VPS, TSPU IP-blocks DCs | Use EU VPS |
