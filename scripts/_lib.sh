#!/usr/bin/env bash
# Shared helpers sourced by all scripts/*.sh files.
# Source from a script that lives in scripts/, with: source "$(dirname "$0")/_lib.sh"

set -euo pipefail
IFS=$'\n\t'

# Resolve repo root: parent of the directory containing this file.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
SCRIPT_NAME="$(basename "${0:-shell}")"

log() {
  printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_NAME" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 $*)"
}

require_repo_root() {
  [ -f "$REPO_ROOT/docker-compose.yml" ] \
    || die "not in repo root (no docker-compose.yml found at $REPO_ROOT)"
  cd "$REPO_ROOT"
}

# Load .env into the current shell, exporting all vars.
load_env() {
  [ -f "$REPO_ROOT/.env" ] || die ".env not found; copy .env.example to .env and fill it"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
  : "${BW_DOMAIN:?BW_DOMAIN missing in .env}"
  : "${BW_BIND_PORT:?BW_BIND_PORT missing in .env}"
}

# ---- multi-DB additions (spec 2026-05-04) ----

# Backup-related constants previously hard-coded inside backup.sh.
BACKUP_DIR=/var/backups/bitwarden
PASS_FILE=/root/.bitwarden-backup-pass
RETENTION_DAYS=7

# Resolve and validate the DB provider from .env. Echoes the provider on stdout.
db_provider() {
  local p="${BW_DB_PROVIDER:-}"
  case "$p" in
    sqlite|postgresql|mysql) echo "$p" ;;
    "")  die "BW_DB_PROVIDER not set in .env" ;;
    *)   die "Invalid BW_DB_PROVIDER='$p' (expected: sqlite|postgresql|mysql)" ;;
  esac
}

# Generate the encryption pass file on first call; idempotent.
# Factored out of backup.sh so any script that may need to read encrypted
# archives (restore.sh) can rely on the same path/format.
ensure_pass_file() {
  [ -f "$PASS_FILE" ] && return 0
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
}

# Wait for postgres or mysql container to report healthy after `compose up`.
# Argument: provider name (postgresql|mysql).
wait_db_healthy() {
  local svc="$1" name
  case "$svc" in
    postgresql) name=bitwarden-postgres ;;
    mysql)      name=bitwarden-mysql ;;
    *) die "wait_db_healthy: unknown service $svc" ;;
  esac
  local status
  for _ in $(seq 1 60); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo none)"
    [ "$status" = "healthy" ] && return 0
    sleep 2
  done
  die "$name did not become healthy in 120s"
}
