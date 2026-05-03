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
   $EDITOR .env   # fill BW_DOMAIN, ADMIN_EMAIL, BW_INSTALLATION_*
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
