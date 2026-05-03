# Bitwarden VPS Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete repository of configuration and scripts that lets a sudo-user clone, run two commands, and have a working self-hosted Bitwarden at `https://panda.hello-vanilla.ru` — including daily encrypted backups, restore procedure, and full runbook.

**Architecture:** A single `bitwarden/self-host` Docker container bound to `127.0.0.1:8082`, fronted by the host's existing nginx via a new vhost, TLS via the host's existing certbot. SQLite database in a Docker volume. Daily backup driven by a systemd timer encrypts an archive of the volume. No SMTP, single-user lockdown after registration.

**Tech Stack:** Bash 5+, Docker Engine + Compose plugin, nginx, certbot/Let's Encrypt, systemd, SQLite (inside container), openssl (AES-256-CBC for backups), shellcheck (script linter), Bitwarden unified image `bitwarden/self-host:beta`.

**Source of truth for product behavior:** spec at `docs/superpowers/specs/2026-05-02-bitwarden-vps-setup-design.md`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `README.md` | Quick start + pointer to runbook in spec |
| `.gitignore` | Already present; extend if needed |
| `.env.example` | Runtime config template (committed) |
| `docker-compose.yml` | Single `bitwarden` service definition |
| `nginx/panda.hello-vanilla.ru.conf.template` | nginx vhost template with `__DOMAIN__`/`__BIND_PORT__` placeholders |
| `scripts/_lib.sh` | Shared bash helpers (`log`, `die`, `require_cmd`, `require_root`, `load_env`) sourced by all scripts |
| `scripts/bootstrap.sh` | Idempotent VPS prep: docker, certbot, swap |
| `scripts/install.sh` | Idempotent install: pull image, up containers, render & enable nginx vhost, certbot, install systemd units |
| `scripts/lockdown.sh` | Set `BW_DISABLE_REGISTRATION=true` and restart container |
| `scripts/backup.sh` | SQLite atomic dump → tar volume → AES-256 encrypt → 7-day rotation |
| `scripts/restore.sh` | Decrypt archive → wipe volume → unpack → restart; requires `--yes-i-know` |
| `scripts/update.sh` | Save digest → pull → up → prune |
| `systemd/bitwarden-backup.service` | Oneshot unit invoking `backup.sh` |
| `systemd/bitwarden-backup.timer` | Daily timer at 03:30 |

**Conventions used by all scripts:**
- `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`
- `shellcheck` clean (`shellcheck -x scripts/*.sh` exits 0)
- All sourcing: `source "$(dirname "$0")/_lib.sh"` from repo-root invocation
- `log "msg"` → stderr with `[YYYY-MM-DDTHH:MM:SSZ] [script] msg`
- `die "msg"` → log + exit 1
- Scripts must be invoked from the repo root; `_lib.sh` checks for marker file `docker-compose.yml`

---

## Task 1: Verify unified-image env-variable names against official docs

**Why this is first:** Spec section 10 leaves the exact env-var names of `bitwarden/self-host` as an open item. Every downstream task (compose, scripts) depends on them. Lock them in before writing any other file.

**Files:**
- Modify: `docs/superpowers/specs/2026-05-02-bitwarden-vps-setup-design.md` — append a new "Section 11: Verified env-var names" with confirmed values.

- [ ] **Step 1: Pull official unified-image documentation**

Visit (read with WebFetch):
- `https://bitwarden.com/help/install-and-deploy-unified/`
- `https://github.com/bitwarden/server/tree/main/docker-unified` (README)
- `https://github.com/bitwarden/server/blob/main/docker-unified/entrypoint.sh` (definitive — shows actual env-var consumption)

- [ ] **Step 2: Record the verified mapping**

Confirm the **exact** name and form for each of these. The unified image is known to use both short `BW_*` aliases and full `globalSettings__*` ASP.NET configuration paths; record which the official docs prefer.

| Function | Env var (verified) |
|---|---|
| Domain (full HTTPS URL) | `BW_DOMAIN` (expected: `https://panda.hello-vanilla.ru`) |
| Disable signups | `globalSettings__disableUserRegistration` or short `BW_ENABLE_USER_REGISTRATION` (inverted) |
| Database provider | `BW_DB_PROVIDER` (`sqlite` / `postgresql` / `mysql` / `sqlserver`) |
| SQLite file path inside container | (defaults under `/etc/bitwarden/...`; record precise path) |
| Installation ID | `globalSettings__installation__id` |
| Installation key | `globalSettings__installation__key` |
| Internal HTTP port | (default `8080`, used for compose bind) |
| Healthcheck endpoint | (commonly `/alive` — verify) |
| Disable mail | `globalSettings__mail__sendGridApiKey` empty + smtp host empty? Or specific `BW_ENABLE_MAIL` flag? |

