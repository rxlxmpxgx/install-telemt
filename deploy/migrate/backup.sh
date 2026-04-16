#!/bin/bash
set -euo pipefail

# =============================================
# Backup script for RU entry node migration
# =============================================

PROJECT_DIR="/opt/telemt-project"
BACKUP_DIR="${PROJECT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "${BACKUP_DIR}"

BACKUP_FILE="${BACKUP_DIR}/telemt-ru-backup-${TIMESTAMP}.tar.gz"

info() { echo "[INFO] $*"; }

info "Backing up Telemt RU node..."

tar czf "${BACKUP_FILE}" \
    -C / \
    "${PROJECT_DIR}/bot.ini" \
    "${PROJECT_DIR}/deploy-config.env" \
    "${PROJECT_DIR}/bot" \
    /usr/local/etc/xray/config.json \
    /etc/systemd/system/telemt-bot.service \
    2>/dev/null || true

FILESIZE=$(du -h "${BACKUP_FILE}" | cut -f1)

info "Backup saved: ${BACKUP_FILE} (${FILESIZE})"
echo ""
echo "To migrate to a new RU server:"
echo "  1. scp ${BACKUP_FILE} root@NEW_RU_SERVER:/tmp/"
echo "  2. On new server: mkdir -p /opt/telemt-project"
echo "  3. On new server: tar xzf /tmp/telemt-ru-backup-*.tar.gz -C /"
echo "  4. On new server: git clone YOUR_REPO && cd repo && sudo bash deploy/ru/install.sh"
echo "     (install.sh will detect existing config and use it)"
