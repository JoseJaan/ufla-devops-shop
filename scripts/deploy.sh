#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_USER=ufla-shop
APP_DIR=/opt/ufla-shop
ENV_FILE=/etc/ufla-shop.env
BACKUP_DIR=/var/backups/ufla-shop
TLS_DIR=/etc/ssl/ufla-shop
HEALTH_URL=http://localhost:8000/ready

cd /

log() { echo "==> $*"; }
pg() { sudo -u postgres psql -v ON_ERROR_STOP=1 -tAq "$@"; }

log "instalando pacotes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-venv postgresql redis-server nginx openssl rsync curl >/dev/null
systemctl enable --now -q postgresql redis-server

log "usuario $APP_USER"
id "$APP_USER" &>/dev/null || useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"

log "arquivo de ambiente $ENV_FILE"
install -m 644 "$REPO_DIR/systemd/ufla-shop.env.example" /etc/ufla-shop.env.example
if [[ ! -f $ENV_FILE ]]; then
    senha="$(openssl rand -hex 16)"
    sed "s/TROQUE_ME/$senha/g" /etc/ufla-shop.env.example > "$ENV_FILE"
    log "  $ENV_FILE criado com senha nova"
else
    log "  $ENV_FILE ja existe, mantido"
fi
chown root:"$APP_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"
DB_PASSWORD="$(set -a; . "$ENV_FILE"; echo "$DB_PASSWORD")"

log "banco loja"
if [[ -z "$(pg -c "SELECT 1 FROM pg_roles WHERE rolname = 'loja'")" ]]; then
    pg -c "CREATE ROLE loja LOGIN PASSWORD '$DB_PASSWORD'"
else
    pg -c "ALTER ROLE loja LOGIN PASSWORD '$DB_PASSWORD'"
fi
if [[ -z "$(pg -c "SELECT 1 FROM pg_database WHERE datname = 'loja'")" ]]; then
    pg -c "CREATE DATABASE loja OWNER loja"
fi

log "codigo em $APP_DIR"
install -d -m 755 "$APP_DIR" "$APP_DIR/scripts"
rsync -a --delete --exclude __pycache__ \
    "$REPO_DIR/app" "$REPO_DIR/static" "$REPO_DIR/requirements.txt" "$APP_DIR/"
install -m 755 "$REPO_DIR/scripts/backup.sh" "$APP_DIR/scripts/backup.sh"
[[ -x $APP_DIR/.venv/bin/python ]] || python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install -q --disable-pip-version-check -r "$APP_DIR/requirements.txt"

log "diretorio de backup $BACKUP_DIR"
install -d -o "$APP_USER" -g "$APP_USER" -m 750 "$BACKUP_DIR"

log "units do systemd"
install -m 644 "$REPO_DIR"/systemd/*.service "$REPO_DIR"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q ufla-shop.service
systemctl enable --now -q ufla-shop-backup.timer
systemctl restart ufla-shop.service

log "certificado TLS"
install -d -m 755 "$TLS_DIR"
if [[ ! -f $TLS_DIR/loja.key ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=localhost" \
        -keyout "$TLS_DIR/loja.key" -out "$TLS_DIR/loja.pem" 2>/dev/null
    chmod 600 "$TLS_DIR/loja.key"
    log "  certificado gerado"
else
    log "  certificado ja existe, mantido"
fi

log "nginx"
install -m 644 "$REPO_DIR/nginx/loja.conf" /etc/nginx/sites-available/loja.conf
ln -sf /etc/nginx/sites-available/loja.conf /etc/nginx/sites-enabled/loja.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t -q
systemctl enable -q nginx
systemctl reload-or-restart nginx

log "healthcheck $HEALTH_URL"
for i in $(seq 1 10); do
    if curl -fsS -o /dev/null "$HEALTH_URL"; then
        log "deploy ok (tentativa $i)"
        exit 0
    fi
    sleep 1
done
echo "ERRO: $HEALTH_URL nao respondeu 200 em 10 tentativas" >&2
journalctl -u ufla-shop -n 20 --no-pager >&2
exit 1
