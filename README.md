# MuteSettings (private infrastructure repository)

**Purpose:** versioned, reviewed Ansible, Docker Compose templates, and production runbooks for MuteVPN.

This repo contains **no** live database dumps, private keys, tokens, customer data, real `.env` files, or production credentials. Private repository is **not** a secrets vault.

## Planned topology

- **PL:** primary Remnawave Panel, MuteBackend web/worker/bot, two PostgreSQL clusters, Redis, subscription ingress.
- **FI:** standby with database replication and prepared applications; bot polling / payment worker remains disabled unless promoted.
- **NL:** VPN node; future changes to NL public IP must not affect API/subscription availability.

Current production remains NL until a controlled final cutover. Current PL nginx proxies API/subscription traffic to NL. HAPP uses `crypt5` and may honor free Provider settings, but core VPN must not depend on HAPP Provider quota.

## Stage 4: non-production restore verification

Snapshot source already present on PL: `/root/mute-ha-stage3-backups/20261101T125729Z`.

Run locally in WSL, where your SSH key is configured:

```bash
bash scripts/stage4_restore_verify.sh 20261101T125729Z
```

The script copies verified dumps to `/var/backups/mutevpn/snapshots/...` and restores them **one at a time** in isolated, network-disabled, resource-limited temporary PostgreSQL 18 and 17 containers. It checks public tables, then deletes test containers and test volumes. It **never** restores over active PL PostgreSQL, starts the production bot, or switches the API. It keeps original backups in `/root` temporarily for safety.

**Operational note:** this snapshot is point-in-time, not replication and not a final consistent cutover. It may become stale as production changes. At cutover, synchronize again with a controlled write pause and verify all integrations.

**Resource note:** PL and FI currently have only 1 vCPU / ~2GB RAM; do not attempt the full application deployment until capacity and port conflicts are resolved. This test can still add short-term CPU/RAM pressure. Run during a quiet period.

## GitHub workflow

Only add reviewed files explicitly. Never `git add -A` on a directory containing old HA backups or actual credentials. Configure your repo as private and protect `main`; commit through a PR.

Keep a secondary **encrypted, off-host** backup; local backups on PL are not protection against PL host failure.
