# Bitwarden multi-DB env support — design

Status: approved (brainstorm 2026-05-04)
Owner: bau
Predecessor: `2026-05-02-bitwarden-vps-setup-design.md`

## 1. Goal and contract

Add a second and third database mode (PostgreSQL, MySQL) to the existing
single-mode (SQLite) Bitwarden setup, without breaking installations that
already run on SQLite.

User-visible contract:

1. Before running `install.sh`, the user picks a mode by copying one of three
   templates: `cp .env.example.sqlite .env` (or `.postgres`, or `.mysql`).
2. The `.env` file carries `BW_DB_PROVIDER` ∈ {`sqlite`, `postgresql`,
   `mysql`}; this single variable also names the docker-compose profile to
   activate.
3. `install.sh`, `backup.sh`, and `restore.sh` read `.env`, branch on the
   provider, and do the right thing.
4. `update.sh` is unchanged (it operates on the bitwarden image, not the DB).

Out of scope (explicitly rejected during brainstorm):

- MSSQL.
- External / managed Postgres or MySQL. Both run in-compose only.
- Cross-mode data migration (SQLite ↔ Postgres ↔ MySQL). Wipe and re-install
  is the supported path.

Backwards compatibility:

- Existing `.env` files are not invalidated. Variable names are unchanged.
  The default mode is still SQLite.
- The aggregate `.env.example` is removed and replaced by three per-DB
  templates; `.env` itself is in `.gitignore`, so working installations are
  unaffected.

## 2. File layout

New files:

```
.env.example.sqlite        SQLite template (≈ current .env.example)
.env.example.postgres      PostgreSQL template
.env.example.mysql         MySQL template
scripts/wipe.sh            Stop and clean (two modes: default / --wipe-all)
```

Modified files:

```
.env.example               REMOVED (superseded by the three templates)
docker-compose.yml         Adds postgres + mysql services under profiles
scripts/install.sh         Reads BW_DB_PROVIDER, picks --profile
scripts/backup.sh          Branches on provider; new structured archive with PROVIDER manifest
scripts/restore.sh         Reads PROVIDER manifest; rejects cross-mode; falls back to legacy format
scripts/_lib.sh            Adds `db_provider()`, `ensure_pass_file()`, `wait_db_healthy()`, BACKUP_DIR/PASS_FILE/RETENTION_DAYS constants
README.md                  New "Choosing a database mode" section + wipe.sh
```

Untouched: `scripts/update.sh`, `scripts/bootstrap.sh`, `scripts/lockdown.sh`,
`nginx/`, `systemd/` (the existing backup timer keeps working as-is — the
backup.sh internals decide how to dump).

## 3. docker-compose.yml

The bitwarden service is unprofiled (always starts). Postgres and MySQL each
sit behind a profile whose name equals the corresponding `BW_DB_PROVIDER`
value, so `install.sh` can pass `--profile "$BW_DB_PROVIDER"` directly.

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

Key decisions:

- `profiles` value matches `BW_DB_PROVIDER` so the install script can pass
  it through verbatim.
- `depends_on … required: false` lets the unprofiled bitwarden service
  reference profile-gated dependencies without compose erroring when those
  services are inactive.
- DB ports are not published — bitwarden reaches them by service name on
  the default compose network.
- `MYSQL_RANDOM_ROOT_PASSWORD: "yes"` avoids the empty-root-password
  default; bitwarden uses its own non-root user.
- `postgres_data` / `mysql_data` are declared even when their profile is
  inactive. compose only materializes a volume when something mounts it,
  but declaring it up front simplifies the wipe path.
- `${BW_DB_SERVER:-}` (and friends) prevent compose from erroring on
  unset variables in SQLite mode where these keys are absent from `.env`.

## 4. env templates

All three share the head (domain, email, installation creds, bind port,
registration). They differ only in the DB block.

`.env.example.sqlite`:

