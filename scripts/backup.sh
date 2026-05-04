#!/usr/bin/env bash
# Daily encrypted backup of bitwarden_data + (for postgres/mysql) DB dump.
# Run: sudo ./scripts/backup.sh
# Invoked automatically by systemd timer bitwarden-backup.timer.

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root
load_env

PROVIDER="$(db_provider)"
TS="$(date -u +%Y-%m-%d-%H%M)"

mkdir -p "$BACKUP_DIR"
ensure_pass_file

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

RAW="$BACKUP_DIR/${TS}.tar.gz"
ENC="${RAW}.enc"

# 1. SQLite atomic backup inside container (only if container is running and
#    we are in sqlite mode). Spec section 11.1 of the predecessor design
#    locks BW_DB_FILE = /etc/bitwarden/vault.db.
if [ "$PROVIDER" = "sqlite" ] && docker ps --format '{{.Names}}' | grep -qx bitwarden; then
  log "Running SQLite atomic backup inside container"
  docker compose exec -T bitwarden \
    sh -c 'sqlite3 /etc/bitwarden/vault.db ".backup /etc/bitwarden/vault.db.bak"' \
    || die "sqlite atomic backup failed inside container"
elif [ "$PROVIDER" = "sqlite" ]; then
  log "WARN: bitwarden container not running; volume snapshot will reflect on-disk state only"
fi

# 2. Snapshot bitwarden_data volume (always — config, attachments, sends).
log "Snapshotting bitwarden_data volume"
docker run --rm \
  -v bitwarden_data:/src:ro \
  -v "$WORKDIR:/dst" \
  alpine tar czf /dst/bitwarden_data.tgz -C /src . \
  || die "tar of bitwarden_data failed"

# 3. DB dump for postgres/mysql.
case "$PROVIDER" in
  postgresql)
    log "Running pg_dump"
    docker compose exec -T postgres \
      pg_dump -U "$BW_DB_USERNAME" "$BW_DB_DATABASE" \
      | gzip > "$WORKDIR/dump.sql.gz" \
      || die "pg_dump failed"
    ;;
  mysql)
    log "Running mysqldump"
    docker compose exec -T mysql \
      mysqldump --single-transaction \
        -u "$BW_DB_USERNAME" -p"$BW_DB_PASSWORD" "$BW_DB_DATABASE" \
      | gzip > "$WORKDIR/dump.sql.gz" \
      || die "mysqldump failed"
    ;;
esac

# 4. PROVIDER manifest + bundle + encrypt.
echo "$PROVIDER" > "$WORKDIR/PROVIDER"
log "Bundling archive at $RAW"
tar -C "$WORKDIR" -czf "$RAW" .

log "Encrypting to $ENC"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$RAW" \
  -out "$ENC" \
  -pass "file:$PASS_FILE" \
  || die "encryption failed"
rm -f "$RAW"

# 5. Clean up the in-container .bak file (sqlite mode).
if [ "$PROVIDER" = "sqlite" ] && docker ps --format '{{.Names}}' | grep -qx bitwarden; then
  docker compose exec -T bitwarden rm -f /etc/bitwarden/vault.db.bak || true
fi

# 6. Rotate.
log "Pruning backups older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz.enc' -mtime "+$RETENTION_DAYS" -print -delete

# 7. Summary.
SIZE_BYTES="$(stat -c%s "$ENC" 2>/dev/null || stat -f%z "$ENC")"
log "Backup ok ($PROVIDER): $ENC (${SIZE_BYTES} bytes)"
