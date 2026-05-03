#!/usr/bin/env bash
# Daily encrypted backup of the bitwarden_data volume.
# Run: sudo ./scripts/backup.sh
# Invoked automatically by systemd timer bitwarden-backup.timer.

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root

BACKUP_DIR=/var/backups/bitwarden
PASS_FILE=/root/.bitwarden-backup-pass
RETENTION_DAYS=7
TS="$(date -u +%Y-%m-%d-%H%M)"

mkdir -p "$BACKUP_DIR"

# Generate password file on first run
if [ ! -f "$PASS_FILE" ]; then
  log "Generating new backup encryption password at $PASS_FILE"
  head -c 64 /dev/urandom | base64 -w0 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  cat >&2 <<EOF

================================================================================
NEW BACKUP PASSWORD GENERATED. SAVE THIS OFFLINE NOW (paper or external vault):

  $(cat "$PASS_FILE")

Without this password, encrypted backups CANNOT be decrypted.
Path on this VPS: $PASS_FILE (chmod 600).
================================================================================

EOF
fi

# 1. Atomic SQLite backup inside container (only if container is running).
# Path /etc/bitwarden/vault.db is the BW_DB_FILE default (Dockerfile line 40,
# verified in spec section 11.1).
if docker ps --format '{{.Names}}' | grep -qx bitwarden; then
  log "Running SQLite atomic backup inside container"
  docker compose exec -T bitwarden \
    sh -c 'sqlite3 /etc/bitwarden/vault.db ".backup /etc/bitwarden/vault.db.bak"' \
    || die "sqlite backup failed inside container"
else
  log "WARN: bitwarden container not running; volume snapshot will reflect on-disk state only"
fi

# 2. Tar the volume into BACKUP_DIR via a throw-away container
RAW="$BACKUP_DIR/${TS}.tar.gz"
log "Snapshotting volume to $RAW"
docker run --rm \
  -v bitwarden_data:/src:ro \
  -v "$BACKUP_DIR:/dst" \
  alpine sh -c "tar czf /dst/${TS}.tar.gz -C /src ." \
  || die "tar of volume failed"

# 3. Encrypt
ENC="${RAW}.enc"
log "Encrypting to $ENC"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$RAW" \
  -out "$ENC" \
  -pass "file:$PASS_FILE" \
  || die "encryption failed"
rm -f "$RAW"

# 4. Remove the in-container .bak (if it exists)
if docker ps --format '{{.Names}}' | grep -qx bitwarden; then
  docker compose exec -T bitwarden rm -f /etc/bitwarden/vault.db.bak || true
fi

# 5. Rotate: delete .enc files older than RETENTION_DAYS
log "Pruning backups older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz.enc' -mtime "+$RETENTION_DAYS" -print -delete

# 6. Summary
SIZE_BYTES="$(stat -c%s "$ENC")"
log "Backup ok: $ENC (${SIZE_BYTES} bytes)"
