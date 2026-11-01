# Planned migration (not yet executed)

## Stage 3 — completed
- NL PostgreSQL 18 Remnawave and PostgreSQL 17 MuteBackend custom-format dumps copied to PL; SHA256 verified.
- Stored in `/root/mute-ha-stage3-backups/20261101T125729Z`.

## Stage 4 — next
- Preserve original dumps, copy to `/var/backups/mutevpn/snapshots` with 0600 perms.
- Restore in **isolated** Docker PG18 and PG17 containers, check table counts and schema.
- Do not start production bot or migrate live DB.

## Stage 5 — planned (requires separate change review)
- Ensure PL capacity (prefer 4 vCPU / 8 GB RAM), storage and restore-tested off-host backups.
- Prepare Remnawave and MuteBackend compose templates under `/opt/mutevpn`, secrets under `/etc/mutevpn`.
- Preserve live database versions 18 and 17 separately; do not silently combine or upgrade clusters.
- Prepare isolated staging with outbound side effects disabled (Telegram polling, payment handlers, scheduled workers).
- Prepare safe HTTPS ingress with no collision between Xray `rw-core` on TCP 443 and public apps.
- Confirm Remnawave node addresses and source URLs, current production image digests, and HAPP crypt5 compatibility.

## Stage 6 — planned
- Maintenance/write pause and final sync; only one primary bot/worker/payment handler.
- Validate PL API and HAPP subscriptions, then switch PL local nginx upstreams and Remnawave management DNS.
- Rollback only with verified data consistency; never overwrite newer data with a stale dump.

## Stage 7 — planned
- FI PG standby, separate failover ingress, monitor replica lag, WAL retention and real client checks.
- Ensure fencing/split-brain prevention before any automated promotion.
