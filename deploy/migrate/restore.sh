#!/bin/bash
set -euo pipefail

# =============================================
# Restore script for RU entry node migration
# Usage: restore.sh <backup.tar.gz>
# =============================================

[[ -z "${1:-}" ]] && echo "Usage: sudo bash restore.sh <backup.tar.gz>" && exit 1
BACKUP_FILE="$1"

[[ ! -f "${BACKUP_FILE}" ]] && echo "File not found: ${BACKUP_FILE}" && exit 1
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

PROJECT_DIR="/opt/telemt-project"

echo "[INFO] Restoring from backup: ${BACKUP_FILE}"
mkdir -p "${PROJECT_DIR}"

tar xzf "${BACKUP_FILE}" -C /

echo "[INFO] Backup restored to ${PROJECT_DIR}"
echo ""
echo "Next: run install.sh (it will detect the restored config)"
echo "  git clone YOUR_REPO && cd repo && sudo bash deploy/ru/install.sh"
