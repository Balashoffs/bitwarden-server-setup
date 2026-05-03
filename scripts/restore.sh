#!/usr/bin/env bash
# Restore Bitwarden volume from an encrypted backup archive.
# DESTRUCTIVE: wipes the existing bitwarden_data volume.
# Run: sudo ./scripts/restore.sh /var/backups/bitwarden/<file>.tar.gz.enc --yes-i-know

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$1" "${2:-}"
require_repo_root

ARCHIVE="${1:-}"
CONFIRM="${2:-}"

[ -n "$ARCHIVE" ] || die "usage: $0 <archive.tar.gz.enc> --yes-i-know"
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
[ "$CONFIRM" = "--yes-i-know" ] \
  || die "refusing to wipe volume without --yes-i-know flag"

PASS_FILE=/root/.bitwarden-backup-pass
PASS_OPT=""
if [ -f "$PASS_FILE" ]; then
  PASS_OPT="-pass file:$PASS_FILE"
else
  log "Pass file $PASS_FILE not found; openssl will prompt for password"
  PASS_OPT="-pass stdin"
fi

TMP="$(mktemp /tmp/bw-restore.XXXXXX.tar.gz)"
trap 'rm -f "$TMP"' EXIT

log "Decrypting $ARCHIVE → $TMP"
# shellcheck disable=SC2086
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$ARCHIVE" -out "$TMP" $PASS_OPT \
  || die "decryption failed"

log "Stopping container"
docker compose down

log "Recreating volume bitwarden_data"
docker volume rm bitwarden_data >/dev/null 2>&1 || true
docker volume create bitwarden_data >/dev/null

log "Unpacking archive into volume"
docker run --rm \
  -v bitwarden_data:/dst \
  -v "$TMP:/restore.tar.gz:ro" \
  alpine tar xzf /restore.tar.gz -C /dst \
  || die "unpack failed"

log "Starting container"
docker compose up -d
log "Waiting for healthcheck"
for i in $(seq 1 60); do
  status="$(docker inspect --format '{{.State.Health.Status}}' bitwarden 2>/dev/null || echo none)"
  [ "$status" = "healthy" ] && break
  sleep 2
  [ "$i" = 60 ] && die "container did not become healthy in 120 s after restore"
done

cat >&2 <<EOF

==== restore.sh complete ====

Restored from: $ARCHIVE
Open: https://${BW_DOMAIN:-<your-domain>}
Login with the master password used when this backup was created.
EOF