```bash
# DB mode: SQLite. Lives inside the bitwarden_data volume.
# Simplest mode — no separate database container.
BW_DOMAIN=example.com
ADMIN_EMAIL=you@example.tld
BW_INSTALLATION_ID=
BW_INSTALLATION_KEY=
BW_BIND_PORT=8082
BW_DISABLE_REGISTRATION=false

BW_DB_PROVIDER=sqlite
```

`.env.example.postgres`:

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

`.env.example.mysql`:

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

Decisions:

- `BW_DB_PASSWORD` ships empty. `install.sh` validates and fails fast if it
  is empty in postgres/mysql modes. Generating it inside `install.sh` was
  considered and rejected — mutating the user's `.env` is unfriendly to
  git diffs and idempotence checks.
- `BW_DB_SERVER` equals the compose service name. The comment explicitly
  says "do not change" — switching to an external host is a different
  scope (rejected during brainstorm).
- DB and username are both literally `bitwarden`. No reason to vary.
- `BW_DB_PORT` is the standard port within the docker network; it is not
  published to the host.

`scripts/_lib.sh` additions — single source of truth for shared concerns
that today are duplicated across backup.sh / restore.sh:

```bash
# Constants previously hard-coded in backup.sh
BACKUP_DIR=/var/backups/bitwarden
PASS_FILE=/root/.bitwarden-backup-pass
RETENTION_DAYS=7

db_provider() {
  local p="${BW_DB_PROVIDER:-}"
  case "$p" in
    sqlite|postgresql|mysql) echo "$p" ;;
    "")  die "BW_DB_PROVIDER not set in .env" ;;
    *)   die "Invalid BW_DB_PROVIDER='$p' (expected: sqlite|postgresql|mysql)" ;;
  esac
}

# Generate the encryption pass file on first call; idempotent.
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
wait_db_healthy() {
  local svc="$1" name
  case "$svc" in
    postgresql) name=bitwarden-postgres ;;
    mysql)      name=bitwarden-mysql ;;
    *) die "wait_db_healthy: unknown service $svc" ;;
  esac
  for _ in $(seq 1 60); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo none)" = "healthy" ] && return 0
    sleep 2
  done
  die "$name did not become healthy in 120s"
}
```

`load_env()` is also extended to validate `BW_DB_PROVIDER` and (for
non-sqlite) `BW_DB_PASSWORD` / `BW_DB_USERNAME` / `BW_DB_DATABASE` /
`BW_DB_SERVER` so all scripts inherit the same fail-fast contract.

## 5. Scripts

### install.sh

The current happy path (`docker compose up -d`) becomes:

```bash
provider="$(db_provider)"

if [[ "$provider" != "sqlite" ]]; then
  [[ -n "${BW_DB_PASSWORD:-}" ]] || die "BW_DB_PASSWORD must be set for $provider"
fi

if [[ "$provider" == "sqlite" ]]; then
  docker compose up -d
else
  docker compose --profile "$provider" up -d
fi
```

Everything else (nginx vhost render, certbot, systemd timer) is unchanged.

### backup.sh

Conventions inherited from the current script (kept verbatim):

- Output directory: `/var/backups/bitwarden`.
- Encryption: `openssl enc -aes-256-cbc -pbkdf2 -iter 200000` with
  `-pass file:/root/.bitwarden-backup-pass`. The pass file is auto-generated
  on first run and printed to stderr exactly once.
- Final filename: `${TS}.tar.gz.enc`.
- Retention: prune `.tar.gz.enc` older than `RETENTION_DAYS`.
- For SQLite mode: keep the existing pattern — `sqlite3 .backup` inside
  the bitwarden container before snapshotting the volume, ensuring an
  atomic copy of `vault.db`.

The change is the inner archive structure. Today the encrypted blob is a
plain `tar.gz` of `bitwarden_data` contents. New format: a `tar.gz` whose
top level always contains a `PROVIDER` manifest plus a `bitwarden_data.tgz`,
and (for non-SQLite) a `dump.sql.gz`:

```
${TS}.tar.gz.enc  ──openssl-decrypt──>  ${TS}.tar.gz
                                          ├── PROVIDER             # "sqlite" | "postgresql" | "mysql"
                                          ├── bitwarden_data.tgz   # tar.gz of bitwarden_data volume
                                          └── dump.sql.gz          # only for postgres/mysql
```