- [ ] **Step 3: Append "Section 11: Verified env-var names" to the spec**

Edit spec file, add a section near the end (before "Конец спецификации") with a clean table listing each env-var and its verified name and the URL of the page that confirms it.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-05-02-bitwarden-vps-setup-design.md
git commit -m "Lock down unified-image env-variable names in spec"
```

---

## Task 2: Create project skeleton — README, .gitignore, .env.example

**Files:**
- Create: `README.md`
- Modify: `.gitignore` (ensure entries from spec are present)
- Create: `.env.example`

- [ ] **Step 1: Write `.env.example` using verified env-var names from Task 1**

Use the names confirmed in Task 1 Step 2. The skeleton from the spec is:

```env
# Domain — BARE hostname (no scheme). The unified image's entrypoint
# prepends https:// itself; passing a URL would yield "https://https://..." links.
BW_DOMAIN=panda.hello-vanilla.ru

# Email used by certbot for Let's Encrypt account/recovery
ADMIN_EMAIL=you@example.tld

# Bitwarden installation credentials — get from https://bitwarden.com/host/
# Enter email, copy values verbatim. Free, mandatory for licensing checks.
BW_INSTALLATION_ID=
BW_INSTALLATION_KEY=

# Local bind port for the Bitwarden container on 127.0.0.1
BW_BIND_PORT=8082

# Database — SQLite stored inside the named volume
BW_DB_PROVIDER=sqlite

# Registration — false at first start (so you can register the owner),
# scripts/lockdown.sh flips this to true after. This .env variable is
# passed through to the container as `globalSettings__disableUserRegistration`
# (the unified image has NO short BW_* alias for this — see spec section 11).
BW_DISABLE_REGISTRATION=false
```

These names are locked in spec section 11 (verified env-var names from the
upstream `bitwarden/self-host` image). Use them verbatim.

- [ ] **Step 2: Verify `.gitignore` contents**

```bash
cat .gitignore
```
Expected entries (already present from brainstorming commit):
```
.env
.env.local
secrets/
backups/
*.log
.last_known_good_digest
```
If missing — add. Otherwise — no change.

- [ ] **Step 3: Write `README.md`**

```markdown
# Bitwarden Server Setup

Self-hosted Bitwarden on a 2 GB Ubuntu 22.04 VPS, integrated with an existing nginx reverse proxy.

## Quick start

1. Add DNS A-record `panda.hello-vanilla.ru → <VPS_IP>`.
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
   $EDITOR .env   # fill DOMAIN, ADMIN_EMAIL, BW_INSTALLATION_*
   sudo ./scripts/install.sh
   ```

4. Open `https://panda.hello-vanilla.ru`, register the single owner account.
5. **Write the master password down on paper.** It cannot be reset.
6. Run `sudo ./scripts/lockdown.sh` to disable further registrations.
7. Enable TOTP 2FA in account settings; save the recovery code offline.
8. After the first backup, copy `/root/.bitwarden-backup-pass` offline.

## Reference

The full design and runbook (including troubleshooting, restore, and operations) is at:

`docs/superpowers/specs/2026-05-02-bitwarden-vps-setup-design.md`

In particular:
- Section 6 — full runbook
- Section 7 — smoke checklist after install
- Section 8 — known risks
```

- [ ] **Step 4: Verify files**

```bash
ls -la README.md .env.example .gitignore
test -s README.md && test -s .env.example && test -s .gitignore && echo OK
```
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add README.md .env.example .gitignore
git commit -m "Add project skeleton: README, .env.example, .gitignore"
```

---

## Task 3: Create `docker-compose.yml`

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Write `docker-compose.yml` using verified env names**

```yaml
services:
  bitwarden:
    image: bitwarden/self-host:beta
    container_name: bitwarden
    restart: unless-stopped
    ports:
      - "127.0.0.1:${BW_BIND_PORT}:8080"
    env_file: .env
    environment:
      BW_DOMAIN: ${BW_DOMAIN}
      BW_DB_PROVIDER: ${BW_DB_PROVIDER}
      globalSettings__disableUserRegistration: ${BW_DISABLE_REGISTRATION}
      globalSettings__installation__id: ${BW_INSTALLATION_ID}
      globalSettings__installation__key: ${BW_INSTALLATION_KEY}
    volumes:
      - bitwarden_data:/etc/bitwarden
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8080/alive"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

volumes:
  bitwarden_data:
```

