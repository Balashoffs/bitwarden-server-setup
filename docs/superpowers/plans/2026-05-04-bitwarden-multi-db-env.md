# Bitwarden multi-DB env support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PostgreSQL and MySQL as alternatives to the existing SQLite-only Bitwarden Lite setup, via three per-DB env templates, docker-compose profiles, multi-mode backup/restore, and a new `wipe.sh` teardown script.

**Architecture:** Single `docker-compose.yml` with `bitwarden` always running (unprofiled) and `postgres` / `mysql` sidecar services gated behind compose profiles whose names equal the `BW_DB_PROVIDER` value. Scripts read `.env`, branch on provider, and act accordingly. Backup archive format gains a top-level `PROVIDER` manifest plus `bitwarden_data.tgz` and (for non-SQLite) `dump.sql.gz`; legacy archives still restore via fallback path.

**Tech Stack:** Bash 5, docker compose v2, openssl (encryption), postgres:16-alpine, mysql:8.0, shellcheck (lint).

**Spec:** `docs/superpowers/specs/2026-05-04-bitwarden-multi-db-env-design.md`

**Verification model:** No bats/test framework exists in this repo. Each task validates via `shellcheck`, `bash -n`, `docker compose config`, and explicit failure-mode rehearsal where possible. End-to-end smoke testing is manual on a VPS (covered by spec section 7), out of scope for this plan.

---

## File map

**Created:**
- `.env.example.sqlite`
- `.env.example.postgres`
- `.env.example.mysql`
- `scripts/wipe.sh`

**Removed:**
- `.env.example`

**Modified:**
- `docker-compose.yml`
- `scripts/_lib.sh`
- `scripts/install.sh`
- `scripts/backup.sh`
- `scripts/restore.sh`
- `README.md`

**Untouched:** `scripts/update.sh`, `scripts/bootstrap.sh`, `scripts/lockdown.sh`, `nginx/`, `systemd/`, `.gitignore`.

---

## Task 1: Extend `scripts/_lib.sh` with shared helpers

Adds the constants and helpers the rest of the plan depends on. Does NOT change behavior of existing helpers.

**Files:**
- Modify: `scripts/_lib.sh`

- [ ] **Step 1: Read current `_lib.sh` to confirm starting state**

```bash
cat scripts/_lib.sh
```

Expected: file ends after `load_env()` (line 46). No constants `BACKUP_DIR`, `PASS_FILE`, `RETENTION_DAYS` defined.

- [ ] **Step 2: Append constants and helpers to `scripts/_lib.sh`**

Open `scripts/_lib.sh` and append the following after the existing `load_env()` function (before EOF):

```bash

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
```

- [ ] **Step 3: Syntax check**

Run:
```bash
bash -n scripts/_lib.sh
```

Expected: no output, exit code 0.

- [ ] **Step 4: Lint with shellcheck (if installed)**

Run:
```bash
command -v shellcheck >/dev/null && shellcheck -x scripts/_lib.sh || echo "shellcheck not installed; skipping"
```

Expected: clean output or "skipping". If shellcheck flags the new helpers, fix them inline (common false positives: SC2155 — split declaration/assignment).

- [ ] **Step 5: Functional smoke for `db_provider`**

Run an inline check of the validator:
```bash
( source scripts/_lib.sh; BW_DB_PROVIDER=sqlite db_provider )
( source scripts/_lib.sh; BW_DB_PROVIDER=postgresql db_provider )
( source scripts/_lib.sh; BW_DB_PROVIDER=mysql db_provider )
( source scripts/_lib.sh; BW_DB_PROVIDER=foo db_provider 2>&1 ) || true
( source scripts/_lib.sh; unset BW_DB_PROVIDER; db_provider 2>&1 ) || true
```

Expected: first three echo `sqlite` / `postgresql` / `mysql`. Last two emit `ERROR: Invalid BW_DB_PROVIDER='foo' …` and `ERROR: BW_DB_PROVIDER not set in .env` and exit non-zero. (Subshell `(...)` isolates the `set -e` failure.)

- [ ] **Step 6: Commit**

