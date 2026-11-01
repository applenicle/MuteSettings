# MuteVPN low-resource migration — 1 vCPU / 2 GiB per VPS

Decision: **no VPS hardware upgrade**. NL remains production until the last validated cutover. PL becomes primary. FI is a **cold standby**, not a permanently-running redundant panel/database stack. NL remains a VPN node.

Stage 6: create folders on PL and FI, add a swap file on PL (1.5 GiB) and FI (1 GiB), and report Docker memory/compose layout. No container restarts, no database modifications, no bot start, no ingress/DNS changes.

Run from WSL (after merging current PR):

```bash
cd ~/MuteSettings
git switch -c feat/stage6-low-resource
mkdir -p playbooks docs
# Copy playbooks/stage6_lite_prepare.yml and docs/LOW_RESOURCE_DEPLOYMENT.md from supplied archive.
ansible-inventory -i ~/mute-ha/inventory.yml --graph
ansible-playbook --syntax-check -i ~/mute-ha/inventory.yml playbooks/stage6_lite_prepare.yml
ansible-playbook -i ~/mute-ha/inventory.yml -u root \
  --private-key "$HOME/.ssh/mute_ha_ed25519" \
  playbooks/stage6_lite_prepare.yml
```

## Planning constraints

- Swap makes short memory spikes more survivable but **does not add CPU or replace RAM**; latency under load may increase. Do not promise zero downtime on 1 vCPU / 2 GiB.
- Do not run duplicate Telegram bot/worker/payment processors. Verify FI staging bot uses a different token before starting any migrated instance. Do not publish token values.
- PL currently has an old PostgreSQL 17 database and Redis, and inactive MuteBackend containers. **Do not `docker compose up -d` that old project.** First establish which persistent data is disposable versus active, and make new backups.
- PL port 443 is already occupied by `rw-core`; keep it. Additional HTTPS services should be routed by the existing ingress, not by binding a competing public listener.
- Plan to minimize memory by using exactly one instance of each needed service, small explicit PostgreSQL settings after checking compatibility, and no redundant local workloads.
- FI is cold standby initially. Automatic, no-data-loss failover is not available without replication, fencing and tested failover. Define RPO/RTO realistically before advertising automatic HA.
- The Stage 4 verified backups represent a snapshot, not live replication. Final cutover needs a write pause, a new synced backup and a single bot/worker instance.
- Never commit .env, key files, database dumps, user subscriptions, payment secrets, certificates or production compose output containing interpolated secrets to GitHub.
