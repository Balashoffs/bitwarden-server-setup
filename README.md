# Bitwarden Server Setup

Self-hosted Bitwarden on a 2 GB Ubuntu 22.04 VPS, integrated with an existing nginx reverse proxy.

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
6. **Write the master password down on paper.** It cannot be reset.
7. Run `sudo ./scripts/lockdown.sh` to disable further registrations.
8. Enable TOTP 2FA in account settings; save the recovery code offline.
9. After the first backup, copy `/root/.bitwarden-backup-pass` offline.

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

## Reference

The full design and runbook (including troubleshooting, restore, and operations) is at:

`docs/superpowers/specs/2026-05-02-bitwarden-vps-setup-design.md`

In particular:
- Section 6 — full runbook
- Section 7 — smoke checklist after install
- Section 8 — known risks

## Scripts reference

| Script | Purpose | Idempotent? |
|---|---|---|
| `scripts/bootstrap.sh [--configure-ufw]` | Install Docker, certbot, swap on Ubuntu 22.04 VPS | Yes |
| `scripts/install.sh` | Pull image, start container, configure nginx vhost + Let's Encrypt cert, install backup timer | Yes |
| `scripts/lockdown.sh` | Disable user registration after owner is created | Yes |
| `scripts/backup.sh` | Daily encrypted backup; run by systemd timer at 03:30 | Yes |
| `scripts/restore.sh <archive> --yes-i-know` | Restore from encrypted backup archive | DESTRUCTIVE |
| `scripts/update.sh` | Pull current `:beta` and recreate; saves rollback digest | Yes |
| `scripts/wipe.sh --yes-i-know [--wipe-all]` | Stop containers, remove volumes and backup timer; with `--wipe-all` also remove nginx vhost, certbot cert, and `.env`. Backup archives are kept. | DESTRUCTIVE |
