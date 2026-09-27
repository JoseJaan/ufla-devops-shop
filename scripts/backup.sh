#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR=/var/backups/ufla-shop
MANTER=7

if [[ -z "${DATABASE_URL:-}" && -r /etc/ufla-shop.env ]]; then
    set -a
    . /etc/ufla-shop.env
    set +a
fi
: "${DATABASE_URL:?DATABASE_URL nao definida}"

umask 077
destino="$BACKUP_DIR/loja-$(date +%F-%H%M).sql.gz"
tmp="$destino.tmp"
trap 'rm -f "$tmp"' EXIT

pg_dump "$DATABASE_URL" | gzip > "$tmp"
mv "$tmp" "$destino"

ls -1t "$BACKUP_DIR"/loja-*.sql.gz | tail -n +$((MANTER + 1)) | xargs -r rm -f --

tamanho="$(du -h "$destino" | cut -f1)"
logger -t backup "gerado $destino ($tamanho)"
echo "gerado $destino ($tamanho)"
