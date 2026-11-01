#!/usr/bin/env python3
"""Read-only, redacted NL Remnawave runtime contract for Stage 8 planning.

Reads Docker inspect in memory. Prints only predetermined safe fields and
environment VARIABLE NAMES (never their values). Does not read .env files.
"""
import json
import os
import re
import subprocess

if os.geteuid() != 0:
    raise SystemExit('ERROR=REQUIRES_ROOT')

names = (
    'remnawave', 'remnawave-db', 'remnawave-redis',
    'remnawave-subscription-page', 'remnawave-nginx',
)
print('=== STAGE 7: NL REMNAWAVE RUNTIME CONTRACT (READ ONLY) ===')
print('NO_ENV_VALUES_OR_SECRETS=YES')
for name in names:
    cmd = ['docker', 'inspect', '--type=container', name]
    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=12)
        data = json.loads(raw)[0]
    except (subprocess.SubprocessError, json.JSONDecodeError, IndexError):
        print(f'CONTAINER_{name}=NOT_INSPECTABLE')
        continue
    config = data.get('Config') or {}
    host = data.get('HostConfig') or {}
    labels = config.get('Labels') or {}
    state = data.get('State') or {}
    keys = []
    for item in config.get('Env') or []:
        key = item.split('=', 1)[0]
        if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,100}', key):
            keys.append(key)
    # Values are deliberately NOT included in any output.
    print(f'CONTAINER={name}')
    print(f'  IMAGE={config.get("Image", "unknown")}')
    print(f'  STATE={state.get("Status", "unknown")}')
    print(f'  COMPOSE_SERVICE={labels.get("com.docker.compose.service", "unknown")}')
    print(f'  COMPOSE_PROJECT={labels.get("com.docker.compose.project", "unknown")}')
    print(f'  NETWORK_NAMES={",".join(sorted((data.get("NetworkSettings") or {}).get("Networks") or {}))}')
    print(f'  ENV_KEYS={",".join(sorted(set(keys)))}')
    print(f'  RESTART_POLICY={(host.get("RestartPolicy") or {}).get("Name", "unknown")}')
for path in (
    '/opt/remnawave/docker-compose.yml', '/opt/remnawave/.env',
    '/opt/remnawave/nginx.conf',
):
    print(f'FILE_PRESENT_{path}={"YES" if os.path.isfile(path) else "NO"}')
print('STAGE7_NL_PANEL_CONTRACT=COMPLETE')
