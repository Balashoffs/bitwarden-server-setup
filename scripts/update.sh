#!/usr/bin/env bash
# Update bitwarden image to whatever tag is pinned in docker-compose.yml.
# To bump versions, edit the `image:` line in docker-compose.yml first,
# then run this script.
# Run: sudo ./scripts/update.sh

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root

DIGEST_FILE="$REPO_ROOT/.last_known_good_digest"

# Resolve the image reference from compose so this script keeps working
# after a tag bump in docker-compose.yml.
IMAGE="$(docker compose config --images 2>/dev/null | head -1)"
[ -n "$IMAGE" ] || die "could not determine image from docker-compose.yml"
log "Operating on image: $IMAGE"

# Capture current digest before pulling
CURRENT="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)"
if [ -n "$CURRENT" ]; then
  echo "$CURRENT" > "$DIGEST_FILE"
  log "Saved current digest to $DIGEST_FILE: $CURRENT"
fi

log "Pulling $IMAGE"
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

NEW="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || echo unknown)"
log "Update complete; running $NEW"
log "To roll back: edit docker-compose.yml to use image: $CURRENT and 'docker compose up -d'"
