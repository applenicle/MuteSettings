# Stage 8: Secure, non-running Remnawave panel configuration preparation

**Purpose**: Prepare the Remnawave control-plane move from NL to PL by copying its **existing** source environment, Compose and nginx references to root-only storage on PL. This stage **does not** run another panel, start its PostgreSQL database, change an ingress, restart Docker, modify DNS, or touch the bot.

## Why we cannot simply start the copied panel

- NL remains the **only** live Remnawave panel. A second panel attached to the restored database could run background jobs, node control, Telegram notifications, or webhooks concurrently.
- The PG18 volume on PL (`mutevpn_stage7_panel_pg18`) is a **cold restore** from Nov 1, not a synchronized primary. Production continues writing on NL.
- The target PL VPS has 1 vCPU and 2 GB RAM with swap. We must constrain actual worker/process counts and avoid redundant copies.
- Existing `rw-core`/VPN node owns port 443, and the PL nginx is forwarding `api.mutevpn.shop` and `sub.mutevpn.shop` to NL. Don't overwrite it.
- Secrets and the cryptographic identity of the panel must be retained for final cutover; don't invent new APP_SECRET/JWT secrets on PL without analyzing integration compatibility.

## Secure transfer

Use Ansible on your WSL machine, where `~/mute-ha/inventory.yml` defines the existing aliases (`nl`, `pl`, `fi`). **Never** commit production `.env`, Compose files with inlined secrets, nginx TLS material, PostgreSQL dumps, or runtime inventory to GitHub.

```bash
cd ~/MuteSettings
ansible-playbook --syntax-check -i ~/mute-ha/inventory.yml playbooks/stage8_prepare_panel_config.yml
ansible-playbook -i ~/mute-ha/inventory.yml -u root \
  --private-key "$HOME/.ssh/mute_ha_ed25519" \
  playbooks/stage8_prepare_panel_config.yml
```

The playbook uses Ansible `slurp` and root-only `copy` with `no_log: true`, then compares source and destination SHA-256 hashes. **The transferred bytes travel via the Ansible controller in memory** (no persistent local secrets file is created by this playbook), but are retained securely on PL at:

```
/etc/mutevpn/remnawave/stage8-reference/
    panel-source.env.disabled
    panel-source-compose.yml.disabled
    panel-source-nginx.conf.disabled
```

These are deliberately **disabled reference files, not runnable deployment configuration**. Their directory mode is 0700, file modes 0600. Even if the source .env includes a private key or Cloudflare token, no values are printed in Ansible output; don't enable Ansible verbose logging, `ANSIBLE_LOG_PATH`, or external callback plugins that persist decrypted task variables. Ensure the WSL workstation and controller are trusted. On PL, ensure this directory is excluded from backups accessible to unauthorized parties.

The playbook validates that Stage 7 PG18 is **stopped** and its volume exists. It makes no attempt to update the database or synchronize production writes. Only run it on your trusted VPS SSH connections.

## Success markers

```
STAGE8_NL_REFERENCE_CAPTURED=YES
STAGE8_SAFE_AUDIT=PASS
STAGE8_CONFIG_SOURCE_TO_PL_SHA256=VERIFIED
STAGE8_PANEL_PROCESS_STARTED=NO
STAGE8_COMPLETED=YES
```

## Next stage

Build a **new** constrained Compose project on PL under `/opt/mutevpn/remnawave/` using the reference files **only as inputs**. It must have distinct container names, no public port bindings, and no production webhook or node-control behavior while staging. The Stage 7 PG18 dataset is still stale; a consistent final snapshot of *both* PG18 and PG17 is required during an explicitly coordinated cutover. Do not start two production Telegram bots or two active Remnawave panels.