```bash
git add scripts/_lib.sh
git commit -m "$(cat <<'EOF'
Add db_provider/ensure_pass_file/wait_db_healthy helpers to _lib.sh

Foundation for multi-DB support. Extracts BACKUP_DIR/PASS_FILE/
RETENTION_DAYS constants from backup.sh into _lib.sh so restore.sh
and wipe.sh share the same paths.
EOF
)"
```

---

## Task 2: Replace `.env.example` with three per-DB templates

Pure file work; no script logic.

**Files:**
- Create: `.env.example.sqlite`
- Create: `.env.example.postgres`
- Create: `.env.example.mysql`
- Delete: `.env.example`

- [ ] **Step 1: Create `.env.example.sqlite`**

Write to `.env.example.sqlite`:

```bash
# DB mode: SQLite. Lives inside the bitwarden_data volume.
# Simplest mode — no separate database container.

# Domain — BARE hostname (no scheme). The unified image's entrypoint
# prepends https:// itself; passing a URL would yield "https://https://..." links.
BW_DOMAIN=example.com

# Email used by certbot for Let's Encrypt account/recovery
ADMIN_EMAIL=you@example.tld

# Bitwarden installation credentials — get from https://bitwarden.com/host/
# Enter email, copy values verbatim. Free, mandatory for licensing checks.
BW_INSTALLATION_ID=
BW_INSTALLATION_KEY=

# Local bind port for the Bitwarden container on 127.0.0.1
BW_BIND_PORT=8082

# Registration — false at first start (so you can register the owner),
# scripts/lockdown.sh flips this to true after.
BW_DISABLE_REGISTRATION=false

# Database — SQLite stored inside the named volume
BW_DB_PROVIDER=sqlite
```

- [ ] **Step 2: Create `.env.example.postgres`**

Write to `.env.example.postgres`:

```bash
# DB mode: PostgreSQL. Runs as a sidecar service in docker-compose
# under profile "postgresql". Set BW_DB_PASSWORD before install.sh.

BW_DOMAIN=example.com
ADMIN_EMAIL=you@example.tld
BW_INSTALLATION_ID=
BW_INSTALLATION_KEY=
BW_BIND_PORT=8082
BW_DISABLE_REGISTRATION=false

BW_DB_PROVIDER=postgresql
BW_DB_SERVER=postgres        # docker-compose service name; do not change
BW_DB_DATABASE=bitwarden
BW_DB_USERNAME=bitwarden
BW_DB_PASSWORD=              # REQUIRED: generate via `openssl rand -base64 32`
BW_DB_PORT=5432
```

- [ ] **Step 3: Create `.env.example.mysql`**

Write to `.env.example.mysql`:

```bash
# DB mode: MySQL. Runs as a sidecar service in docker-compose
# under profile "mysql". Set BW_DB_PASSWORD before install.sh.

BW_DOMAIN=example.com
ADMIN_EMAIL=you@example.tld
BW_INSTALLATION_ID=
BW_INSTALLATION_KEY=
BW_BIND_PORT=8082
BW_DISABLE_REGISTRATION=false

BW_DB_PROVIDER=mysql
BW_DB_SERVER=mysql           # docker-compose service name; do not change
BW_DB_DATABASE=bitwarden
BW_DB_USERNAME=bitwarden
BW_DB_PASSWORD=              # REQUIRED: generate via `openssl rand -base64 32`
BW_DB_PORT=3306
```

- [ ] **Step 4: Delete legacy `.env.example`**

Run:
```bash
git rm .env.example
```

Expected: file deletion staged.

- [ ] **Step 5: Verify all three templates parse as bash**

Run:
```bash
for f in .env.example.sqlite .env.example.postgres .env.example.mysql; do
  echo "=== $f ==="
  bash -n <(printf 'set -a\n'; cat "$f") && echo OK
done
```

Expected: each template prints `=== <file> ===` followed by `OK`. The `set -a` wrap mimics how `load_env` sources the file.

- [ ] **Step 6: Commit**

```bash
git add .env.example.sqlite .env.example.postgres .env.example.mysql
git commit -m "$(cat <<'EOF'
Replace .env.example with per-DB templates (sqlite/postgres/mysql)

Each template carries the full set of variables required for its mode.
Postgres and mysql ship with empty BW_DB_PASSWORD — install.sh fails
fast if it remains empty, forcing the user to generate one.
EOF
)"
```

