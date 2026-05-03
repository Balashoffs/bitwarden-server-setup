#!/usr/bin/env bash
# Prepare a fresh Ubuntu 22.04 VPS for Bitwarden installation.
# Idempotent: re-running is safe.
# Run: sudo ./scripts/bootstrap.sh [--configure-ufw]

# shellcheck source=scripts/_lib.sh
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
# shellcheck disable=SC1091  # /etc/os-release is provided by the OS, not the repo
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
  # shellcheck disable=SC1091  # /etc/os-release is provided by the OS
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
