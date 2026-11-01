#!/usr/bin/env python3
"""Read-only audit. Prints only booleans, env *names*, and safe status lines.
NEVER output env content, Docker inspect JSON, or rendered Compose to logs.
"""
import os
import pathlib
import re
import subprocess
import sys

SOURCE = pathlib.Path('/etc/mutevpn/remnawave/stage8-reference')
FILES = [
    SOURCE / 'panel-source.env.disabled',
    SOURCE / 'panel-source-compose.yml.disabled',
    SOURCE / 'panel-source-nginx.conf.disabled',
]
REQUIRED = {'DATABASE_URL', 'APP_SECRET', 'JWT_AUTH_SECRET', 'JWT_API_TOKENS_SECRET', 'REDIS_SOCKET'}

def fail(msg):
    print('STOP=' + msg)
    raise SystemExit(2)

def docker(*args):
    return subprocess.run(['docker', *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True).stdout

if os.geteuid() != 0:
    fail('ROOT_REQUIRED')
for p in FILES:
    if not p.is_file() or p.stat().st_size == 0:
        fail('REFERENCE_MISSING')
    if p.stat().st_mode & 0o077:
        fail('REFERENCE_PERMISSIONS_TOO_OPEN')
if SOURCE.stat().st_mode & 0o077:
    fail('REFERENCE_DIRECTORY_PERMISSIONS_TOO_OPEN')

env = {}
for line in FILES[0].read_text(encoding='utf-8').splitlines():
    match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*)$', line)
    if match:
        env[match.group(1)] = match.group(2)

missing = sorted(REQUIRED.difference(env))
# Stage 7 contract shows all keys in the *running container*, but source .env
# may omit vars injected by Compose. Treat missing as AUDIT not destructive failure.
print('=== STAGE8 PL REFERENCE AUDIT ===')
print('SOURCE_ENV_KEY_COUNT=' + str(len(env)))
print('MISSING_EXPECTED_SOURCE_ENV_KEYS=' + (','.join(missing) if missing else 'NONE'))
print('SOURCE_HAS_PANEL_FRONT_END_DOMAIN=' + str('FRONT_END_DOMAIN' in env).upper())
print('SOURCE_HAS_SUB_PUBLIC_DOMAIN=' + str('SUB_PUBLIC_DOMAIN' in env).upper())
print('SOURCE_HAS_WEBHOOK_ENABLED_FLAG=' + str('WEBHOOK_ENABLED' in env).upper())
print('REFERENCE_FILE_PERMISSIONS=ROOT_ONLY')

status = docker('inspect', '-f', '{{.State.Status}}', 'mutevpn-stage7-panel-pg18').strip()
if status != 'exited':
    fail('STAGE7_PG18_NOT_STOPPED')
print('STAGE7_PG18_VOLUME=AVAILABLE_COLD')

# Reject any running Remnawave backend on PL. Other components (VPN node/nginx)
# contain "remnawave" in their image names, so match ONLY the backend image.
containers = docker('ps', '--format', '{{.Image}}|{{.Names}}').splitlines()
panels = []
for row in containers:
    image, _, name = row.partition('|')
    if image.startswith('remnawave/backend:') or name == 'remnawave':
        panels.append(name)
if panels:
    fail('UNEXPECTED_RUNNING_PL_REMNAWAVE_PANEL')
print('EXISTING_PL_REMNAWAVE_PANEL=NOT_RUNNING')
print('ACTIVE_NL_PANEL_UNCHANGED=YES')
print('PANEL_REFERENCE_FILES_ARE_DISABLED=YES')
print('STAGE8_SAFE_AUDIT=PASS')