---

## Task 3: Update `docker-compose.yml` with profiles and DB sidecars

Adds postgres + mysql services, profile-gates them, declares their volumes, wires bitwarden's `depends_on` with `required: false`.

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Read current compose file to confirm starting state**

```bash
cat docker-compose.yml
```

Expected: 28 lines, single `bitwarden` service with two named volumes.

- [ ] **Step 2: Replace `docker-compose.yml` with the multi-DB version**

Overwrite `docker-compose.yml` with:

```yaml
services:
  bitwarden:
    image: ghcr.io/bitwarden/lite:2026.4.0
    container_name: bitwarden
    restart: unless-stopped
    ports:
      - "127.0.0.1:${BW_BIND_PORT}:8080"
    env_file: .env
    environment:
      BW_DOMAIN: ${BW_DOMAIN}
      BW_DB_PROVIDER: ${BW_DB_PROVIDER}
      BW_DB_SERVER: ${BW_DB_SERVER:-}
      BW_DB_DATABASE: ${BW_DB_DATABASE:-}
      BW_DB_USERNAME: ${BW_DB_USERNAME:-}
      BW_DB_PASSWORD: ${BW_DB_PASSWORD:-}
      BW_DB_PORT: ${BW_DB_PORT:-}
      globalSettings__disableUserRegistration: ${BW_DISABLE_REGISTRATION}
      globalSettings__installation__id: ${BW_INSTALLATION_ID}
      globalSettings__installation__key: ${BW_INSTALLATION_KEY}
    volumes:
      - bitwarden_data:/etc/bitwarden
      - bitwarden_logs:/var/log/bitwarden
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8080/alive"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
    depends_on:
      postgres:
        condition: service_healthy
        required: false
      mysql:
        condition: service_healthy
        required: false

  postgres:
    image: postgres:16-alpine
    container_name: bitwarden-postgres
    profiles: ["postgresql"]
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${BW_DB_DATABASE}
      POSTGRES_USER: ${BW_DB_USERNAME}
      POSTGRES_PASSWORD: ${BW_DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  mysql:
    image: mysql:8.0
    container_name: bitwarden-mysql
    profiles: ["mysql"]
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: ${BW_DB_DATABASE}
      MYSQL_USER: ${BW_DB_USERNAME}
      MYSQL_PASSWORD: ${BW_DB_PASSWORD}
      MYSQL_RANDOM_ROOT_PASSWORD: "yes"
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost",
             "-u", "$${MYSQL_USER}", "-p$${MYSQL_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  bitwarden_data:
  bitwarden_logs:
  postgres_data:
  mysql_data:
```

- [ ] **Step 3: Validate compose for SQLite mode**

Create a throwaway `.env` for parsing:
```bash
cat > /tmp/bw-test.env <<'EOF'
BW_DOMAIN=example.com
BW_BIND_PORT=8082
BW_DB_PROVIDER=sqlite
BW_DISABLE_REGISTRATION=false
BW_INSTALLATION_ID=00000000-0000-0000-0000-000000000000
BW_INSTALLATION_KEY=k
EOF
docker compose --env-file /tmp/bw-test.env config >/dev/null
```

Expected: exit 0, no errors. Compose accepts the file even though BW_DB_SERVER/USERNAME/etc are unset (the `:-` defaults make them optional).

- [ ] **Step 4: Validate compose for PostgreSQL mode**

```bash
cat > /tmp/bw-test.env <<'EOF'
BW_DOMAIN=example.com
BW_BIND_PORT=8082
BW_DB_PROVIDER=postgresql
BW_DB_SERVER=postgres
BW_DB_DATABASE=bitwarden
BW_DB_USERNAME=bitwarden
BW_DB_PASSWORD=secret
BW_DB_PORT=5432
BW_DISABLE_REGISTRATION=false
BW_INSTALLATION_ID=00000000-0000-0000-0000-000000000000
BW_INSTALLATION_KEY=k
EOF
docker compose --env-file /tmp/bw-test.env --profile postgresql config >/dev/null
```

Expected: exit 0. The `postgres` service appears in the rendered config.

- [ ] **Step 5: Validate compose for MySQL mode**