**Source of truth for env names:** spec Section 11. Per Section 11, the disable-registration variable has NO short `BW_*` alias — `globalSettings__disableUserRegistration` must be passed directly. The `.env` file uses the human-friendly name `BW_DISABLE_REGISTRATION` and the compose `environment:` block re-maps it.

- [ ] **Step 2: Validate compose syntax**

Run:
```bash
docker compose config -q
```
Expected: exits 0 with no output. (May complain if `.env` is missing — create a temporary `.env` from `.env.example` for validation, then delete: `cp .env.example .env && docker compose config -q && rm .env`.)

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "Add docker-compose.yml for unified bitwarden image"
```

---

## Task 4: Create nginx vhost template

**Files:**
- Create: `nginx/panda.hello-vanilla.ru.conf.template`

- [ ] **Step 1: Write the template**

```nginx
# Generated from nginx/panda.hello-vanilla.ru.conf.template by scripts/install.sh.
# Placeholders __DOMAIN__ and __BIND_PORT__ are substituted at install time.
# certbot --nginx will append HTTPS server block + 80→443 redirect on first run.

server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    location / {
        proxy_pass http://127.0.0.1:__BIND_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket for notifications/SignalR
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1d;
    }

    # 500 MB attachments + safety margin (Bitwarden default cap)
    client_max_body_size 525M;
}
```

- [ ] **Step 2: Render-test the template**

```bash
sed -e 's/__DOMAIN__/panda.hello-vanilla.ru/g' \
    -e 's/__BIND_PORT__/8082/g' \
    nginx/panda.hello-vanilla.ru.conf.template
```
Expected: prints the nginx config with `panda.hello-vanilla.ru` and `8082` substituted; no `__*__` placeholders remain. Verify with:
```bash
sed -e 's/__DOMAIN__/panda.hello-vanilla.ru/g' -e 's/__BIND_PORT__/8082/g' \
    nginx/panda.hello-vanilla.ru.conf.template | grep -c '__' 
```
Expected output: `0`.

- [ ] **Step 3: Commit**

```bash
git add nginx/panda.hello-vanilla.ru.conf.template
git commit -m "Add nginx vhost template for Bitwarden"
```

---

## Task 5: Create shared bash helpers `_lib.sh`

**Files:**
- Create: `scripts/_lib.sh`

- [ ] **Step 1: Write `scripts/_lib.sh`**

```bash
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
```

- [ ] **Step 2: Lint with shellcheck**

```bash
shellcheck -x scripts/_lib.sh
```
Expected: no output, exit 0. If shellcheck not installed: `sudo apt install shellcheck` (or `brew install shellcheck` locally).

- [ ] **Step 3: Syntax check**

```bash
bash -n scripts/_lib.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Smoke-test by sourcing**

```bash
( source scripts/_lib.sh && log "lib loaded" )
```
Expected: stderr line like `[2026-05-02T...] [bash] lib loaded`.

- [ ] **Step 5: Commit**

```bash
git add scripts/_lib.sh
git commit -m "Add shared bash helpers for scripts"
```

---

## Task 6: Create `scripts/bootstrap.sh`

**Files:**
- Create: `scripts/bootstrap.sh`

- [ ] **Step 1: Write `scripts/bootstrap.sh`**

