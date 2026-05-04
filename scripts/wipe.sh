#!/usr/bin/env bash
# scripts/wipe.sh — stop all bitwarden containers, remove volumes, drop the
# systemd backup timer. With --wipe-all also removes nginx vhost, certbot
# cert, and the .env file.
#
# Usage:
#   sudo ./scripts/wipe.sh --yes-i-know
#   sudo ./scripts/wipe.sh --yes-i-know --wipe-all

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root

# Argument parsing — --yes-i-know is mandatory, --wipe-all is optional.
SAW_CONFIRM=false
WIPE_ALL=false
for arg in "$@"; do
  case "$arg" in
    --yes-i-know) SAW_CONFIRM=true ;;
    --wipe-all)   WIPE_ALL=true ;;
  esac
done
"$SAW_CONFIRM" || die "refusing to wipe without --yes-i-know flag"

# 1. Stop all services and remove their volumes regardless of which profile
#    is currently active. compose tolerates inactive profiles, and the
#    volumes are declared at compose-level so they get removed even if
#    their profile-gated service was never started.
log "docker compose down --volumes (all profiles)"
docker compose --profile postgresql --profile mysql down --volumes --remove-orphans

# 2. Remove systemd backup timer.
if systemctl list-unit-files 2>/dev/null | grep -q bitwarden-backup.timer; then
  log "Disabling systemd backup timer"
  systemctl disable --now bitwarden-backup.timer || true
  rm -f /etc/systemd/system/bitwarden-backup.{service,timer}
  systemctl daemon-reload
fi

# 3. Optional --wipe-all: nginx vhost, certbot cert, .env.
if "$WIPE_ALL"; then
  log "--wipe-all: removing nginx vhost, certbot cert, .env"

  rm -f /etc/nginx/sites-enabled/bitwarden.conf
  rm -f /etc/nginx/sites-available/bitwarden.conf
  # The vhost was named after BW_DOMAIN, not always 'bitwarden.conf' — clean
  # both possibilities. Read the domain from .env (still present at this point).
  if [ -f "$REPO_ROOT/.env" ]; then
    domain="$(grep -E '^BW_DOMAIN=' "$REPO_ROOT/.env" | cut -d= -f2-)"
    if [ -n "$domain" ]; then
      rm -f "/etc/nginx/sites-enabled/${domain}.conf"
      rm -f "/etc/nginx/sites-available/${domain}.conf"
      log "Removing certbot cert for $domain"
      certbot delete --cert-name "$domain" -n 2>/dev/null || true
    fi
  fi
  systemctl reload nginx 2>/dev/null || true

  rm -f "$REPO_ROOT/.env"
fi

log "Wipe complete (wipe-all=$WIPE_ALL). Backup archives in $BACKUP_DIR are NOT removed."