```bash
sed -i.bak 's/BW_DB_PROVIDER=postgresql/BW_DB_PROVIDER=mysql/; s/BW_DB_SERVER=postgres/BW_DB_SERVER=mysql/; s/BW_DB_PORT=5432/BW_DB_PORT=3306/' /tmp/bw-test.env
docker compose --env-file /tmp/bw-test.env --profile mysql config >/dev/null
rm -f /tmp/bw-test.env /tmp/bw-test.env.bak
```

Expected: exit 0. The `mysql` service appears in the rendered config.

- [ ] **Step 6: Confirm profiles actually gate the DB sidecars**

```bash
cat > /tmp/bw-test.env <<'EOF'
BW_DOMAIN=example.com
BW_BIND_PORT=8082
BW_DB_PROVIDER=sqlite
BW_DISABLE_REGISTRATION=false
BW_INSTALLATION_ID=00000000-0000-0000-0000-000000000000
BW_INSTALLATION_KEY=k
EOF
# Without --profile, expect no postgres/mysql services in the rendered config
docker compose --env-file /tmp/bw-test.env config | grep -E '^\s*(postgres|mysql):' || echo "OK: profiles gating works"
rm -f /tmp/bw-test.env
```

Expected: `OK: profiles gating works` (the grep finds no service entries in sqlite mode).

- [ ] **Step 7: Commit**

```bash
git add docker-compose.yml
git commit -m "$(cat <<'EOF'
Add postgres and mysql sidecar services under compose profiles

Profile names match BW_DB_PROVIDER values so install.sh can pass them
through verbatim. Bitwarden depends_on … required: false lets the
unprofiled service tolerate inactive sidecars. Volumes for both
sidecars are declared up-front so wipe.sh can clean them in one pass.
EOF
)"
```

---

## Task 4: Update `scripts/install.sh` to pick the docker-compose profile

Replaces the unconditional `docker compose up -d` with a provider-aware launch and adds password validation for non-sqlite modes.

**Files:**
- Modify: `scripts/install.sh:11-12, 25-29, 41-44`

- [ ] **Step 1: Read the section we are replacing**

```bash
sed -n '10,45p' scripts/install.sh
```

Expected: shows `load_env`, `require_cmd …`, BW_DOMAIN check, BW_INSTALLATION/ADMIN_EMAIL/BW_BIND_PORT checks, port-free check, image pull, `docker compose up -d`.

- [ ] **Step 2: Insert provider validation after the existing env checks**

After line 28 (the `BW_BIND_PORT` empty check), add the following block:

```bash
# Resolve and validate DB provider; for non-sqlite modes the password is mandatory.
PROVIDER="$(db_provider)"
if [ "$PROVIDER" != "sqlite" ]; then
  [ -n "${BW_DB_PASSWORD:-}" ] || die "BW_DB_PASSWORD must be set in .env for $PROVIDER mode"
  [ -n "${BW_DB_USERNAME:-}" ] || die "BW_DB_USERNAME must be set in .env for $PROVIDER mode"
  [ -n "${BW_DB_DATABASE:-}" ] || die "BW_DB_DATABASE must be set in .env for $PROVIDER mode"
  [ -n "${BW_DB_SERVER:-}"   ] || die "BW_DB_SERVER must be set in .env for $PROVIDER mode"
  [ -n "${BW_DB_PORT:-}"     ] || die "BW_DB_PORT must be set in .env for $PROVIDER mode"
fi
log "DB provider: $PROVIDER"
```

- [ ] **Step 3: Replace the `docker compose pull` / `docker compose up -d` block**

Find the existing block:

```bash
log "Pulling image"
docker compose pull
log "Starting container"
docker compose up -d
```

Replace with:

```bash
# Compose calls below — pass --profile only for non-sqlite modes so that
# `docker compose up -d` in sqlite mode does not try to start a DB sidecar.
COMPOSE_PROFILE_ARGS=()
if [ "$PROVIDER" != "sqlite" ]; then
  COMPOSE_PROFILE_ARGS=(--profile "$PROVIDER")
fi

log "Pulling image"
docker compose "${COMPOSE_PROFILE_ARGS[@]}" pull
log "Starting container(s)"
docker compose "${COMPOSE_PROFILE_ARGS[@]}" up -d
```