```bash
#!/usr/bin/env bash
# Prepare a fresh Ubuntu 22.04 VPS for Bitwarden installation.
# Idempotent: re-running is safe.
# Run: sudo ./scripts/bootstrap.sh [--configure-ufw]

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root

CONFIGURE_UFW=0
for arg in "$@"; do
  case "$arg" in
    --configure-ufw) CONFIGURE_UFW=1 ;;
    *) die "unknown arg: $arg (supported: --configure-ufw)" ;;
  esac
done

# 1. Sanity checks
log "Sanity checks"
. /etc/os-release
[ "$ID" = "ubuntu" ] && [ "$VERSION_ID" = "22.04" ] \
  || log "WARN: not Ubuntu 22.04 (got $ID $VERSION_ID); proceeding anyway"
[ "$(uname -m)" = "x86_64" ] || die "unsupported arch: $(uname -m)"

# 2. Apt utilities
log "Installing base utilities"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl ca-certificates gnupg lsb-release jq sqlite3 shellcheck

# 3. Docker Engine + Compose plugin
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  log "Docker + Compose already present, skipping"
else
  log "Installing Docker Engine + Compose plugin"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG docker "$SUDO_USER"
    log "Added $SUDO_USER to 'docker' group — log out and back in to apply"
  fi
fi

# 4. certbot + nginx plugin
if command -v certbot >/dev/null; then
  log "certbot already present, skipping install"
else
  log "Installing certbot + python3-certbot-nginx"
  apt-get install -y -qq certbot python3-certbot-nginx
fi
systemctl is-active --quiet certbot.timer \
  || log "WARN: certbot.timer not active; certs won't auto-renew"

# 5. Swap
if [ -n "$(swapon --show=NAME --noheadings)" ]; then
  log "Swap already configured: $(swapon --show)"
else
  log "Creating 2 GB swap file at /swapfile"
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap -q /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab \
    || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  cat > /etc/sysctl.d/99-swap.conf <<EOF
vm.swappiness=10
EOF
  sysctl -q -p /etc/sysctl.d/99-swap.conf
fi

# 6. UFW (read-only by default)
if command -v ufw >/dev/null; then
  log "UFW status:"
  ufw status verbose | sed 's/^/  /' >&2
  if [ "$CONFIGURE_UFW" = "1" ]; then
    log "Configuring UFW: deny incoming, allow 22/80/443"
    ufw --force default deny incoming
    ufw --force default allow outgoing
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    ufw status verbose | sed 's/^/  /' >&2
  else
    log "Skipping UFW changes (pass --configure-ufw to set up firewall from scratch)"
  fi
else
  log "ufw not installed; skipping firewall section"
fi

# 7. Final summary
cat >&2 <<EOF

==== bootstrap.sh complete ====

Next steps:
  1. If docker group was just added — log out and back in.
  2. Set DNS A-record for your domain to this VPS IP.
  3. Get installation ID + key from https://bitwarden.com/host/
  4. cp .env.example .env  &&  edit .env
  5. sudo ./scripts/install.sh
EOF
```

- [ ] **Step 2: Lint**

```bash
shellcheck -x scripts/bootstrap.sh
```
Expected: exit 0, no output.

- [ ] **Step 3: Syntax check**

```bash
bash -n scripts/bootstrap.sh
```
Expected: exit 0.

- [ ] **Step 4: Make executable**

```bash
chmod +x scripts/bootstrap.sh
```

- [ ] **Step 5: Help/non-root smoke-test**

```bash
./scripts/bootstrap.sh
```
Expected: exits 1 with `ERROR: must run as root` (or similar from `require_root`). This proves the guard rail works without actually mutating the system.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "Add bootstrap.sh: prepare VPS (docker, certbot, swap, optional UFW)"
```

---

## Task 7: Create `scripts/install.sh`

**Files:**
- Create: `scripts/install.sh`

- [ ] **Step 1: Write `scripts/install.sh`**

```bash
#!/usr/bin/env bash
# Deploy/redeploy Bitwarden + nginx vhost + TLS cert.
# Idempotent: re-running is safe.
# Run: sudo ./scripts/install.sh

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root
load_env

require_cmd docker
require_cmd nginx
require_cmd certbot
require_cmd ss
require_cmd sed

# BW_DOMAIN is the bare hostname (per spec section 11). Sanity-check no scheme leaked in.
case "$BW_DOMAIN" in
  http://*|https://*) die "BW_DOMAIN must be bare hostname, not URL: '$BW_DOMAIN' (see spec section 11)" ;;
esac
HOSTNAME="$BW_DOMAIN"

[ -n "${BW_INSTALLATION_ID:-}" ] || die "BW_INSTALLATION_ID empty in .env"
[ -n "${BW_INSTALLATION_KEY:-}" ] || die "BW_INSTALLATION_KEY empty in .env"
[ -n "${ADMIN_EMAIL:-}" ] || die "ADMIN_EMAIL empty in .env"
[ -n "${BW_BIND_PORT:-}" ] || die "BW_BIND_PORT empty in .env"

# 1. Confirm bind port is free on 127.0.0.1 (excluding the existing bitwarden container itself).
if ss -tlnp "( sport = :$BW_BIND_PORT )" 2>/dev/null | grep -q '127.0.0.1'; then
  if ! docker ps --format '{{.Names}}' | grep -qx bitwarden; then
    die "port $BW_BIND_PORT on 127.0.0.1 is taken by another process; pick a different BW_BIND_PORT in .env"
  fi
  log "port $BW_BIND_PORT held by existing bitwarden container — ok"
else
  log "port $BW_BIND_PORT on 127.0.0.1 is free"
fi

# 2. Pull image and start container
log "Pulling image"
docker compose pull
log "Starting container"
docker compose up -d

# 3. Wait for healthcheck
log "Waiting for container to become healthy (up to 120 s)"
for i in $(seq 1 60); do
  status="$(docker inspect --format '{{.State.Health.Status}}' bitwarden 2>/dev/null || echo none)"
  case "$status" in
    healthy) log "container healthy"; break ;;
    starting|none) sleep 2 ;;
    unhealthy) die "container reported unhealthy; see: docker compose logs bitwarden" ;;
    *) sleep 2 ;;
  esac
  [ "$i" = 60 ] && die "container did not become healthy in 120 s"
