# Stage 7 — cold Remnawave PostgreSQL 18 preparation on PL

**Purpose:** prepare a *verified, isolated, non-production* copy of the Remnawave PostgreSQL 18 database on Poland without using additional VPS resources. Source backup comes from Stage 3 / Stage 4. Only the **Remnawave panel database** is prepared in this step. Backend PostgreSQL 17, Telegram bot, panel application, nginx and VPN nodes are **not moved or restarted** here.

## Prerequisites

- Stage 6 completed on PL, standard directories and swap present.
- Stage 4 backup still exists at `/var/backups/mutevpn/snapshots/20261101T125729Z/` on PL.
- Original Stage 3 directory and SHA256SUMS still exist on PL for cross-verification.
- `~/mute-ha/inventory.yml` includes the existing `pl` alias, and SSH `~/.ssh/mute_ha_ed25519` works.
- Keep NL as the only production panel and bot. No DNS or subscription URL changes.

## Run from WSL, from MuteSettings root

```bash
ansible-playbook --syntax-check -i ~/mute-ha/inventory.yml playbooks/stage7_prepare_panel_pg18.yml
ansible-playbook -i ~/mute-ha/inventory.yml -u root \
  --private-key "$HOME/.ssh/mute_ha_ed25519" \
  playbooks/stage7_prepare_panel_pg18.yml
```

The playbook uses a **new** Docker volume `mutevpn_stage7_panel_pg18` and container `mutevpn-stage7-panel-pg18`; neither a live PostgreSQL 17 service nor a production volume is reused. It pulls `postgres:18.3`, starts the test database **with no Docker network and no published ports**, restores one verified dump in a transaction, validates its table count, and **stops the test container**, leaving only the separate staged volume on disk. No permanent RAM usage is added after successful completion.

The generated staging password is stored only at `/etc/mutevpn/stage7_panel_pg18.password` on PL under a root-only parent directory. Do not commit it or print its contents.

Expected final markers:

```text
STAGING_REMNAWAVE_PUBLIC_TABLES=37
STAGED_DATABASE_STATE=STOPPED
LIVE_PL_POSTGRES17_UNCHANGED=YES
CURRENT_NL_PRODUCTION_UNCHANGED=YES
FINAL_SYNC_STILL_REQUIRED=YES
STAGE7_PANEL_DB_PREPARED=YES
```

Actual table count may vary. Stage 7 is idempotent for the exact snapshot; it **refuses** to reuse a container or volume when it cannot prove ownership and completion. On failure, only freshly-created Stage 7 resources are removed. Do not manually prune Docker volumes or run `docker compose up` on old PL projects.

## Next stage: panel app and final cutover

This is a cold copy of the Nov 1 snapshot, **not a live replica**. The panel application has **not yet been deployed**. Before starting any panel process, examine the current NL Compose services and environment **variable names only** (never expose secret values), prepare an isolated runtime config, disable background jobs/webhooks/node control in any candidate panel as necessary, and ensure **exactly one active production panel** during cutover. Final migration needs a fresh, consistent backup and an explicit maintenance/write-freeze window to prevent lost updates. Database version 18 on panel and version 17 on backend must be migrated independently.

Budget: 1 vCPU, 2 GiB RAM and swap on PL. The container has 320 MiB RAM limit, 512 MiB RAM+swap limit, and 0.55 CPU quota while running. Even an isolated restore may momentarily add load, so avoid peak traffic.

## Read-only NL panel contract for Stage 8

After the PL cold restore, collect only production container image names, Docker networks, Compose service labels and **environment variable names** from NL (never values):

```bash
ansible-playbook -i ~/mute-ha/inventory.yml -u root \
  --private-key "$HOME/.ssh/mute_ha_ed25519" \
  playbooks/stage7_panel_contract_readonly.yml
```

This second playbook makes **zero NL changes** and provides the runtime contract needed to design the panel app configuration on PL. Do not paste full `.env` or expanded `docker compose config` output to GitHub.