- [ ] **Step 4: Syntax check**

```bash
bash -n scripts/install.sh
```

Expected: no output, exit 0.

- [ ] **Step 5: Lint**

```bash
command -v shellcheck >/dev/null && shellcheck -x scripts/install.sh || echo skipping
```

Expected: clean output or "skipping". `COMPOSE_PROFILE_ARGS=()` is correct array syntax — shellcheck may suggest quoting; verify expansion uses `"${COMPOSE_PROFILE_ARGS[@]}"` (already does).

- [ ] **Step 6: Rehearse the failure modes (no docker required)**

Source `_lib.sh` and `install.sh` won't actually run on macOS (it requires root, docker, nginx). Instead, do a focused unit-style check by extracting just the validation block to a temp script:

```bash
cat > /tmp/bw-validate.sh <<'EOF'
set -euo pipefail
. ./scripts/_lib.sh
log() { :; }   # silence
PROVIDER="$(db_provider)"
if [ "$PROVIDER" != "sqlite" ]; then
  [ -n "${BW_DB_PASSWORD:-}" ] || die "BW_DB_PASSWORD must be set in .env for $PROVIDER mode"
fi
echo "ok: $PROVIDER"
EOF

# Postgres mode without password → should fail
( BW_DB_PROVIDER=postgresql bash /tmp/bw-validate.sh 2>&1 ) || true
# Postgres mode with password → should succeed
( BW_DB_PROVIDER=postgresql BW_DB_PASSWORD=x bash /tmp/bw-validate.sh )
# Sqlite mode → should succeed without password
( BW_DB_PROVIDER=sqlite bash /tmp/bw-validate.sh )
rm -f /tmp/bw-validate.sh
```

Expected: first call emits `ERROR: BW_DB_PASSWORD must be set in .env for postgresql mode`; second prints `ok: postgresql`; third prints `ok: sqlite`.

- [ ] **Step 7: Commit**

```bash
git add scripts/install.sh
git commit -m "$(cat <<'EOF'
install.sh: select docker-compose profile based on BW_DB_PROVIDER

Sqlite mode keeps the old `docker compose up -d` path. Postgres/mysql
modes pull and start with --profile <provider>. Validates that DB
credentials are populated before any compose call to fail fast on
misconfigured .env.
EOF
)"
```

---

## Task 5: Rewrite `scripts/backup.sh` for multi-DB

Same conventions (encryption, paths, retention), new structured archive layout. Preserves SQLite atomic-backup pattern.

**Files:**
- Modify: `scripts/backup.sh` (full rewrite)

- [ ] **Step 1: Read the current `backup.sh` to confirm we understand the inherited contract**

```bash
cat scripts/backup.sh
```

Expected: 81 lines, opens with sqlite3 .backup pattern, uses BACKUP_DIR/PASS_FILE inline, single-pass tar+encrypt.

- [ ] **Step 2: Overwrite `scripts/backup.sh` with the multi-DB version**

Replace the entire file content with:

```bash
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
```

The `stat -c%s` / `stat -f%z` fallback keeps the script working on macOS for development checks; existing script used `stat -c%s` (Linux-only) and would fail on macOS.

- [ ] **Step 3: Syntax check**

```bash
bash -n scripts/backup.sh
```

Expected: no output, exit 0.

- [ ] **Step 4: Lint**

```bash
command -v shellcheck >/dev/null && shellcheck -x scripts/backup.sh || echo skipping
```

Expected: clean. SC1091 (cannot follow source) is OK with the `# shellcheck source=` directive already in place.

- [ ] **Step 5: Verify the script structure handles all three providers**

Without docker installed, the best we can do locally is grep-verify each provider branch is present:

```bash
grep -E 'PROVIDER.*=.*sqlite' scripts/backup.sh && \
grep 'pg_dump' scripts/backup.sh && \
grep 'mysqldump --single-transaction' scripts/backup.sh && \
grep 'PROVIDER manifest\|echo "$PROVIDER" >' scripts/backup.sh
```

Expected: each grep matches.

- [ ] **Step 6: Commit**