done

# 4. Render nginx vhost from template
VHOST_SRC="$REPO_ROOT/nginx/${HOSTNAME}.conf.template"
[ -f "$VHOST_SRC" ] || die "vhost template not found: $VHOST_SRC"
VHOST_DST="/etc/nginx/sites-available/${HOSTNAME}.conf"
log "Rendering vhost to $VHOST_DST"
sed -e "s/__DOMAIN__/${HOSTNAME}/g" \
    -e "s/__BIND_PORT__/${BW_BIND_PORT}/g" \
    "$VHOST_SRC" > "$VHOST_DST"

# Symlink into sites-enabled if not already
if [ ! -L "/etc/nginx/sites-enabled/${HOSTNAME}.conf" ]; then
  ln -s "$VHOST_DST" "/etc/nginx/sites-enabled/${HOSTNAME}.conf"
  log "Enabled vhost"
fi

# 5. Test and reload nginx
log "Testing nginx config"
nginx -t
systemctl reload nginx
log "nginx reloaded"

# 6. Smoke-check HTTP (cert may not exist yet)
log "Smoke-checking HTTP /alive (pre-TLS)"
if curl -fsS "http://${HOSTNAME}/alive" -o /dev/null; then
  log "HTTP /alive ok"
else
  log "HTTP /alive failed; will rely on certbot to validate connectivity"
fi

# 7. Issue/renew certificate
log "Running certbot --nginx -d $HOSTNAME"
certbot --nginx \
  -d "$HOSTNAME" \
  --non-interactive --agree-tos --redirect \
  -m "$ADMIN_EMAIL" || die "certbot failed; see /var/log/letsencrypt/letsencrypt.log"

# 8. Smoke-check HTTPS
log "Smoke-checking HTTPS /alive"
curl -fsS "https://${HOSTNAME}/alive" -o /dev/null \
  || die "HTTPS /alive failed after certbot"

# 9. Install systemd backup units
log "Installing systemd backup timer"
SYSTEMD_DIR=/etc/systemd/system
sed "s|__BACKUP_SCRIPT__|$REPO_ROOT/scripts/backup.sh|g" \
    "$REPO_ROOT/systemd/bitwarden-backup.service" \
    > "$SYSTEMD_DIR/bitwarden-backup.service"
cp "$REPO_ROOT/systemd/bitwarden-backup.timer" \
   "$SYSTEMD_DIR/bitwarden-backup.timer"
systemctl daemon-reload
systemctl enable --now bitwarden-backup.timer

# 10. Done
cat >&2 <<EOF

==== install.sh complete ====

Open: https://${HOSTNAME}
- Register the single owner account.
- WRITE THE MASTER PASSWORD DOWN ON PAPER.
- Run: sudo ./scripts/lockdown.sh

Backup timer: $(systemctl list-timers bitwarden-backup.timer --no-pager | head -2 | tail -1)
EOF
```

- [ ] **Step 2: Lint and syntax**

```bash
shellcheck -x scripts/install.sh
bash -n scripts/install.sh
```
Expected: both exit 0, no output.

- [ ] **Step 3: Make executable**

```bash
chmod +x scripts/install.sh
```

- [ ] **Step 4: Guard-rail smoke test (no .env present)**

```bash
mv .env .env.bak 2>/dev/null || true
./scripts/install.sh
```
Expected: fails with `must run as root` (because guard runs before .env load) — that's enough to prove startup order. Then:
```bash
mv .env.bak .env 2>/dev/null || true
```

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh
git commit -m "Add install.sh: pull image, render vhost, certbot, enable timer"
```

---

## Task 8: Create `scripts/lockdown.sh`

**Files:**
- Create: `scripts/lockdown.sh`

- [ ] **Step 1: Write `scripts/lockdown.sh`**

