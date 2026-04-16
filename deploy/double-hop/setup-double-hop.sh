#!/bin/bash
set -euo pipefail

# =============================================
# Double-Hop Deployment Script
# RU (entry) + EU (exit) via VLESS+Reality
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================
# STEP 0: Which server?
# =============================================
echo ""
echo "=== Telemt Double-Hop Setup ==="
echo ""
echo "Which server are you setting up?"
echo "  1) EU (exit node — Telemt + Xray + Angie)"
echo "  2) RU (entry node — Xray only)"
echo ""
read -rp "Choice [1/2]: " SERVER_ROLE

if [[ "$SERVER_ROLE" != "1" && "$SERVER_ROLE" != "2" ]]; then
    error "Invalid choice"
fi

# =============================================
# STEP 1: Install Xray (both servers)
# =============================================
install_xray() {
    if command -v xray &>/dev/null; then
        info "Xray already installed: $(xray version | head -1)"
    else
        info "Installing Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        info "Xray installed: $(xray version | head -1)"
    fi
}

# =============================================
# STEP 2: Generate keys (run once, share between servers)
# =============================================
generate_keys() {
    info "Generating VLESS+Reality keys..."
    XRAY_UUID=$(xray uuid)
    KEYPAIR=$(xray x25519)
    EU_PRIVATE_KEY=$(echo "$KEYPAIR" | grep "Private key" | awk '{print $3}')
    EU_PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Public key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    info "UUID:         $XRAY_UUID"
    info "Private Key:  $EU_PRIVATE_KEY"
    info "Public Key:   $EU_PUBLIC_KEY"
    info "Short ID:     $SHORT_ID"

    echo ""
    warn "SAVE THESE VALUES! You need them for BOTH servers."
    echo ""
    read -rp "Press Enter to continue..."
}

# =============================================
# EU SERVER SETUP
# =============================================
setup_eu() {
    info "=== Setting up EU server ==="

    generate_keys

    read -rp "EU server public IP: " EU_IP

    # --- Xray config ---
    info "Writing Xray config..."
    cat > /usr/local/etc/xray/config.json << XRAYEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-in",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${XRAY_UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "127.0.0.1:4124",
          "xver": 2,
          "shortIds": ["${SHORT_ID}"],
          "privateKey": "${EU_PRIVATE_KEY}",
          "serverNames": ["tg.breachvpn.org"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "tunnel-to-telemt",
      "protocol": "freedom",
      "settings": { "destination": "127.0.0.1:8443" }
    },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["vless-in"], "outboundTag": "tunnel-to-telemt" }
    ]
  }
}
XRAYEOF

    systemctl restart xray
    systemctl enable xray
    info "Xray started on :443 (VLESS+Reality → Telemt :8443)"

    # --- Angie: add :4124 server block for Reality dest ---
    info "Adding Angie :4124 server block (Reality scanner fallback)..."
    ANGIE_CONF="/opt/angie/angie.conf"
    if [[ -f "$ANGIE_CONF" ]]; then
        if ! grep -q "4124" "$ANGIE_CONF"; then
            sed -i '/listen 127.0.0.1:4123 ssl/a\\n    # Reality scanner fallback (no PROXY protocol)\n    listen 127.0.0.1:4124 ssl http2;' "$ANGIE_CONF"
            info "Added :4124 to Angie config. Restart Angie manually after review."
        fi
    else
        warn "Angie config not found at $ANGIE_CONF — add :4124 server block manually"
    fi

    # --- Telemt config ---
    info "Telemt needs these changes on EU server:"
    echo ""
    echo "  1. Port: 443 → 8443"
    echo "  2. Listen: 0.0.0.0 → 127.0.0.1"
    echo "  3. Add: proxy_protocol = true"
    echo "  4. Add: listen_addr_ipv4 = \"127.0.0.1\""
    echo "  5. public_host: → ru.breachvpn.org"
    echo ""
    warn "Apply Telemt config changes BEFORE restarting!"
    echo ""
    echo "Quick commands:"
    echo "  sed -i 's/^port = 443/port = 8443/' /etc/telemt/telemt.toml"
    echo "  sed -i 's/^\\[\\[server\\.listeners\\]\\]/[[server.listeners]]/' /etc/telemt/telemt.toml"
    echo "  sed -i 's/^ip = \"0\\.0\\.0\\.0\"/ip = \"127.0.0.1\"/' /etc/telemt/telemt.toml"
    echo "  sed -i '/^port = 8443/a proxy_protocol = true\\nlisten_addr_ipv4 = \"127.0.0.1\"' /etc/telemt/telemt.toml"
    echo "  sed -i 's/public_host = .*/public_host = \"ru.breachvpn.org\"/' /etc/telemt/telemt.toml"
    echo "  sed -i 's/public_port = .*/public_port = 443/' /etc/telemt/telemt.toml"
    echo ""
    echo "Then: systemctl restart telemt"

    # --- Firewall ---
    ufw allow 443/tcp 2>/dev/null || true
    info "Firewall: 443/tcp open"

    # --- Summary ---
    echo ""
    info "=== EU Setup Complete ==="
    info "Xray: :443 → :8443 (Telemt)"
    info "Reality dest: :4124 (Angie scanner fallback)"
    echo ""
    warn "IMPORTANT: Write down these values for RU setup:"
    echo "  UUID:        $XRAY_UUID"
    echo "  Public Key:  $EU_PUBLIC_KEY"
    echo "  Short ID:    $SHORT_ID"
    echo "  EU IP:       $EU_IP"
}

