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
