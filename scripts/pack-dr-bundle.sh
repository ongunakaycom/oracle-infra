#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/tmp/dr-bundles}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BUNDLE_NAME="secops-dr-bundle-${TIMESTAMP}"
STAGE_DIR="/tmp/${BUNDLE_NAME}"

APP_DIR="/opt/secops"
WEB_DIR="/var/www/secops"
ENV_FILE="/etc/secops/secops.env"
CADDY_FILE="/etc/caddy/Caddyfile"
SERVICE_FILE="/etc/systemd/system/secops-api.service"

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/app" "${STAGE_DIR}/web" "${STAGE_DIR}/config" "${OUT_DIR}"

if command -v sqlite3 &>/dev/null && [ -f "${APP_DIR}/secops.db" ]; then
  sqlite3 "${APP_DIR}/secops.db" ".backup '${STAGE_DIR}/app/secops.db'"
else
  cp -p "${APP_DIR}/secops.db" "${STAGE_DIR}/app/secops.db"
fi

cp -p "${APP_DIR}/secops-api" "${STAGE_DIR}/app/secops-api"
cp -rp "${WEB_DIR}/." "${STAGE_DIR}/web/"

[ -f "${CADDY_FILE}" ] && cp -p "${CADDY_FILE}" "${STAGE_DIR}/config/Caddyfile"
[ -f "${SERVICE_FILE}" ] && cp -p "${SERVICE_FILE}" "${STAGE_DIR}/config/secops-api.service"
if [ -f "${ENV_FILE}" ]; then
  install -m 600 "${ENV_FILE}" "${STAGE_DIR}/config/secops.env"
fi

cat << MANIFEST > "${STAGE_DIR}/manifest.json"
{
  "bundle": "${BUNDLE_NAME}",
  "created_at_utc": "${TIMESTAMP}",
  "source_host": "$(hostname)",
  "arch": "$(uname -m)"
}
MANIFEST

ARCHIVE_PATH="${OUT_DIR}/${BUNDLE_NAME}.tar.gz"
tar -czf "${ARCHIVE_PATH}" -C /tmp "${BUNDLE_NAME}"
sha256sum "${ARCHIVE_PATH}" > "${ARCHIVE_PATH}.sha256"
rm -rf "${STAGE_DIR}"

echo "[+] DR Paketi Hazır: ${ARCHIVE_PATH}"
echo "[+] Checksum: ${ARCHIVE_PATH}.sha256"
