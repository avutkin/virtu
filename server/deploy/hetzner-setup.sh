#!/usr/bin/env bash
#
# One-time provisioning for a fresh Ubuntu 24.04 Hetzner Cloud server.
# Sets up: PostgreSQL (localhost only), a Python venv + the API, a systemd
# service bound to loopback, Caddy for automatic HTTPS, and a firewall.
#
# PREREQUISITES (do these first — see README.md):
#   1. Point a DNS A record (e.g. api.example.com) at this server's IP.
#   2. Clone the repo to /opt/wythin:
#        sudo git clone https://github.com/avutkin/wythin.git /opt/wythin
#   3. cp /opt/wythin/server/deploy/env.example /opt/wythin/server/deploy/.env
#      and fill it in (DB_PASSWORD, DATABASE_URL, OPENAI_API_KEY).
#
# USAGE (as root):
#   sudo bash /opt/wythin/server/deploy/hetzner-setup.sh api.example.com
#
set -euo pipefail

DOMAIN="${1:?usage: hetzner-setup.sh <api-domain>   e.g. api.example.com}"
APP_DIR=/opt/wythin
APP_USER=wythin
DB_NAME=wythin
DB_USER=wythin
ENV_FILE="$APP_DIR/server/deploy/.env"

[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE — copy env.example and fill it in first."; exit 1; }
DB_PASS="$(grep -E '^DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || true)"
[ -n "$DB_PASS" ] || { echo "DB_PASSWORD not set in $ENV_FILE"; exit 1; }
chmod 600 "$ENV_FILE"

echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip postgresql ufw curl git gettext-base \
                   debian-keyring debian-archive-keyring apt-transport-https unattended-upgrades

echo "==> Installing Caddy (auto-HTTPS)"
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y
  apt-get install -y caddy
fi

echo "==> Creating app user"
id "$APP_USER" >/dev/null 2>&1 || \
  useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"

echo "==> Configuring PostgreSQL (localhost only)"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
# Postgres on Ubuntu listens on localhost by default; the firewall below also
# blocks 5432 from the internet as defense in depth.

echo "==> Python venv + dependencies (API only — no desktop/BLE deps)"
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip -q
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/server/requirements.txt" -q
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

echo "==> Running schema migration"
sudo -u "$APP_USER" bash -c "cd $APP_DIR && set -a && . server/deploy/.env && set +a && .venv/bin/python server/deploy/migrate.py"

echo "==> Installing systemd service"
install -m 644 "$APP_DIR/server/deploy/wythin-api.service" /etc/systemd/system/wythin-api.service
systemctl daemon-reload
systemctl enable --now wythin-api

echo "==> Configuring Caddy for https://$DOMAIN"
API_DOMAIN="$DOMAIN" envsubst '${API_DOMAIN}' < "$APP_DIR/server/deploy/Caddyfile" > /etc/caddy/Caddyfile
systemctl reload caddy || systemctl restart caddy

echo "==> Firewall (SSH + HTTP/HTTPS only; DB and app port stay internal)"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> Enabling automatic security updates"
systemctl enable --now unattended-upgrades || true

echo
echo "Done. Verify:  curl https://$DOMAIN/health   ->  {\"status\":\"ok\"}"
echo "Point the iOS app's serverURL at: https://$DOMAIN"