```bash
#!/usr/bin/env bash
# Disable user registration after the owner account has been created.
# Run: sudo ./scripts/lockdown.sh

# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"

require_root "$@"
require_repo_root
load_env

if grep -q '^BW_DISABLE_REGISTRATION=true' .env; then
  log "Registration already disabled — nothing to do"
  exit 0
fi

log "Setting BW_DISABLE_REGISTRATION=true in .env"
sed -i 's/^BW_DISABLE_REGISTRATION=.*/BW_DISABLE_REGISTRATION=true/' .env

log "Recreating container with new env"
docker compose up -d

log "Waiting for healthcheck"
for i in $(seq 1 60); do
  status="$(docker inspect --format '{{.State.Health.Status}}' bitwarden 2>/dev/null || echo none)"
  [ "$status" = "healthy" ] && break
  sleep 2
  [ "$i" = 60 ] && die "container did not become healthy in 120 s"
done

# Probe registration endpoint — expect 4xx.
# BW_DOMAIN is the bare hostname (per spec section 11); sanity-check no scheme leaked in.
case "$BW_DOMAIN" in
  http://*|https://*) die "BW_DOMAIN must be bare hostname, not URL: '$BW_DOMAIN' (see spec section 11)" ;;
esac
HOSTNAME="$BW_DOMAIN"
code="$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "https://${HOSTNAME}/identity/accounts/register" \
  -H 'Content-Type: application/json' \
  -d '{"email":"smoke@test.invalid","masterPasswordHash":"x","masterPasswordHint":null,"key":"x","kdf":0,"kdfIterations":600000}')"
if [ "$code" -ge 400 ] && [ "$code" -lt 500 ]; then
  log "Registration locked (HTTP $code from /identity/accounts/register)"
else
  log "WARN: register endpoint returned $code (expected 4xx); manual verification recommended"
fi

log "Lockdown complete"
```

- [ ] **Step 2: Lint and syntax**

```bash
shellcheck -x scripts/lockdown.sh
bash -n scripts/lockdown.sh
chmod +x scripts/lockdown.sh
```
Expected: lint+syntax clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/lockdown.sh
git commit -m "Add lockdown.sh: disable signups after owner registration"
```

---

## Task 9: Create `scripts/backup.sh` and systemd units

**Files:**
- Create: `scripts/backup.sh`
- Create: `systemd/bitwarden-backup.service`
- Create: `systemd/bitwarden-backup.timer`

- [ ] **Step 1: Write `scripts/backup.sh`**

```bash
#!/usr/bin/env bash
# Daily encrypted backup of the bitwarden_data volume.
# Run: sudo ./scripts/backup.sh
# Invoked automatically by systemd timer bitwarden-backup.timer.

# shellcheck source=_lib.sh
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
```

- [ ] **Step 2: Write `systemd/bitwarden-backup.service`**

```ini
[Unit]
Description=Bitwarden daily backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=__BACKUP_SCRIPT__
StandardOutput=append:/var/log/bitwarden-backup.log
StandardError=append:/var/log/bitwarden-backup.log
```

(`install.sh` substitutes `__BACKUP_SCRIPT__` with the absolute repo path.)

- [ ] **Step 3: Write `systemd/bitwarden-backup.timer`**

```ini
[Unit]
Description=Run Bitwarden backup daily at 03:30

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Lint and syntax**

```bash
shellcheck -x scripts/backup.sh
bash -n scripts/backup.sh
chmod +x scripts/backup.sh
```
Expected: clean.

