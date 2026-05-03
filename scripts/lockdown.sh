#!/usr/bin/env bash
# Disable user registration after the owner account has been created.
# Run: sudo ./scripts/lockdown.sh

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root
load_env

if grep -q '^BW_DISABLE_REGISTRATION=true' .env; then
  log "Registration already disabled — nothing to do"
  exit 0
fi

log "Setting BW_DISABLE_REGISTRATION=true in .env"
sed -i 's/^BW_DISABLE_REGISTRATION=.*/BW_DISABLE_REGISTRATION=true/' .env

log "Recreating container with new env"
docker compose up -d

log "Waiting for healthcheck"
for i in $(seq 1 60); do
  status="$(docker inspect --format '{{.State.Health.Status}}' bitwarden 2>/dev/null || echo none)"
  [ "$status" = "healthy" ] && break
  sleep 2
  [ "$i" = 60 ] && die "container did not become healthy in 120 s"
done

# Probe registration endpoint — expect 4xx.
# BW_DOMAIN is the bare hostname (per spec section 11); sanity-check no scheme leaked in.
case "$BW_DOMAIN" in
  http://*|https://*) die "BW_DOMAIN must be bare hostname, not URL: '$BW_DOMAIN' (see spec section 11)" ;;
esac
HOSTNAME="$BW_DOMAIN"
code="$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "https://${HOSTNAME}/identity/accounts/register" \
  -H 'Content-Type: application/json' \
  -d '{"email":"smoke@test.invalid","masterPasswordHash":"x","masterPasswordHint":null,"key":"x","kdf":0,"kdfIterations":600000}')"
if [ "$code" -ge 400 ] && [ "$code" -lt 500 ]; then
  log "Registration locked (HTTP $code from /identity/accounts/register)"
else
  log "WARN: register endpoint returned $code (expected 4xx); manual verification recommended"
fi

log "Lockdown complete"
