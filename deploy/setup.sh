#!/bin/bash
set -euo pipefail

# =============================================
# Telemt + Angie Single-IP Deployment Script
# Target: Ubuntu 24.04
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Configuration ---
PROXY_DOMAIN="${PROXY_DOMAIN:-}"
ADMIN_IP="${ADMIN_IP:-}"

echo ""
echo "============================================="
echo "  Telemt + Angie Deployment"
echo "  Single-IP: Telemt:443 + Angie:4123+80"
echo "============================================="
echo ""

# --- Interactive prompts ---
if [ -z "$PROXY_DOMAIN" ]; then
    read -rp "Enter domain (e.g. vpn.example.com, used for both proxy links and masking): " PROXY_DOMAIN
fi
if [ -z "$ADMIN_IP" ]; then
    read -rp "Enter your admin IP for API/metrics access (e.g. 1.2.3.4): " ADMIN_IP
fi

[ -z "$PROXY_DOMAIN" ] && error "Domain is required"

info "Domain: $PROXY_DOMAIN (used for both proxy links and SNI masking)"
info "Admin IP: ${ADMIN_IP:-all allowed}"

# --- Step 1: System updates ---
info "Updating system..."
apt update && apt upgrade -y
apt autoremove -y

# --- Step 2: Install Docker ---
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
else
    info "Docker already installed"
fi

# --- Step 3: Install Telemt ---
if ! command -v telemt &>/dev/null; then
    info "Installing Telemt..."
    wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-$(uname -m)-linux-$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu).tar.gz" | tar -xz
    mv telemt /bin
    chmod +x /bin/telemt
else
    info "Telemt already installed: $(telemt --version 2>/dev/null || echo 'unknown')"
fi

# --- Step 4: Generate per-user secrets ---
info "Generating per-user secrets..."
SECRETS_DIR="/etc/telemt"
mkdir -p "$SECRETS_DIR" /opt/telemt /tmp/angie-deploy

USERS=("s1" "s2" "s3" "s4" "s5")
SECRET_LINES=""

for user in "${USERS[@]}"; do
    secret=$(openssl rand -hex 16)
    SECRET_LINES="${SECRET_LINES}${user} = \"${secret}\"\n"
    info "  Generated: $user = $secret"
done

# --- Step 5: Write Telemt config ---
info "Writing Telemt config..."

cat > /etc/telemt/telemt.toml <<TELEMT_EOF
[general]
use_middle_proxy = true
# ad_tag = "REPLACE_WITH_YOUR_AD_TAG"
log_level = "normal"
fast_mode = true
rst_on_close = "errors"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PROXY_DOMAIN}"

[server]
port = 443
max_connections = 10000
metrics_port = 9090
metrics_listen = "127.0.0.1:9090"
metrics_whitelist = ["127.0.0.1/32", "::1/128"$([ -n "$ADMIN_IP" ] && echo ", \"${ADMIN_IP}/32\"")]

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"$([ -n "$ADMIN_IP" ] && echo ", \"${ADMIN_IP}/32\"")]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${PROXY_DOMAIN}"
mask = true
mask_host = "127.0.0.1"
mask_port = 4123
mask_proxy_protocol = 1
tls_emulation = true
tls_front_dir = "/etc/telemt/tlsfront"
server_hello_delay_min_ms = 8
server_hello_delay_max_ms = 24
alpn_enforce = true
tls_new_session_tickets = 0
mask_shape_hardening = true
mask_shape_bucket_floor_bytes = 512
mask_shape_bucket_cap_bytes = 4096
mask_timing_normalization_enabled = true
mask_timing_normalization_floor_ms = 50
mask_timing_normalization_ceiling_ms = 500
unknown_sni_action = "mask"

[access.users]
$(echo -e "$SECRET_LINES" | head -c -1)
TELEMT_EOF

mkdir -p /etc/telemt/tlsfront

# --- Step 6: Create telemt user ---
if ! id telemt &>/dev/null; then
    useradd -d /opt/telemt -m -r -U telemt
fi
chown -R telemt:telemt /etc/telemt

# --- Step 7: Write Angie config ---
info "Deploying Angie (masking web server)..."

mkdir -p /opt/angie

cat > /opt/angie/angie.conf <<ANGIE_EOF
user angie;
worker_processes auto;
error_log /var/log/angie/error.log notice;

events {
    worker_connections 1024;
}

