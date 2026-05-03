#!/usr/bin/env bash
# Update bitwarden image to current :beta tag.
# Run: sudo ./scripts/update.sh

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root

DIGEST_FILE="$REPO_ROOT/.last_known_good_digest"

# Capture current digest before pulling
CURRENT="$(docker inspect --format '{{index .RepoDigests 0}}' bitwarden/self-host:beta 2>/dev/null || true)"
if [ -n "$CURRENT" ]; then
  echo "$CURRENT" > "$DIGEST_FILE"
  log "Saved current digest to $DIGEST_FILE: $CURRENT"
fi

log "Pulling latest :beta"
docker compose pull

log "Recreating container"
docker compose up -d

log "Waiting for healthcheck"
for i in $(seq 1 60); do
  status="$(docker inspect --format '{{.State.Health.Status}}' bitwarden 2>/dev/null || echo none)"
  [ "$status" = "healthy" ] && break
  sleep 2
  [ "$i" = 60 ] && die "container did not become healthy in 120 s after update"
done

log "Pruning dangling images"
docker image prune -f >/dev/null

NEW="$(docker inspect --format '{{index .RepoDigests 0}}' bitwarden/self-host:beta 2>/dev/null || echo unknown)"
log "Update complete; running $NEW"
log "To roll back: edit docker-compose.yml to use image: $CURRENT and 'docker compose up -d'"