Sketch:

```bash
provider="$(db_provider)"
ensure_pass_file   # existing logic, factored into _lib.sh
workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT
TS="$(date -u +%Y-%m-%d-%H%M)"
RAW="$BACKUP_DIR/${TS}.tar.gz"; ENC="${RAW}.enc"

# 1. Per-mode pre-step
if [[ "$provider" == "sqlite" ]] && docker ps --format '{{.Names}}' | grep -qx bitwarden; then
  docker compose exec -T bitwarden \
    sh -c 'sqlite3 /etc/bitwarden/vault.db ".backup /etc/bitwarden/vault.db.bak"' \
    || die "sqlite atomic backup failed"
fi

# 2. Snapshot bitwarden_data volume
docker run --rm -v bitwarden_data:/src:ro -v "$workdir:/dst" alpine \
  tar czf /dst/bitwarden_data.tgz -C /src . \
  || die "tar of bitwarden_data failed"

# 3. DB dump (Postgres / MySQL only)
case "$provider" in
  postgresql)
    docker compose exec -T postgres pg_dump -U "$BW_DB_USERNAME" "$BW_DB_DATABASE" \
      | gzip > "$workdir/dump.sql.gz" \
      || die "pg_dump failed"
    ;;
  mysql)
    docker compose exec -T mysql mysqldump --single-transaction \
      -u "$BW_DB_USERNAME" -p"$BW_DB_PASSWORD" "$BW_DB_DATABASE" \
      | gzip > "$workdir/dump.sql.gz" \
      || die "mysqldump failed"
    ;;
esac

# 4. Manifest + bundle + encrypt
echo "$provider" > "$workdir/PROVIDER"
tar -C "$workdir" -czf "$RAW" .
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$RAW" -out "$ENC" -pass "file:$PASS_FILE" || die "encryption failed"
rm -f "$RAW"

# 5. SQLite cleanup of the temp .bak
if [[ "$provider" == "sqlite" ]] && docker ps --format '{{.Names}}' | grep -qx bitwarden; then
  docker compose exec -T bitwarden rm -f /etc/bitwarden/vault.db.bak || true
fi

# 6. Rotate (existing logic)
find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz.enc' -mtime "+$RETENTION_DAYS" -print -delete
```

`set -euo pipefail` (already at top of `_lib.sh`) makes the `pg_dump | gzip`
and `mysqldump | gzip` pipelines fail-fast if the dumper errors mid-stream
— silent partial dumps would be a correctness bug.

### restore.sh