http {
    log_format main '[\$time_local] \$proxy_protocol_addr "\$http_referer" "\$http_user_agent"';
    access_log /var/log/angie/access.log main;

    server {
        listen 80;
        listen [::]:80;
        server_name ${PROXY_DOMAIN};

        location /.well-known/acme-challenge/ {
            root /tmp/acme;
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    resolver 1.1.1.1 8.8.8.8;
    acme_client le https://acme-v02.api.letsencrypt.org/directory;

    server {
        listen 127.0.0.1:4123 ssl proxy_protocol;
        http2 on;

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        server_name ${PROXY_DOMAIN};

        acme le;
        ssl_certificate \$acme_cert_le;
        ssl_certificate_key \$acme_cert_key_le;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_session_timeout 1d;
        ssl_session_cache shared:SSL:50m;

        location / {
            root /tmp;
            index index.html;
        }
    }
}
ANGIE_EOF

cat > /opt/angie/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Secure Connection Gateway</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: #333; background: #f5f7fa; }
        .container { max-width: 720px; margin: 0 auto; padding: 80px 24px; text-align: center; }
        h1 { font-size: 2rem; font-weight: 600; margin-bottom: 16px; color: #1a1a2e; }
        p { font-size: 1.1rem; line-height: 1.6; color: #555; margin-bottom: 24px; }
        .status { display: inline-block; padding: 8px 24px; border-radius: 20px; background: #e8f5e9; color: #2e7d32; font-weight: 500; }
        footer { margin-top: 60px; font-size: 0.85rem; color: #999; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Secure Gateway</h1>
        <p>This service provides secure and reliable connectivity infrastructure. All connections are encrypted and protected.</p>
        <div class="status">Service Operational</div>
        <footer>&copy; 2026 Secure Gateway. All rights reserved.</footer>
    </div>
</body>
</html>
HTML_EOF

cat > /opt/angie/docker-compose.yml <<'DC_EOF'
services:
  angie:
    image: docker.angie.software/angie:minimal
    container_name: angie
    restart: always
    network_mode: host
    volumes:
      - ./angie.conf:/etc/angie/angie.conf:ro
      - ./index.html:/tmp/index.html:ro
      - angie-data:/var/lib/angie
      - acme-challenge:/tmp/acme

volumes:
  angie-data:
  acme-challenge:
DC_EOF

# --- Step 8: Start Angie ---
info "Starting Angie..."
cd /opt/angie
docker compose up -d
sleep 3

if ! docker ps | grep -q angie; then
    error "Angie failed to start! Check: docker logs angie"
fi
info "Angie is running"

# --- Step 9: Install Telemt systemd service ---
info "Installing Telemt systemd service..."

cat > /etc/systemd/system/telemt.service <<'SVC_EOF'
[Unit]
Description=Telemt MTProxy Server
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
WatchdogSec=300

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable telemt
systemctl start telemt
sleep 2

if systemctl is-active --quiet telemt; then
    info "Telemt is running"
else
    error "Telemt failed to start! Check: journalctl -u telemt -n 50"
fi

# --- Step 10: Kernel tuning ---
info "Applying kernel tuning..."

cat >> /etc/sysctl.conf <<'SYSCTL_EOF'

# Telemt optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_time = 90
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
fs.file-max = 1048576
SYSCTL_EOF

sysctl -p

# --- Step 11: File limits ---
info "Setting file limits..."

cat > /etc/security/limits.d/telemt.conf <<'LIMITS_EOF'
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
LIMITS_EOF

# --- Step 12: Firewall ---
info "Configuring firewall..."

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

info "Firewall configured (22, 80, 443 open)"

# --- Step 13: Verify masking ---
info "Verifying mask target..."
sleep 2

MASK_CHECK=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "${PROXY_DOMAIN}:4123:127.0.0.1" "https://${PROXY_DOMAIN}:4123/" 2>/dev/null || echo "000")

if [ "$MASK_CHECK" = "200" ] || [ "$MASK_CHECK" = "301" ] || [ "$MASK_CHECK" = "302" ]; then
    info "Mask target is responding (HTTP $MASK_CHECK)"
else
    warn "Mask target returned HTTP $MASK_CHECK — Let's Encrypt may need time. Run: docker logs angie"
fi

# --- Done ---
echo ""
echo "============================================="
echo -e "  ${GREEN}DEPLOYMENT COMPLETE${NC}"
echo "============================================="
echo ""
echo "  Proxy links (distribute these):"
echo ""

curl -s http://127.0.0.1:9091/v1/users | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for user in data.get('data', []):
        name = user.get('username', '?')
        links = user.get('links', {}).get('tls', [])
        if links:
            print(f'  [{name}] {links[0]}')
        else:
            print(f'  [{name}] no TLS link generated')
except:
    print('  (run manually: curl -s http://127.0.0.1:9091/v1/users | jq')
" 2>/dev/null || echo "  (run: curl -s http://127.0.0.1:9091/v1/users | jq)"

echo ""
echo "  Metrics:  curl -s http://127.0.0.1:9090/metrics"
echo "  API:      curl -s http://127.0.0.1:9091/v1/users"
echo ""
echo "  Next steps:"
echo "  1. Register proxy in @MTProxybot for ad_tag"
echo "  2. Set up Cloudflare DNS (see DEPLOY_GUIDE.md)"
echo "  3. Install Prometheus + Grafana for monitoring"
echo ""
