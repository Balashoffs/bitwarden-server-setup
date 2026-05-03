#!/usr/bin/env bash
# Deploy/redeploy Bitwarden + nginx vhost + TLS cert.
# Idempotent: re-running is safe.
# Run: sudo ./scripts/install.sh

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root
load_env

require_cmd docker
require_cmd nginx
require_cmd certbot
require_cmd ss
require_cmd sed

# BW_DOMAIN is the bare hostname (per spec section 11). Sanity-check no scheme leaked in.
case "$BW_DOMAIN" in
  http://*|https://*) die "BW_DOMAIN must be bare hostname, not URL: '$BW_DOMAIN' (see spec section 11)" ;;
esac
HOSTNAME="$BW_DOMAIN"

[ -n "${BW_INSTALLATION_ID:-}" ] || die "BW_INSTALLATION_ID empty in .env"
[ -n "${BW_INSTALLATION_KEY:-}" ] || die "BW_INSTALLATION_KEY empty in .env"
[ -n "${ADMIN_EMAIL:-}" ] || die "ADMIN_EMAIL empty in .env"
[ -n "${BW_BIND_PORT:-}" ] || die "BW_BIND_PORT empty in .env"

# 1. Confirm bind port is free on 127.0.0.1 (excluding the existing bitwarden container itself).
if ss -tlnp "( sport = :$BW_BIND_PORT )" 2>/dev/null | grep -q '127.0.0.1'; then
  if ! docker ps --format '{{.Names}}' | grep -qx bitwarden; then
    die "port $BW_BIND_PORT on 127.0.0.1 is taken by another process; pick a different BW_BIND_PORT in .env"
  fi
  log "port $BW_BIND_PORT held by existing bitwarden container — ok"
else
  log "port $BW_BIND_PORT on 127.0.0.1 is free"
fi

# 2. Pull image and start container
log "Pulling image"
docker compose pull
log "Starting container"
docker compose up -d

# 3. Wait for healthcheck
log "Waiting for container to become healthy (up to 120 s)"
for i in $(seq 1 60); do
  status="$(docker inspect --format '{{.State.Health.Status}}' bitwarden 2>/dev/null || echo none)"
  case "$status" in
    healthy) log "container healthy"; break ;;
    starting|none) sleep 2 ;;
    unhealthy) die "container reported unhealthy; see: docker compose logs bitwarden" ;;
    *) sleep 2 ;;
  esac
  [ "$i" = 60 ] && die "container did not become healthy in 120 s"
done

# 4. Render nginx vhost from template
VHOST_SRC="$REPO_ROOT/nginx/${HOSTNAME}.conf.template"
[ -f "$VHOST_SRC" ] || die "vhost template not found: $VHOST_SRC"
VHOST_DST="/etc/nginx/sites-available/${HOSTNAME}.conf"
log "Rendering vhost to $VHOST_DST"
sed -e "s/__DOMAIN__/${HOSTNAME}/g" \
    -e "s/__BIND_PORT__/${BW_BIND_PORT}/g" \
    "$VHOST_SRC" > "$VHOST_DST"

# Symlink into sites-enabled if not already
if [ ! -L "/etc/nginx/sites-enabled/${HOSTNAME}.conf" ]; then
  ln -s "$VHOST_DST" "/etc/nginx/sites-enabled/${HOSTNAME}.conf"
  log "Enabled vhost"
fi

# 5. Test and reload nginx
log "Testing nginx config"
nginx -t
systemctl reload nginx
log "nginx reloaded"

# 6. Smoke-check HTTP (cert may not exist yet)
log "Smoke-checking HTTP /alive (pre-TLS)"
if curl -fsS "http://${HOSTNAME}/alive" -o /dev/null; then
  log "HTTP /alive ok"
else
  log "HTTP /alive failed; will rely on certbot to validate connectivity"
fi

# 7. Issue/renew certificate
log "Running certbot --nginx -d $HOSTNAME"
certbot --nginx \
  -d "$HOSTNAME" \
  --non-interactive --agree-tos --redirect \
  -m "$ADMIN_EMAIL" || die "certbot failed; see /var/log/letsencrypt/letsencrypt.log"

# 8. Smoke-check HTTPS
log "Smoke-checking HTTPS /alive"
curl -fsS "https://${HOSTNAME}/alive" -o /dev/null \
  || die "HTTPS /alive failed after certbot"

# 9. Install systemd backup units
log "Installing systemd backup timer"
SYSTEMD_DIR=/etc/systemd/system
sed "s|__BACKUP_SCRIPT__|$REPO_ROOT/scripts/backup.sh|g" \
    "$REPO_ROOT/systemd/bitwarden-backup.service" \
    > "$SYSTEMD_DIR/bitwarden-backup.service"
cp "$REPO_ROOT/systemd/bitwarden-backup.timer" \
   "$SYSTEMD_DIR/bitwarden-backup.timer"
systemctl daemon-reload
systemctl enable --now bitwarden-backup.timer

# 10. Done
cat >&2 <<EOF

==== install.sh complete ====

Open: https://${HOSTNAME}
- Register the single owner account.
- WRITE THE MASTER PASSWORD DOWN ON PAPER.
- Run: sudo ./scripts/lockdown.sh

Backup timer: $(systemctl list-timers bitwarden-backup.timer --no-pager | head -2 | tail -1)
EOF