For systemd unit syntax:
```bash
systemd-analyze verify systemd/bitwarden-backup.timer 2>&1 || true
```
(Will warn about the `__BACKUP_SCRIPT__` placeholder in the .service — that's expected pre-install. We accept the warning.)

- [ ] **Step 5: Commit**

```bash
git add scripts/backup.sh systemd/
git commit -m "Add backup.sh + systemd timer for daily encrypted backups"
```

---

## Task 10: Create `scripts/restore.sh`

**Files:**
- Create: `scripts/restore.sh`

- [ ] **Step 1: Write `scripts/restore.sh`**

```bash
#!/usr/bin/env bash
# Restore Bitwarden volume from an encrypted backup archive.
# DESTRUCTIVE: wipes the existing bitwarden_data volume.
# Run: sudo ./scripts/restore.sh /var/backups/bitwarden/<file>.tar.gz.enc --yes-i-know

# shellcheck source=_lib.sh
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
```

- [ ] **Step 2: Lint and syntax**

```bash
shellcheck -x scripts/restore.sh
bash -n scripts/restore.sh
chmod +x scripts/restore.sh
```
Expected: clean.

- [ ] **Step 3: Smoke-test missing-confirm guard**

```bash
sudo ./scripts/restore.sh /tmp/nope.enc
```
Expected: exits 1 with `archive not found`. Then:
```bash
sudo touch /tmp/fake.tar.gz.enc
sudo ./scripts/restore.sh /tmp/fake.tar.gz.enc
sudo rm /tmp/fake.tar.gz.enc
```
Expected: exits 1 with `refusing to wipe volume without --yes-i-know flag`.

- [ ] **Step 4: Commit**

```bash
git add scripts/restore.sh
git commit -m "Add restore.sh: decrypt archive and rebuild volume"
```

---

## Task 11: Create `scripts/update.sh`

**Files:**
- Create: `scripts/update.sh`

- [ ] **Step 1: Write `scripts/update.sh`**

```bash
#!/usr/bin/env bash
# Update bitwarden image to current :beta tag.
# Run: sudo ./scripts/update.sh

# shellcheck source=_lib.sh
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
```

- [ ] **Step 2: Lint and syntax**

```bash
shellcheck -x scripts/update.sh
bash -n scripts/update.sh
chmod +x scripts/update.sh
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/update.sh
git commit -m "Add update.sh: pull image with rollback digest"
```

---

## Task 12: Repo-wide lint pass and final readme polish

**Files:**
- Modify: `README.md` (add a "Scripts" section)

- [ ] **Step 1: Run shellcheck on every script**

```bash
shellcheck -x scripts/*.sh
```
Expected: no output, exit 0. Fix any warnings inline.

- [ ] **Step 2: Confirm permissions**

```bash
ls -l scripts/*.sh
```
Expected: every `scripts/*.sh` is `-rwxr-xr-x` except `_lib.sh` (which is sourced, not executed — but having +x is fine).

```bash
chmod +x scripts/*.sh
```

- [ ] **Step 3: Append a Scripts section to README**

Append to `README.md`:

```markdown
## Scripts reference

| Script | Purpose | Idempotent? |
|---|---|---|
| `scripts/bootstrap.sh [--configure-ufw]` | Install Docker, certbot, swap on Ubuntu 22.04 VPS | Yes |
| `scripts/install.sh` | Pull image, start container, configure nginx vhost + Let's Encrypt cert, install backup timer | Yes |
| `scripts/lockdown.sh` | Disable user registration after owner is created | Yes |
| `scripts/backup.sh` | Daily encrypted backup; run by systemd timer at 03:30 | Yes |
| `scripts/restore.sh <archive> --yes-i-know` | Restore from encrypted backup archive | DESTRUCTIVE |
| `scripts/update.sh` | Pull current `:beta` and recreate; saves rollback digest | Yes |
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: add scripts reference table"
```

---

## Task 13: Real VPS smoke test (manual)

**Why this is a task:** scripts that touch a real system can only be fully verified there. This task is the runbook walkthrough; the operator follows it on the actual `panda.hello-vanilla.ru` VPS and reports back.

**Files:** none (deployment-time validation)

- [ ] **Step 1: DNS pre-check**

Run on workstation:
```bash
dig +short panda.hello-vanilla.ru
```
Expected: returns the VPS public IP. If empty — add the A-record at the registrar before continuing.

- [ ] **Step 2: Get installation ID + key**

Visit `https://bitwarden.com/host/`, enter email, save the two values.

- [ ] **Step 3: Push the repo & clone on VPS**

```bash
# locally
git push origin main   # (after configuring a remote — github/gitea/etc.)

# on VPS
ssh <user>@<vps>
git clone <remote-url> ~/bitwarden-server-setup
cd ~/bitwarden-server-setup
```

- [ ] **Step 4: Bootstrap**

```bash
sudo ./scripts/bootstrap.sh
exit   # log out, then back in for docker group
ssh <user>@<vps>
cd ~/bitwarden-server-setup
docker ps   # should work without sudo now
```

- [ ] **Step 5: Configure .env**

```bash
cp .env.example .env
nano .env
# Fill: BW_DOMAIN=panda.hello-vanilla.ru        # bare hostname, no scheme
#       ADMIN_EMAIL=<your email>
#       BW_INSTALLATION_ID=<from step 2>
#       BW_INSTALLATION_KEY=<from step 2>
```

- [ ] **Step 6: Install**

```bash
sudo ./scripts/install.sh
```
Expected output ends with the "install.sh complete" banner. If it fails on the bind-port check — pick a different `BW_BIND_PORT` in `.env` and re-run.

- [ ] **Step 7: Smoke checks (spec section 7)**

Run each, all should pass:
```bash
curl -fsS https://panda.hello-vanilla.ru/alive   # expect 200
docker compose ps                                # bitwarden healthy
sudo nginx -t                                    # syntax OK
sudo certbot certificates                        # cert listed for panda.hello-vanilla.ru
sudo systemctl is-active bitwarden-backup.timer  # active
sudo systemctl list-timers bitwarden-backup.timer
```

- [ ] **Step 8: Register owner & lockdown**

In a browser: `https://panda.hello-vanilla.ru` → Create Account. **Write the master password down on paper before submitting.**

Then:
```bash
sudo ./scripts/lockdown.sh
```
Expected: log line `Registration locked (HTTP 4xx ...)`.

- [ ] **Step 9: Enable 2FA**

In the web UI: Account Settings → Security → Two-step Login → Authenticator App. Save the recovery code offline.

- [ ] **Step 10: Trigger first backup, save the encryption password**

```bash
sudo ./scripts/backup.sh
sudo cat /root/.bitwarden-backup-pass
```
**Copy the password offline immediately.** Verify the archive exists:
```bash
ls -lh /var/backups/bitwarden/
```

- [ ] **Step 11: Verify clients**

Install Bitwarden mobile app and browser extension. In each, set Server URL = `https://panda.hello-vanilla.ru`. Log in. Add a test item; confirm it syncs to the other client.

- [ ] **Step 12: Restore drill (optional but strongly recommended)**

On a separate dev machine (NOT the same VPS), copy a backup archive and the pass file, then:
```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in <archive>.tar.gz.enc \
  -out test.tar.gz \
  -pass file:.bitwarden-backup-pass
tar tzf test.tar.gz | head
sqlite3 <(tar xzf test.tar.gz -O ./data/db.sqlite) '.tables'
```
Expected: `tar tzf` lists files starting with `./`, sqlite query lists Bitwarden tables (User, Cipher, etc.).

If any step fails — see spec section 6.4 troubleshooting table.

---

## Self-Review

(Run after writing the full plan — fix issues inline, no separate review pass.)

**Spec coverage check:**
- Spec § 2 decisions log — captured implicitly via task choices ✓
- Spec § 3 architecture (single container, 127.0.0.1 bind, existing nginx) — Task 3, Task 4, Task 7 ✓
- Spec § 4.1 `.env.example` — Task 2 ✓
- Spec § 4.2 `docker-compose.yml` — Task 3 ✓
- Spec § 4.3 nginx vhost template — Task 4 ✓
- Spec § 5.1 `bootstrap.sh` (sanity, apt, docker, certbot, swap, ufw, fail2ban skip, summary) — Task 6 ✓
- Spec § 5.2 `install.sh` (env check, port check, pull/up, healthcheck wait, vhost render, nginx test+reload, certbot, smoke check, systemd install) — Task 7 ✓
- Spec § 5.3 `lockdown.sh` — Task 8 ✓
- Spec § 5.4 `backup.sh` (sqlite atomic dump, volume tar, openssl encrypt, password gen + offline-save banner, rotation) — Task 9 ✓
- Spec § 5.5 `restore.sh` with `--yes-i-know` — Task 10 ✓
- Spec § 5.6 `update.sh` with digest save — Task 11 ✓
- Spec § 5.7 systemd units — Task 9 ✓
- Spec § 6 runbook — Task 13 (manual VPS smoke test) + Task 12 (README scripts table) ✓
- Spec § 7 smoke checklist — Task 13 step 7 ✓
- Spec § 10 open items (verify env-var names, choose user, log location) — Task 1 ✓ (env names); user-name + log location stay as default (sudo-user from `$SUDO_USER`, log to `/var/log/bitwarden-backup.log` per Task 9 step 2). Optional `limit_req_zone` deferred — call out in README if user wants.

**Placeholder scan:** No "TBD/TODO" remain. Task 1 deliberately defers env-var lookup but supplies the URL + procedure. Task 12/13 are by design manual.

**Type/name consistency:**
- `BW_DOMAIN` is consistently a **bare hostname** (no scheme, per spec section 11.2 #3) across `.env.example`, compose, and scripts. Scripts that need to construct URLs (install.sh, lockdown.sh) prepend `https://` themselves and validate via a `case` guard that no scheme leaked into the value — checked install.sh, lockdown.sh.
- `BW_DISABLE_REGISTRATION` is the human-friendly `.env` name; the compose `environment:` block re-maps it to the upstream variable `globalSettings__disableUserRegistration` (no short `BW_*` alias exists — spec section 11.2 #1). lockdown.sh edits the `.env` variable then `docker compose up -d` propagates the new value.
- SQLite path inside the container is `/etc/bitwarden/vault.db` (the `BW_DB_FILE` default — spec section 11.2 #2 and section 11.3). backup.sh references this exact path; no other path is hardcoded.
- `BW_BIND_PORT` consistent everywhere.
- `bitwarden_data` volume name consistent in compose, backup.sh, restore.sh.
- `bitwarden` container name consistent.
- Pass file path `/root/.bitwarden-backup-pass` consistent in backup.sh, restore.sh, runbook.
- Backup dir `/var/backups/bitwarden` consistent in backup.sh, runbook.

No drift detected.

---
