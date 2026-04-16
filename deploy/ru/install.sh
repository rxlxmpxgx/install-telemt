#!/bin/bash
set -euo pipefail

# =============================================
# Telemt Proxy — RU Entry Node Installer
# Usage: sudo bash install.sh
# Or:    curl -fsSL URL | sudo bash
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

PROJECT_DIR="/opt/telemt-project"
BOT_DIR="${PROJECT_DIR}/bot"
VENV_DIR="${PROJECT_DIR}/bot-venv"
CONFIG_FILE="${PROJECT_DIR}/bot.ini"

[[ $EUID -ne 0 ]] && error "Run as root"

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}  Telemt Proxy — RU Entry Node Setup${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# --- Detect if restoring from backup ---
RESTORE_ENV="${PROJECT_DIR}/deploy-config.env"
if [[ -f "${RESTORE_ENV}" ]]; then
    info "Found existing config at ${RESTORE_ENV}"
    source "${RESTORE_ENV}"
    info "Using saved configuration (edit ${RESTORE_ENV} to change)"
    echo ""
else
    # --- Interactive Configuration ---
    info "Configuration"
    echo ""

    read -rp "EU server IP [154.83.149.180]: " EU_IP
    EU_IP="${EU_IP:-154.83.149.180}"

    read -rp "VLESS UUID [e9ca9cc3-367d-4095-b4c0-b586829d0f30]: " VLESS_UUID
    VLESS_UUID="${VLESS_UUID:-e9ca9cc3-367d-4095-b4c0-b586829d0f30}"

    read -rp "VLESS Public Key [v1MY9CR9HkAFSqv8kmDHnad4nRGPIo4j88p1sDC22H8]: " VLESS_PUBKEY
    VLESS_PUBKEY="${VLESS_PUBKEY:-v1MY9CR9HkAFSqv8kmDHnad4nRGPIo4j88p1sDC22H8}"

    read -rp "Short ID [6ee901fbfd1c3518]: " SHORT_ID
    SHORT_ID="${SHORT_ID:-6ee901fbfd1c3518}"

    read -rp "Reality SNI domain [kue.dataconflux.org]: " REALITY_SNI
    REALITY_SNI="${REALITY_SNI:-kue.dataconflux.org}"

    read -rp "XHTTP path [/v1/837cc5]: " XHTTP_PATH
    XHTTP_PATH="${XHTTP_PATH:-/v1/837cc5}"

    read -rp "RU domain (for proxy links, e.g. ru.example.com): " RU_DOMAIN
    [[ -z "${RU_DOMAIN:-}" ]] && error "RU domain is required"

    TELEMT_API_URL="http://${EU_IP}:9091"
    TELEMT_METRICS_URL="http://${EU_IP}:9090"

    read -rp "Telegram Bot Token (or 'later' to skip): " BOT_TOKEN
    if [[ "${BOT_TOKEN:-}" == "later" || -z "${BOT_TOKEN:-}" ]]; then
        BOT_TOKEN="REPLACE_WITH_BOT_TOKEN"
        warn "Bot token not set. Edit ${CONFIG_FILE} later."
    fi

    read -rp "Your Telegram chat_id (0 if unknown, /start in bot to find): " ADMIN_CHAT_ID
    ADMIN_CHAT_ID="${ADMIN_CHAT_ID:-0}"

    echo ""
    info "Configuration summary:"
    info "  EU IP:       $EU_IP"
    info "  VLESS UUID:  $VLESS_UUID"
    info "  SNI:         $REALITY_SNI"
    info "  XHTTP path:  $XHTTP_PATH"
    info "  RU domain:   $RU_DOMAIN"
    echo ""
    read -rp "Continue? [Y/n]: " CONFIRM
    [[ "${CONFIRM,,}" == "n" ]] && error "Aborted"
fi

# --- Step 1: System packages ---
info "Updating system..."
apt update && apt upgrade -y
apt install -y curl jq python3 python3-pip python3-venv

# --- Step 2: Install Xray ---
if command -v xray &>/dev/null; then
    info "Xray already installed: $(xray version 2>/dev/null | head -1)"
else
    info "Installing Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    info "Xray installed: $(xray version 2>/dev/null | head -1)"
fi

# --- Step 3: Write Xray config ---
info "Writing Xray config..."

cat > /usr/local/etc/xray/config.json <<XRAYEOF
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
      "settings": {
        "proxyProtocol": 2
      }
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
                "id": "${VLESS_UUID}",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "${XHTTP_PATH}"
        },
        "realitySettings": {
          "serverName": "${REALITY_SNI}",
          "publicKey": "${VLESS_PUBKEY}",
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
sleep 2
if systemctl is-active --quiet xray; then
    info "Xray started on :443 → VLESS+Reality → ${EU_IP}:443"
else
    error "Xray failed to start! Check: journalctl -u xray -n 50"
fi

# --- Step 4: Project directory & config ---
info "Setting up project directory..."
mkdir -p "${PROJECT_DIR}"

cat > "${PROJECT_DIR}/deploy-config.env" <<ENVEOF
EU_IP=${EU_IP}
VLESS_UUID=${VLESS_UUID}
VLESS_PUBKEY=${VLESS_PUBKEY}
SHORT_ID=${SHORT_ID}
REALITY_SNI=${REALITY_SNI}
XHTTP_PATH=${XHTTP_PATH}
RU_DOMAIN=${RU_DOMAIN}
TELEMT_API_URL=${TELEMT_API_URL:-http://${EU_IP}:9091}
TELEMT_METRICS_URL=${TELEMT_METRICS_URL:-http://${EU_IP}:9090}
BOT_TOKEN=${BOT_TOKEN}
ADMIN_CHAT_ID=${ADMIN_CHAT_ID:-0}
INSTALLED_AT=$(date -Iseconds)
ENVEOF
chmod 600 "${PROJECT_DIR}/deploy-config.env"

# --- Step 5: Bot code ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -d "${REPO_ROOT}/bot/main.py" ]]; then
    info "Copying bot code from repo..."
    rm -rf "${BOT_DIR}"
    cp -r "${REPO_ROOT}/bot" "${BOT_DIR}"
elif [[ -n "${REPO_URL:-}" ]]; then
    info "Cloning bot code from ${REPO_URL}..."
    git clone --depth 1 "${REPO_URL}" /tmp/telemt-project-clone 2>/dev/null || true
    if [[ -d /tmp/telemt-project-clone/bot ]]; then
        rm -rf "${BOT_DIR}"
        cp -r /tmp/telemt-project-clone/bot "${BOT_DIR}"
        rm -rf /tmp/telemt-project-clone
    else
        error "Bot code not found in ${REPO_URL}"
    fi
elif [[ ! -d "${BOT_DIR}" ]]; then
    error "Bot code not found. Run from repo dir or set REPO_URL env var."
fi

# --- Step 6: Bot configuration ---
info "Writing bot configuration..."

cat > "${CONFIG_FILE}" <<INIEOF
[bot]
token = ${BOT_TOKEN}
admin_chat_id = ${ADMIN_CHAT_ID:-0}

[telemt]
api_url = ${TELEMT_API_URL:-http://${EU_IP}:9091}
metrics_url = ${TELEMT_METRICS_URL:-http://${EU_IP}:9090}
eu_server_ip = ${EU_IP}

[proxy]
ru_domain = ${RU_DOMAIN}

[monitor]
interval = 30
alert_enabled = true
INIEOF
chmod 600 "${CONFIG_FILE}"

# --- Step 7: Python venv ---
info "Setting up Python virtual environment..."
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip --quiet 2>/dev/null
"${VENV_DIR}/bin/pip" install -r "${BOT_DIR}/requirements.txt" --quiet 2>/dev/null

# --- Step 8: Bot systemd service ---
info "Installing bot service..."

cat > /etc/systemd/system/telemt-bot.service <<SVCEOF
[Unit]
Description=Telemt Proxy Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BOT_DIR}
ExecStart=${VENV_DIR}/bin/python main.py
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload

if [[ "${BOT_TOKEN}" != "REPLACE_WITH_BOT_TOKEN" ]]; then
    systemctl enable telemt-bot
    systemctl start telemt-bot
    sleep 2
    if systemctl is-active --quiet telemt-bot; then
        info "Bot started"
    else
        warn "Bot failed to start. Check: journalctl -u telemt-bot -n 50"
    fi
else
    warn "Bot not started (no token)."
    warn "  1. Get token from @BotFather"
    warn "  2. Edit ${CONFIG_FILE}"
    warn "  3. Run: systemctl enable --now telemt-bot"
fi

# --- Step 9: Kernel tuning ---
info "Applying kernel tuning..."
if ! grep -q "telemt optimization" /etc/sysctl.conf 2>/dev/null; then
    cat >> /etc/sysctl.conf <<'SYSCTL_EOF'

# telemt optimization
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
fs.file-max = 1048576
SYSCTL_EOF
    sysctl -p 2>/dev/null || true
fi

# --- Step 10: File limits ---
if [[ ! -f /etc/security/limits.d/telemt.conf ]]; then
    info "Setting file limits..."
    cat > /etc/security/limits.d/telemt.conf <<'LIMITS_EOF'
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
LIMITS_EOF
fi

# --- Step 11: Firewall ---
info "Configuring firewall..."
if command -v ufw &>/dev/null; then
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    info "Firewall: 22, 443 open"
else
    warn "ufw not found. Configure firewall manually."
fi

# --- Summary ---
RU_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "UNKNOWN")

echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  RU ENTRY NODE SETUP COMPLETE${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  RU IP:     ${RU_IP}"
echo "  RU Domain: ${RU_DOMAIN}"
echo "  EU Server: ${EU_IP}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. DNS: Create A record ${RU_DOMAIN} → ${RU_IP}"
echo "     (Cloudflare: DNS only, grey cloud!)"
echo ""
echo "  2. EU server: install Telemt"
echo "     Copy deploy/eu/install-telemt.sh to EU and run it"
echo ""
echo "  3. EU server: configure Remnawave routing"
echo "     Route VLESS inbound → 127.0.0.1:8443 (Telemt)"
echo ""
echo "  4. Bot: message your bot, use /start to get chat_id"
echo "     Update admin_chat_id in ${CONFIG_FILE}"
echo "     Then: systemctl restart telemt-bot"
echo ""
echo "  Config & data: ${PROJECT_DIR}/"
echo "  Migration:     ${PROJECT_DIR}/deploy-config.env"
echo ""
