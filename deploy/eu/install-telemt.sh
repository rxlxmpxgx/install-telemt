#!/bin/bash
set -euo pipefail

# =============================================
# Telemt Proxy — EU Exit Node Telemt Installer
# Adds Telemt to existing Remnawave setup
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root"

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}  Telemt — EU Exit Node Setup${NC}"
echo -e "${CYAN}  (adds Telemt to existing Remnawave)${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# --- Configuration ---
read -rp "RU server IP (for API whitelist): " RU_IP
[[ -z "${RU_IP:-}" ]] && error "RU IP is required"

read -rp "RU domain (for proxy links, e.g. ru.example.com): " RU_DOMAIN
[[ -z "${RU_DOMAIN:-}" ]] && error "RU domain is required"

read -rp "Masking/TLS domain [kue.dataconflux.org]: " TLS_DOMAIN
TLS_DOMAIN="${TLS_DOMAIN:-kue.dataconflux.org}"

echo ""
info "Configuration:"
info "  RU IP:      $RU_IP"
info "  RU domain:  $RU_DOMAIN"
info "  TLS domain: $TLS_DOMAIN"
echo ""
read -rp "Continue? [Y/n]: " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && error "Aborted"

# --- Step 1: Install Telemt ---
if command -v telemt &>/dev/null; then
    info "Telemt already installed: $(telemt --version 2>/dev/null || echo 'unknown')"
else
    info "Installing Telemt..."
    LIBC_SUFFIX="gnu"
    if ldd --version 2>&1 | grep -iq musl; then
        LIBC_SUFFIX="musl"
    fi
    wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-$(uname -m)-linux-${LIBC_SUFFIX}.tar.gz" | tar -xz
    mv telemt /bin
    chmod +x /bin/telemt
    info "Telemt installed: $(telemt --version 2>/dev/null || echo 'unknown')"
fi

# --- Step 2: Create telemt user ---
if ! id telemt &>/dev/null; then
    useradd -d /opt/telemt -m -r -U telemt
    info "Created telemt user"
fi

# --- Step 3: Generate secrets ---
info "Generating proxy secrets..."
mkdir -p /etc/telemt/tlsfront

S1=$(openssl rand -hex 16)
S2=$(openssl rand -hex 16)
S3=$(openssl rand -hex 16)
S4=$(openssl rand -hex 16)
S5=$(openssl rand -hex 16)

info "  s1 = ${S1}"
info "  s2 = ${S2}"
info "  s3 = ${S3}"
info "  s4 = ${S4}"
info "  s5 = ${S5}"

# --- Step 4: Write Telemt config ---
info "Writing Telemt config..."

cat > /etc/telemt/telemt.toml <<TELEMTEOF
[general]
use_middle_proxy = true
# ad_tag = "REPLACE_WITH_YOUR_AD_TAG_FROM_MTProxyBot"
log_level = "normal"
fast_mode = true
rst_on_close = "errors"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${RU_DOMAIN}"
public_port = 443

[server]
port = 8443
listen_addr_ipv4 = "127.0.0.1"
proxy_protocol = true
max_connections = 10000
metrics_port = 9090
metrics_listen = "0.0.0.0:9090"
metrics_whitelist = ["127.0.0.1/32", "::1/128", "${RU_IP}/32"]

[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.1/32", "::1/128", "${RU_IP}/32"]

[[server.listeners]]
ip = "127.0.0.1"

[censorship]
tls_domain = "${TLS_DOMAIN}"
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
mask_shape_hardening_aggressive_mode = false
mask_shape_bucket_floor_bytes = 512
mask_shape_bucket_cap_bytes = 4096

mask_timing_normalization_enabled = true
mask_timing_normalization_floor_ms = 50
mask_timing_normalization_ceiling_ms = 500

unknown_sni_action = "mask"

[access.users]
s1 = "${S1}"
s2 = "${S2}"
s3 = "${S3}"
s4 = "${S4}"
s5 = "${S5}"

# [access.user_ad_tags]
# s1 = "AD_TAG_FROM_MTProxyBot_1"
TELEMTEOF

chown -R telemt:telemt /etc/telemt

# --- Step 5: Systemd service ---
info "Installing Telemt service..."

cat > /etc/systemd/system/telemt.service <<'SVCEOF'
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
SVCEOF

systemctl daemon-reload
systemctl enable telemt
systemctl start telemt
sleep 2

if systemctl is-active --quiet telemt; then
    info "Telemt started on 127.0.0.1:8443 (proxy_protocol=true)"
else
    error "Telemt failed to start! Check: journalctl -u telemt -n 50"
fi

# --- Step 6: Firewall ---
info "Configuring firewall for Telemt API..."
if command -v ufw &>/dev/null; then
    ufw allow from ${RU_IP} to any port 9091 proto tcp 2>/dev/null || true
    ufw allow from ${RU_IP} to any port 9090 proto tcp 2>/dev/null || true
    info "API ports 9090/9091 opened for RU IP ${RU_IP}"
else
    warn "ufw not found. Manually open ports 9090/9091 for ${RU_IP}"
fi

# --- Summary ---
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  EU EXIT NODE — TELEMT INSTALLED${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  Telemt:   127.0.0.1:8443 (proxy_protocol=true)"
echo "  API:      0.0.0.0:9091 (whitelist: 127.0.0.1, ${RU_IP})"
echo "  Metrics:  0.0.0.0:9090 (whitelist: 127.0.0.1, ${RU_IP})"
echo ""
echo -e "${YELLOW}  IMPORTANT: Configure Remnawave routing!${NC}"
echo ""
echo "  In your Remnawave panel, make these changes:"
echo ""
echo "  1. Add a new OUTBOUND:"
echo "     Tag:          tunnel-to-telemt"
echo "     Protocol:     freedom"
echo "     Destination:  127.0.0.1:8443"
echo ""
echo "  2. Add a ROUTING RULE:"
echo "     Inbound tag:  XHTTP-Reality-AMS"
echo "     Outbound tag: tunnel-to-telemt"
echo "     (place ABOVE the bittorrent block rule)"
echo ""
echo "  3. After saving, restart the Remnawave node"
echo ""
echo "  Proxy links (from Telemt API):"
curl -s http://127.0.0.1:9091/v1/users 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for user in data.get('data', []):
        name = user.get('username', '?')
        links = user.get('links', {}).get('tls', [])
        if links:
            print(f'  [{name}] {links[0]}')
except:
    print('  (run: curl -s http://127.0.0.1:9091/v1/users | jq)')
" 2>/dev/null || echo "  (run: curl -s http://127.0.0.1:9091/v1/users | jq)"
echo ""
