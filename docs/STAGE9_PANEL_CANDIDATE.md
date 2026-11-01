# Stage 9 — Offline Remnawave Panel candidate (PL, 1 vCPU / 2 GiB)

## Goal

Prepare a **not-running** Remnawave Panel deployment model on PL using its
**exact running NL image digest**. Validate that it cannot accidentally expose
ports, attach to production Docker networks, share production MuteBackend
volumes, or use production Telegram/Cloudflare secrets. This stage is NOT a
migration and does NOT start a new control plane.

### Pre-conditions

- Stage 7: the isolated PostgreSQL 18.3 Docker volume exists and is **stopped**.
- Stage 8: root-only NL reference files present under
  `/etc/mutevpn/remnawave/stage8-reference/` on PL.
- PL existing `remnanode` and `remnawave-nginx` remain running.
- Docker Compose V2 is installed on PL.
- NL running Remnawave Docker image must have a corresponding immutable registry
  RepoDigest. If no digest is available, do not use a mutable `:3` tag; obtain
  an exact version/digest first.

### Operation

```bash
cd ~/MuteSettings
ansible-playbook --syntax-check -i ~/mute-ha/inventory.yml \
  playbooks/stage9_prepare_panel_candidate.yml
ansible-playbook -i ~/mute-ha/inventory.yml -u root \
  --private-key "$HOME/.ssh/mute_ha_ed25519" \
  playbooks/stage9_prepare_panel_candidate.yml
```

Creates only on PL (not in GitHub):

```text
/opt/mutevpn/remnawave/stage9-candidate/
  compose.yml.disabled   (root-only 0600; valid Compose, not an active default file)
  sandbox.env            (root-only 0600; NEW throwaway credentials, never NL .env)
```

The candidate uses `postgres:18.3`, `valkey/valkey:9.0.3-alpine`, and the exact
Remnawave image digest used by running NL panel. It references only the Stage 7
**cold** volume `mutevpn_stage7_panel_pg18`. Its Docker network is `internal:
true`; **no ports published** and no live `remnawave-network` attachment. The
reference `.env` is **never loaded or copied** into the candidate. The
`DATABASE_URL` points only to the Stage 7 PG18 clone. Telegram notifications,
webhooks and Cloudflare token are disabled/blank in the sandbox. It has explicit
memory budgets so Stage 10 can assess whether a controlled isolated startup is
possible without killing the PL VPN node.

This script performs Docker Compose **model validation only**; it does not start
any containers, open any ports, pull any image, change a volume, stop a service,
or modify production databases. Thus it does not prove the panel actually boots,
can decrypt existing production integrations, or can serve live subscriptions.
Do **not** manually run `docker compose up` against this candidate; the Stage 10
startup test must include CPU/memory gates and a guaranteed shutdown. Docker
internal networks are defense in depth, not a substitute for an independently
verified production cutover procedure.

### Why the app uses disposable secrets

For this configuration-only check, temporary secrets remove the risk of sending
real HAPP/Telegram/Cloudflare/panel credentials into another running application.
At the final cutover, the approved production secrets are restored from Stage 8
with controlled secret replacement and a coordinated stop of the NL control plane.
**Never** use Stage 9 temporary secrets for the production panel.

### Success markers

```text
STAGE9_COMPOSE_PARSE=PASS
STAGE9_INTERNAL_NETWORK_ONLY=YES
STAGE9_PUBLISHED_PORTS=ZERO
STAGE9_PRODUCTION_SECRETS_IN_SANDBOX=NO
STAGE9_PANEL_IMAGE_DIGEST_PINNED=YES
STAGE9_STAGE7_DATABASE_REMAINS_COLD=YES
STAGE9_OFFLINE_PANEL_CANDIDATE=READY
```

## Next

Stage 10: controlled smoke test on an isolated network, if resource headroom
permits; then final synchronized migration of **both** PostgreSQL 18 and 17,
Remnawave/Backend/worker/subscription-page, coordinated bot handover, live
health checks and rollback. Keep all original root backups until the new PL
control plane and separate backup recovery are tested.