```bash
git add scripts/backup.sh
git commit -m "$(cat <<'EOF'
backup.sh: structured archive with PROVIDER manifest for multi-DB

Always archives bitwarden_data volume (config/attachments/sends).
For postgres/mysql also runs pg_dump/mysqldump and includes
dump.sql.gz alongside. Adds PROVIDER manifest at archive root so
restore.sh can branch unambiguously. Preserves SQLite atomic
.backup pattern. Encryption, output dir, and retention unchanged.
EOF
)"
```

---

## Task 6: Rewrite `scripts/restore.sh` for multi-DB with legacy fallback

Detects the `PROVIDER` manifest; if absent, treats archive as legacy SQLite-only. Hard-fails on cross-mode mismatch.

**Files:**
- Modify: `scripts/restore.sh` (full rewrite)

- [ ] **Step 1: Read current `restore.sh` to confirm starting state**

```bash
cat scripts/restore.sh
```

Expected: 70 lines, decrypts to a single tar.gz, unpacks straight into the volume.

- [ ] **Step 2: Overwrite `scripts/restore.sh`**

Replace the entire file content with:

```bash
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
```

- [ ] **Step 3: Syntax check**

```bash
bash -n scripts/restore.sh
```

Expected: no output, exit 0.

- [ ] **Step 4: Lint**

```bash
command -v shellcheck >/dev/null && shellcheck -x scripts/restore.sh || echo skipping
```

Expected: clean.

- [ ] **Step 5: Verify legacy fallback path is structurally present**

```bash
grep -E 'PROVIDER manifest|legacy sqlite|treating as legacy' scripts/restore.sh
grep -E 'Cross-mode restore is not supported' scripts/restore.sh
```

Expected: both grep commands return matches.

- [ ] **Step 6: Commit**

```bash
git add scripts/restore.sh
git commit -m "$(cat <<'EOF'
restore.sh: multi-DB-aware restore with legacy archive fallback

Reads PROVIDER manifest from new archives and rejects cross-mode
restores explicitly. For postgres/mysql, brings the sidecar up,
waits for healthcheck, loads dump.sql.gz, and restarts bitwarden.
For pre-multi-DB archives (no manifest), falls back to the previous
volume-tarball behaviour assuming sqlite.
EOF
)"
```

---

## Task 7: Create `scripts/wipe.sh`

New destructive-cleanup script. Two modes — default and `--wipe-all`.

**Files:**
- Create: `scripts/wipe.sh`

- [ ] **Step 1: Create `scripts/wipe.sh`**

Write to `scripts/wipe.sh`:

```bash
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
```

- [ ] **Step 2: Make `wipe.sh` executable**

```bash
chmod +x scripts/wipe.sh
```

- [ ] **Step 3: Syntax check**

```bash
bash -n scripts/wipe.sh
```

Expected: no output, exit 0.

- [ ] **Step 4: Lint**

```bash
command -v shellcheck >/dev/null && shellcheck -x scripts/wipe.sh || echo skipping
```

Expected: clean.

- [ ] **Step 5: Rehearse argument validation (no docker required)**

```bash
# Missing --yes-i-know should fail
( cd /tmp && sudo -n /bin/echo skip 2>/dev/null ) >/dev/null  # detect if sudo is configured
# Plain bash check — can't run as root locally, but can verify the flag check
# triggers before any privileged action. We patch require_root to a no-op for this.
cat > /tmp/wipe-rehearsal.sh <<EOF
require_root() { :; }
require_repo_root() { :; }
log() { :; }
source $PWD/scripts/_lib.sh
require_root() { :; }
require_repo_root() { :; }
SAW_CONFIRM=false
WIPE_ALL=false
for arg in "\$@"; do
  case "\$arg" in
    --yes-i-know) SAW_CONFIRM=true ;;
    --wipe-all)   WIPE_ALL=true ;;
  esac
done
"\$SAW_CONFIRM" || die "refusing to wipe without --yes-i-know flag"
echo "OK confirm=\$SAW_CONFIRM wipe_all=\$WIPE_ALL"
EOF

bash /tmp/wipe-rehearsal.sh                          2>&1 || true   # expect die
bash /tmp/wipe-rehearsal.sh --yes-i-know             2>&1           # expect OK confirm=true wipe_all=false
bash /tmp/wipe-rehearsal.sh --yes-i-know --wipe-all  2>&1           # expect OK confirm=true wipe_all=true
rm -f /tmp/wipe-rehearsal.sh
```