# =============================================
# RU SERVER SETUP
# =============================================
setup_ru() {
    info "=== Setting up RU server ==="

    read -rp "EU server public IP: " EU_IP
    read -rp "VLESS UUID (from EU setup): " XRAY_UUID
    read -rp "EU Public Key (from EU setup): " EU_PUBLIC_KEY
    read -rp "Short ID (from EU setup): " SHORT_ID

    # --- Xray config ---
    info "Writing Xray config..."
    cat > /usr/local/etc/xray/config.json << XRAYEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "public-in",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": 10444,
        "network": "tcp"
      }
    },
    {
      "tag": "tunnel-in",
      "port": 10444,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": 8443,
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "local-injector",
      "protocol": "freedom",
      "settings": { "proxyProtocol": 2 }
    },
    {
      "tag": "vless-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${EU_IP}",
            "port": 443,
            "users": [
              {
                "id": "${XRAY_UUID}",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "tg.breachvpn.org",
          "publicKey": "${EU_PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "fingerprint": "chrome"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["public-in"], "outboundTag": "local-injector" },
      { "type": "field", "inboundTag": ["tunnel-in"], "outboundTag": "vless-out" }
    ]
  }
}
XRAYEOF

    systemctl restart xray
    systemctl enable xray
    info "Xray started on :443 → VLESS+Reality → ${EU_IP}:443"

    # --- Firewall ---
    ufw allow 443/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    info "Firewall: 443/tcp, 80/tcp open"

    # --- Kernel tuning ---
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    sysctl -w net.core.somaxconn=65535 2>/dev/null || true

    # --- Summary ---
    echo ""
    info "=== RU Setup Complete ==="
    info "Xray :443 → VLESS+Reality → ${EU_IP}:443"
    info "PROXYv2 header injected — Telemt sees real client IPs"
    echo ""
    echo "DNS: Create A record ru.breachvpn.org → $(curl -s4 ifconfig.me)"
    echo "     Cloudflare: DNS only (grey cloud!)"
}

# =============================================
# MAIN
# =============================================
install_xray

if [[ "$SERVER_ROLE" == "1" ]]; then
    setup_eu
elif [[ "$SERVER_ROLE" == "2" ]]; then
    setup_ru
fi
