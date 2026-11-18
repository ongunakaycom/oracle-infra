#!/usr/bin/env bash
set -euo pipefail

BUNDLE_TAR="${1:?Hata: DR bundle .tar.gz dosya yolunu belirtin.}"
DUCKDNS_TOKEN="${2:-}"

[ -f "${BUNDLE_TAR}" ] || { echo "Hata: ${BUNDLE_TAR} bulunamadı."; exit 1; }
[ -f "${BUNDLE_TAR}.sha256" ] && sha256sum -c "${BUNDLE_TAR}.sha256"

if ! command -v caddy &>/dev/null; then
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl sqlite3
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq && apt-get install -y -qq caddy
  elif command -v dnf &>/dev/null; then
    dnf install -y -q 'dnf-command(copr)' sqlite curl
    dnf copr enable -y @caddy/caddy
    dnf install -y -q caddy
  fi
fi

EXTRACT_DIR="/tmp/dr-restore-$$"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${BUNDLE_TAR}" -C "${EXTRACT_DIR}"
BUNDLE_ROOT="$(find "${EXTRACT_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

mkdir -p /opt/secops /var/www/secops /etc/secops /etc/caddy
systemctl stop secops-api 2>/dev/null || true

install -m 755 "${BUNDLE_ROOT}/app/secops-api" /opt/secops/secops-api
install -m 640 "${BUNDLE_ROOT}/app/secops.db" /opt/secops/secops.db
rm -rf /var/www/secops/*
cp -rp "${BUNDLE_ROOT}/web/." /var/www/secops/

if [ -f "${BUNDLE_ROOT}/config/secops.env" ]; then
  install -o root -g root -m 600 "${BUNDLE_ROOT}/config/secops.env" /etc/secops/secops.env
fi

if [ -f "${BUNDLE_ROOT}/config/Caddyfile" ]; then
  install -o root -g root -m 644 "${BUNDLE_ROOT}/config/Caddyfile" /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile
fi

if [ -f "${BUNDLE_ROOT}/config/secops-api.service" ]; then
  install -o root -g root -m 644 "${BUNDLE_ROOT}/config/secops-api.service" /etc/systemd/system/secops-api.service
fi

rm -rf "${EXTRACT_DIR}"

systemctl daemon-reload
systemctl enable --now secops-api
systemctl enable --now caddy
systemctl restart caddy

if [ -n "${DUCKDNS_TOKEN}" ]; then
  curl -sS "https://www.duckdns.org/update?domains=oracle-infra&token=${DUCKDNS_TOKEN}&ip=" && echo ""
fi

sleep 2
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api/health)
if [ "${HTTP_STATUS}" = "200" ]; then
  echo "[+] BAŞARILI: secops-api ayakta (HTTP 200)."
else
  echo "[!] HATA: /api/health beklenmeyen durum kodu döndü: ${HTTP_STATUS}"
  systemctl status secops-api --no-pager
  exit 1
fi