Expected: first call dies with `refusing to wipe without --yes-i-know flag`; second prints `OK confirm=true wipe_all=false`; third prints `OK confirm=true wipe_all=true`.

- [ ] **Step 6: Commit**

```bash
git add scripts/wipe.sh
git commit -m "$(cat <<'EOF'
Add scripts/wipe.sh: destructive teardown of the installation

Default: docker compose down --volumes (all profiles) + remove
systemd backup timer. With --wipe-all also removes nginx vhost,
certbot cert, and .env. Backup archives in /var/backups/bitwarden
are intentionally preserved.
EOF
)"
```

---

## Task 8: Update `README.md`

Documents the per-DB templates, the new mode-selection step, and `wipe.sh`.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README to confirm starting state**

```bash
cat README.md
```

Expected: 50 lines; "Quick start" section refers to a single `.env.example`; "Scripts reference" table without a `wipe.sh` row.

- [ ] **Step 2: Replace the Quick start section**

Find:

```markdown
## Quick start

1. Add DNS A-record `example.com → <VPS_IP>`.
2. Get installation ID + key from https://bitwarden.com/host/.
3. SSH to the VPS, then:

   ```bash
   git clone <this-repo> ~/bitwarden-server-setup
   cd ~/bitwarden-server-setup
   sudo ./scripts/bootstrap.sh
   # Re-login so docker group applies
   exit
   ssh <user>@<vps>
   cd ~/bitwarden-server-setup
   cp .env.example .env
   $EDITOR .env   # fill BW_DOMAIN, ADMIN_EMAIL, BW_INSTALLATION_*
   sudo ./scripts/install.sh
   ```

4. Open `https://example.com`, register the single owner account.
```

Replace with:

```markdown
## Quick start

1. Add DNS A-record `example.com → <VPS_IP>`.
2. Get installation ID + key from https://bitwarden.com/host/.
3. Pick a database mode (see "Choosing a database mode" below).
4. SSH to the VPS, then:

   ```bash
   git clone <this-repo> ~/bitwarden-server-setup
   cd ~/bitwarden-server-setup
   sudo ./scripts/bootstrap.sh
   # Re-login so docker group applies
   exit
   ssh <user>@<vps>
   cd ~/bitwarden-server-setup

   # Pick ONE of the three DB-mode templates:
   cp .env.example.sqlite   .env     # SQLite (default, simplest)
   cp .env.example.postgres .env     # PostgreSQL sidecar
   cp .env.example.mysql    .env     # MySQL sidecar

   $EDITOR .env   # fill BW_DOMAIN, ADMIN_EMAIL, BW_INSTALLATION_*,
                  # and (postgres/mysql) BW_DB_PASSWORD via
                  # `openssl rand -base64 32`
   sudo ./scripts/install.sh
   ```

5. Open `https://example.com`, register the single owner account.
```

(Note: the existing list items 5–8 about master password, lockdown, TOTP, backup pass keep their numbering shifted by one — re-renumber them 6, 7, 8, 9 in step 3 below.)

- [ ] **Step 3: Renumber follow-up steps**

In the README, find:

```markdown
4. Open `https://example.com`, register the single owner account.
5. **Write the master password down on paper.** It cannot be reset.
6. Run `sudo ./scripts/lockdown.sh` to disable further registrations.
7. Enable TOTP 2FA in account settings; save the recovery code offline.
8. After the first backup, copy `/root/.bitwarden-backup-pass` offline.
```

After step 2 above the first line is now the new "5. Open …" entry. Bump the subsequent numbers:

```markdown
5. Open `https://example.com`, register the single owner account.
6. **Write the master password down on paper.** It cannot be reset.
7. Run `sudo ./scripts/lockdown.sh` to disable further registrations.
8. Enable TOTP 2FA in account settings; save the recovery code offline.
9. After the first backup, copy `/root/.bitwarden-backup-pass` offline.
```

- [ ] **Step 4: Insert the "Choosing a database mode" section before the Reference section**

Find the line `## Reference` and insert above it:

```markdown
## Choosing a database mode

| Mode | When to use | Backup size | Resource overhead |
|---|---|---|---|
| `sqlite` | Single owner, ≤10 users (default) | small | none (file in volume) |
| `postgresql` | Multi-user, ops experience | medium | +1 container, ~50 MB RAM idle |
| `mysql` | Same as postgresql, MySQL preferred | medium | +1 container, ~400 MB RAM idle |

Mode is chosen at install time by selecting the matching `.env.example.<db>` template. Switching mode after install is **not** supported automatically — see "Switching modes" below.

### Switching modes

There is no SQLite ↔ PostgreSQL ↔ MySQL migration tool. To switch:

1. Export your vault from the Bitwarden web UI (Tools → Export vault).
2. `sudo ./scripts/wipe.sh --yes-i-know --wipe-all`.
3. Copy the new template (`.env.example.<new-db>`), edit, run `install.sh`.
4. Re-import the vault.

For a single-owner installation this takes a few minutes; the export/import path is the only one supported.

### Upgrading from a pre-multi-DB version

Your existing `.env` keeps working as-is — it is sqlite-mode by default and the variable names did not change. The old `.env.example` was replaced by three per-DB templates; diff against `.env.example.sqlite` if you want to see new optional knobs. Existing encrypted backups continue to restore correctly via the legacy-format fallback in `restore.sh`.
```

- [ ] **Step 5: Add `wipe.sh` to the scripts table**

Find the table:

```markdown
| `scripts/update.sh` | Pull current `:beta` and recreate; saves rollback digest | Yes |
```

Append after that row:

```markdown
| `scripts/wipe.sh --yes-i-know [--wipe-all]` | Stop containers, remove volumes and backup timer; with `--wipe-all` also remove nginx vhost, certbot cert, and `.env`. Backup archives are kept. | DESTRUCTIVE |
```

- [ ] **Step 6: Verify the README parses and renders sensibly**

```bash
# Make sure the file is valid UTF-8 and the headings/tables look right.
grep -nE '^(##|###) ' README.md
```

Expected: shows the section ordering — `## Quick start` → `## Choosing a database mode` → `### Switching modes` → `### Upgrading from a pre-multi-DB version` → `## Reference` → `## Scripts reference`.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
README: document multi-DB templates, wipe.sh, and switching modes

Quick start now picks one of three .env.example.<db> templates.
New "Choosing a database mode" section gives a comparison table
and explains the export/wipe/import path for switching modes.
"Upgrading from a pre-multi-DB version" reassures existing users
that their .env keeps working and old backups still restore via
the legacy-format fallback.
EOF
)"
```

---

## Self-review

**Spec coverage**
- §1 Goal/contract → Tasks 2 (templates), 4 (install.sh), 5 (backup.sh), 6 (restore.sh) ✓
- §2 File layout → matches Tasks 1–8 ✓
- §3 docker-compose.yml → Task 3 ✓
- §4 env templates + _lib.sh → Tasks 1, 2 ✓
- §5 install.sh → Task 4; backup.sh → Task 5; restore.sh → Task 6; wipe.sh → Task 7 ✓
- §6 README → Task 8 ✓
- §7 verification plan → not in scope of this plan (manual VPS smoke); each task has its own local validation ✓
- §8 risks → no implementation work needed; documented in spec ✓

**Placeholder scan:** every code block has full content. No "TBD", "TODO", "implement later", or "similar to Task N". All commands have expected output.

**Type/symbol consistency:**
- `db_provider`, `ensure_pass_file`, `wait_db_healthy`: defined in Task 1, called in Tasks 4, 5, 6, 7 with matching signatures ✓
- `BACKUP_DIR`, `PASS_FILE`, `RETENTION_DAYS`: defined in Task 1, used in Tasks 5, 6, 7 ✓
- `BW_DB_PROVIDER` value `postgresql` (not `postgres`): consistent across env templates, compose profile name, install.sh validation, backup/restore branches, wipe.sh `--profile postgresql` ✓
- Container names `bitwarden-postgres` / `bitwarden-mysql`: defined in Task 3 compose, referenced in Task 1 `wait_db_healthy` ✓
- Archive layout (`PROVIDER`, `bitwarden_data.tgz`, `dump.sql.gz`): produced in Task 5, consumed in Task 6 ✓

No issues found.
