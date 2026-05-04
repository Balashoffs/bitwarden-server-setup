#!/usr/bin/env bash
# Restore Bitwarden from an encrypted backup archive.
# DESTRUCTIVE: wipes the existing bitwarden_data volume and (for
# postgres/mysql) reloads the database from dump.sql.gz inside the archive.
# Run: sudo ./scripts/restore.sh /var/backups/bitwarden/<file>.tar.gz.enc --yes-i-know

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root
load_env

ARCHIVE="${1:-}"
CONFIRM="${2:-}"

[ -n "$ARCHIVE" ] || die "usage: $0 <archive.tar.gz.enc> --yes-i-know"
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
[ "$CONFIRM" = "--yes-i-know" ] || die "refusing to wipe volume without --yes-i-know flag"

CUR_PROVIDER="$(db_provider)"

# Decryption needs the same pass file the backup used.
[ -f "$PASS_FILE" ] || die "missing $PASS_FILE — restore needs the original encryption password"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TMP="$WORKDIR/archive.tar.gz"
log "Decrypting $ARCHIVE → $TMP"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$ARCHIVE" \
  -out "$TMP" \
  -pass "file:$PASS_FILE" \
  || die "decryption failed (wrong password? truncated archive?)"

log "Extracting archive into workdir"
tar -xzf "$TMP" -C "$WORKDIR"
rm -f "$TMP"

# Detect format. New archives carry a top-level PROVIDER manifest.
if [ -f "$WORKDIR/PROVIDER" ]; then
  SRC_PROVIDER="$(cat "$WORKDIR/PROVIDER")"
  DATA_TGZ="$WORKDIR/bitwarden_data.tgz"
  log "Detected new-format archive (provider=$SRC_PROVIDER)"
else
  log "No PROVIDER manifest — treating as legacy sqlite archive (pre-multi-DB format)"
  SRC_PROVIDER="sqlite"
  DATA_TGZ=""
fi

if [ "$SRC_PROVIDER" != "$CUR_PROVIDER" ]; then
  die "Archive was created in '$SRC_PROVIDER' mode but current .env is '$CUR_PROVIDER'. Cross-mode restore is not supported."
fi

log "Stopping all services"
docker compose --profile postgresql --profile mysql down

log "Recreating volume bitwarden_data"
docker volume rm bitwarden_data >/dev/null 2>&1 || true
docker volume create bitwarden_data >/dev/null

if [ -n "$DATA_TGZ" ]; then
  log "Unpacking bitwarden_data.tgz into volume"
  docker run --rm \
    -v bitwarden_data:/dst \
    -v "$DATA_TGZ:/in.tgz:ro" \
    alpine tar xzf /in.tgz -C /dst \
    || die "unpack of bitwarden_data failed"
else
  log "Legacy archive: copying workdir contents into volume"
  docker run --rm \
    -v bitwarden_data:/dst \
    -v "$WORKDIR:/in:ro" \
    alpine sh -c 'cp -a /in/. /dst/' \
    || die "legacy unpack failed"
fi

# Bring services back up. For postgres/mysql we also load the DB dump.
if [ "$CUR_PROVIDER" = "sqlite" ]; then
  log "Starting bitwarden (sqlite mode)"
  docker compose up -d
else
  log "Starting $CUR_PROVIDER + bitwarden"
  docker compose --profile "$CUR_PROVIDER" up -d
  wait_db_healthy "$CUR_PROVIDER"

  case "$CUR_PROVIDER" in
    postgresql)
      log "Loading dump.sql.gz via psql"
      gunzip -c "$WORKDIR/dump.sql.gz" \
        | docker compose exec -T postgres \
            psql -U "$BW_DB_USERNAME" -d "$BW_DB_DATABASE" \
        || die "psql restore failed"
      ;;
    mysql)
      log "Loading dump.sql.gz via mysql"
      gunzip -c "$WORKDIR/dump.sql.gz" \
        | docker compose exec -T mysql \
            mysql -u "$BW_DB_USERNAME" -p"$BW_DB_PASSWORD" "$BW_DB_DATABASE" \
        || die "mysql restore failed"
      ;;
  esac

  log "Restarting bitwarden so it picks up the freshly-loaded DB"
  docker compose --profile "$CUR_PROVIDER" restart bitwarden
fi

log "Waiting for bitwarden healthcheck"
for i in $(seq 1 60); do
  status="$(docker inspect --format '{{.State.Health.Status}}' bitwarden 2>/dev/null || echo none)"
  [ "$status" = "healthy" ] && break
  sleep 2
  [ "$i" = 60 ] && die "container did not become healthy in 120 s after restore"
done

cat >&2 <<EOF

==== restore.sh complete ====

Restored from: $ARCHIVE
Mode: $CUR_PROVIDER
Open: https://${BW_DOMAIN:-<your-domain>}
Login with the master password used when this backup was created.
EOF