```bash
require_root "$@"
require_repo_root

ARCHIVE="${1:-}"
CONFIRM="${2:-}"
[ -n "$ARCHIVE" ] || die "usage: $0 <archive.tar.gz.enc> --yes-i-know"
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
[ "$CONFIRM" = "--yes-i-know" ] || die "refusing to wipe volume without --yes-i-know flag"

cur_provider="$(db_provider)"
workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT

# Decrypt to a tar.gz, extract into workdir
TMP="$workdir/archive.tar.gz"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$ARCHIVE" -out "$TMP" -pass "file:$PASS_FILE" || die "decryption failed"
tar -xzf "$TMP" -C "$workdir"
rm -f "$TMP"

# Detect format: new archives have a PROVIDER manifest at the top level
if [[ -f "$workdir/PROVIDER" ]]; then
  src_provider="$(cat "$workdir/PROVIDER")"
  data_tgz="$workdir/bitwarden_data.tgz"
else
  # Legacy archive: pre-multi-DB format = plain tar.gz of bitwarden_data
  log "Legacy archive format detected; assuming sqlite"
  src_provider="sqlite"
  data_tgz=""   # contents are already extracted into $workdir
fi

[[ "$src_provider" == "$cur_provider" ]] || die \
  "Archive was created in '$src_provider' mode but current .env is '$cur_provider'. Cross-mode restore is not supported."

# Stop and recreate bitwarden_data volume
docker compose --profile postgresql --profile mysql down
docker volume rm bitwarden_data >/dev/null 2>&1 || true
docker volume create bitwarden_data >/dev/null

if [[ -n "$data_tgz" ]]; then
  # New format: unpack bitwarden_data.tgz into volume
  docker run --rm -v bitwarden_data:/dst -v "$data_tgz:/in.tgz:ro" alpine \
    tar xzf /in.tgz -C /dst || die "unpack of bitwarden_data failed"
else
  # Legacy: $workdir IS the volume contents
  docker run --rm -v bitwarden_data:/dst -v "$workdir:/in:ro" alpine \
    sh -c 'cp -a /in/. /dst/' || die "legacy unpack failed"
fi

# Bring services back up before restoring DB dump
if [[ "$cur_provider" == "sqlite" ]]; then
  docker compose up -d
else
  docker compose --profile "$cur_provider" up -d
  # Wait for DB healthcheck so psql/mysql can connect
  wait_db_healthy "$cur_provider"
  case "$cur_provider" in
    postgresql)
      gunzip -c "$workdir/dump.sql.gz" \
        | docker compose exec -T postgres \
            psql -U "$BW_DB_USERNAME" -d "$BW_DB_DATABASE" \
        || die "psql restore failed"
      ;;
    mysql)
      gunzip -c "$workdir/dump.sql.gz" \
        | docker compose exec -T mysql \
            mysql -u "$BW_DB_USERNAME" -p"$BW_DB_PASSWORD" "$BW_DB_DATABASE" \
        || die "mysql restore failed"
      ;;
  esac
  # Restart bitwarden to pick up the freshly-loaded DB
  docker compose --profile "$cur_provider" restart bitwarden
fi
```

Cross-mode mismatch is a hard error: a Postgres dump cannot be loaded into
a SQLite installation, and silently corrupting state is worse than
refusing to run.

Legacy SQLite archives (pre-multi-DB) remain restorable — restore.sh
detects the absence of the `PROVIDER` manifest and treats them as
sqlite-mode volume tarballs.

### wipe.sh (new)

```bash
#!/usr/bin/env bash
# scripts/wipe.sh — stop and clean Bitwarden installation
# Usage: sudo ./scripts/wipe.sh --yes-i-know [--wipe-all]

# shellcheck source=scripts/_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root

# Argument parsing — --yes-i-know is mandatory, --wipe-all is optional.
# Pattern matches the inline check used by restore.sh today (no helper exists).
SAW_CONFIRM=false
WIPE_ALL=false
for arg in "$@"; do
  case "$arg" in
    --yes-i-know) SAW_CONFIRM=true ;;
    --wipe-all)   WIPE_ALL=true ;;
  esac
done
"$SAW_CONFIRM" || die "refusing to wipe without --yes-i-know flag"

# Stop and remove containers + volumes for ALL profiles, regardless of
# which mode is currently active. compose tolerates inactive profiles —
# the volumes themselves are declared at compose-level so they get
# removed even if their profile-gated service was never started.
docker compose --profile postgresql --profile mysql down --volumes --remove-orphans

if systemctl list-unit-files | grep -q bitwarden-backup.timer; then
  systemctl disable --now bitwarden-backup.timer
  rm -f /etc/systemd/system/bitwarden-backup.{service,timer}
  systemctl daemon-reload
fi

if "$WIPE_ALL"; then
  rm -f /etc/nginx/sites-enabled/bitwarden.conf
  rm -f /etc/nginx/sites-available/bitwarden.conf
  systemctl reload nginx 2>/dev/null || true

  # Read domain from .env BEFORE deleting it
  if [[ -f "$REPO_ROOT/.env" ]]; then
    domain="$(grep -E '^BW_DOMAIN=' "$REPO_ROOT/.env" | cut -d= -f2-)"
    [[ -n "$domain" ]] && certbot delete --cert-name "$domain" -n || true
  fi

  rm -f "$REPO_ROOT/.env"
fi

log "Wipe complete (wipe-all=$WIPE_ALL)."
```

`/var/backups/bitwarden` is intentionally NOT removed even with
`--wipe-all` — the backup archives are encrypted, small, and are the
user's last line of defence against an accidental wipe.

## 6. README updates

The Quick start section is rewritten to introduce the three-template
choice. A new "Choosing a database mode" section follows:

| Mode | When to use | Backup size | Resource overhead |
|---|---|---|---|
| sqlite | Single owner, ≤10 users | small | none (file in volume) |
| postgresql | Multi-user, ops experience | medium | +1 container, ~50 MB RAM idle |
| mysql | Same as postgres, MySQL preferred | medium | +1 container, ~400 MB RAM idle |

The "Scripts reference" table gains:

| Script | Purpose | Idempotent? |
|---|---|---|
| `scripts/wipe.sh --yes-i-know [--wipe-all]` | Stop containers, remove volumes and backup timer; with `--wipe-all` also remove nginx vhost, certbot cert, and `.env` | DESTRUCTIVE |

A migration note for users updating from the pre-multi-DB version makes
explicit that their existing `.env` keeps working, points them to
`.env.example.sqlite` for the new optional knobs, and reiterates that
cross-mode migration is unsupported.

## 7. Verification plan

Manual smoke after implementation:

1. **SQLite happy path** — copy `.env.example.sqlite`, fill, run
   `install.sh`, register owner, run `lockdown.sh`. Should match current
   behaviour bit-for-bit.
2. **PostgreSQL happy path** — copy `.env.example.postgres`, generate a
   password, run `install.sh`. `docker compose ps` shows two services;
   bitwarden is healthy and reachable; `docker compose exec postgres
   psql -U bitwarden -d bitwarden -c '\dt'` lists Bitwarden tables.
3. **MySQL happy path** — analogous, with `mysql -u bitwarden -p… -e
   'SHOW TABLES'`.
4. **Backup/restore round-trip** — for each of the three modes: create a
   test vault item, run `backup.sh`, run `wipe.sh --yes-i-know`, run
   `install.sh`, run `restore.sh <archive>`, confirm the item is back.
5. **Cross-mode restore is rejected** — feeding a postgres archive into a
   sqlite-mode installation fails fast with a clear error message.
6. **Validation of `.env`** — `BW_DB_PROVIDER=foo` causes `install.sh` to
   fail; an empty `BW_DB_PASSWORD` in postgres/mysql modes causes
   `install.sh` to fail.
7. **`wipe-all` cleans everything** — after `wipe.sh --yes-i-know
   --wipe-all`: no project containers, `docker volume ls` shows no
   `bitwarden|postgres|mysql` volumes for the project, no
   `bitwarden-backup.timer`, no nginx vhost, no certbot cert, no `.env`.
   `/var/backups/bitwarden` archives remain on disk.
8. **Legacy archive restore** — point `restore.sh` at a pre-multi-DB
   archive (plain volume tarball, no PROVIDER manifest). It should detect
   the legacy format, treat it as sqlite, and restore successfully into
   a fresh sqlite-mode installation.

## 8. Known risks and follow-ups

- Bitwarden's image tag is pinned (`lite:2026.4.0`). If a future release
  changes the Postgres or MySQL schema, this design has nothing to say
  about it — schema migrations are owned by the upstream image.
- `--wipe-all` followed by re-install can hit Let's Encrypt rate limits
  (5 certificates per registered domain per week). Not flagged in README;
  documented upstream by Let's Encrypt.
- Cross-mode migration is intentionally unsupported. If a user with a
  populated SQLite vault later wants to switch to Postgres, the path is
  "export from UI → wipe → reinstall in postgres mode → import in UI",
  which is acceptable for a single-owner pet installation.
- Backup archive format changes (new top-level `PROVIDER` manifest plus
  separated `bitwarden_data.tgz` and optional `dump.sql.gz`). New
  archives cannot be restored by the previous version of `restore.sh`.
  Old archives can still be restored by the new `restore.sh` via the
  legacy-format fallback. The change is one-way; this is acceptable
  because backups are read by this repo's tooling, not third parties.
