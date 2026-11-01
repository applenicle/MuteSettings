#!/usr/bin/env python3
"""Prepare and validate a NON-RUNNING panel sandbox on PL.

No docker run/start/up, no network changes, no SQL, and no production values copied
into the sandbox env. Stage7 volume is referenced but NOT opened by this script.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import urllib.parse

IMAGE_RE = re.compile(r"remnawave/backend@sha256:[0-9a-f]{64}\Z")
REF_DIR = Path('/etc/mutevpn/remnawave/stage8-reference')
READY = Path('/var/lib/mutevpn/stage7_panel_pg18.ready')
PASS = Path('/etc/mutevpn/stage7_panel_pg18.password')
TARGET = Path('/opt/mutevpn/remnawave/stage9-candidate')
COMPOSE = TARGET / 'compose.yml.disabled'
SANDBOX = TARGET / 'sandbox.env'


def run(*cmd: str) -> str:
    cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, check=False)
    if cp.returncode:
        # Never print stderr: docker compose config could include env secrets.
        raise RuntimeError(f'LOCAL_COMMAND_FAILED={cmd[0]}')
    return cp.stdout.strip()


def require(cond: bool, marker: str) -> None:
    if not cond:
        raise RuntimeError(marker)


def safe_file(path: Path) -> None:
    require(path.is_file() and not path.is_symlink(), 'MISSING_OR_SYMLINKED_PRIVATE_FILE')
    require(path.stat().st_uid == 0, 'UNTRUSTED_FILE_OWNER')
    require((path.stat().st_mode & 0o077) == 0, 'UNSAFE_PRIVATE_FILE_PERMISSIONS')


def panel_reference_keys() -> set[str]:
    file = REF_DIR / 'panel-source.env.disabled'
    safe_file(file)
    keys = set()
    # Read NAMES only; never print any value, interpolate, or execute the file.
    for line in file.read_text(encoding='utf-8').splitlines():
        m = re.match(r'^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=',line)
        if m:
            keys.add(m.group(1))
    return keys


def text_env(password: str) -> str:
    pw = urllib.parse.quote(password, safe='')
    values = {
      'DATABASE_URL': f'postgresql://postgres:{pw}@db:5432/postgres',
      'POSTGRES_DB': 'postgres', 'POSTGRES_USER': 'postgres',
      'APP_SECRET': secrets.token_hex(64),
      'JWT_AUTH_SECRET': secrets.token_hex(64),
      'JWT_API_TOKENS_SECRET': secrets.token_hex(64),
      'REDIS_HOST': 'cache', 'REDIS_PORT': '6379', 'REDIS_SOCKET': '',
      'API_INSTANCES': '1', 'APP_PORT': '3000',
      'PANEL_DOMAIN': 'localhost', 'FRONT_END_DOMAIN': 'localhost',
      'SUB_PUBLIC_DOMAIN': 'localhost/api/sub',
      'WEBHOOK_ENABLED': 'false', 'WEBHOOK_URL': '',
      'IS_TELEGRAM_NOTIFICATIONS_ENABLED': 'false',
      'TELEGRAM_BOT_TOKEN': '', 'CLOUDFLARE_TOKEN': '',
      'TELEGRAM_NOTIFY_USERS': 'false', 'TELEGRAM_NOTIFY_NODES': 'false',
      'TELEGRAM_NOTIFY_SERVICE': 'false', 'TELEGRAM_NOTIFY_CRM': 'false',
      'TELEGRAM_NOTIFY_TBLOCKER': 'false',
    }
    return ''.join(f'{key}={value}\n' for key, value in values.items())


def compose_text(panel_image: str) -> str:
    # Explicit project name, all services on a single *internal* bridge network,
    # zero published ports, no access to live DB/Redis/network or Docker socket.
    return f'''name: mutevpn_stage9
services:
  db:
    image: postgres:18.3
    restart: "no"
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD_FILE: /run/secrets/stage7_pg_password
    secrets:
      - stage7_pg_password
    command: ["postgres", "-c", "shared_buffers=32MB", "-c", "max_connections=20", "-c", "work_mem=4MB"]
    volumes:
      - type: volume
        source: stage7_pg18
        target: /var/lib/postgresql
    networks: [isolated]
    mem_limit: 320m
    memswap_limit: 512m
    cpus: 0.45
    pids_limit: 128
  cache:
    image: valkey/valkey:9.0.3-alpine
    restart: "no"
    command: ["valkey-server", "--save", "", "--appendonly", "no", "--maxmemory", "48mb"]
    networks: [isolated]
    mem_limit: 96m
    cpus: 0.15
    pids_limit: 64
  panel:
    image: {panel_image}
    restart: "no"
    env_file:
      - ./sandbox.env
    environment:
      REDIS_HOST: cache
      REDIS_PORT: "6379"
      REDIS_SOCKET: ""
      API_INSTANCES: "1"
      WEBHOOK_ENABLED: "false"
      IS_TELEGRAM_NOTIFICATIONS_ENABLED: "false"
      TELEGRAM_BOT_TOKEN: ""
      CLOUDFLARE_TOKEN: ""
    depends_on: [db, cache]
    networks: [isolated]
    mem_limit: 650m
    memswap_limit: 900m
    cpus: 0.65
    pids_limit: 180
    security_opt: ["no-new-privileges:true"]
networks:
  isolated:
    internal: true
    driver: bridge
volumes:
  stage7_pg18:
    external: true
    name: mutevpn_stage7_panel_pg18
secrets:
  stage7_pg_password:
    file: /etc/mutevpn/stage7_panel_pg18.password
'''


def validate(image: str) -> None:
    # Parse the effective Docker Compose model, without displaying env values.
    raw = run('docker','compose','-p','mutevpn_stage9','-f',str(COMPOSE),'config','--format','json')
    model = json.loads(raw)
    services = model.get('services',{})
    require(set(services) == {'db','cache','panel'}, 'BAD_SERVICE_ALLOWLIST')
    networks = model.get('networks',{})
    require(len(networks) == 1 and all(n.get('internal') is True for n in networks.values()),
            'ISOLATION_NOT_INTERNAL')
    for name, service in services.items():
        require(not service.get('ports') and not service.get('network_mode'), 'PUBLIC_OR_HOST_NETWORK_FORBIDDEN')
        require(not service.get('privileged') and not service.get('pid')=='host', 'PRIVILEGED_FORBIDDEN')
        require(not service.get('container_name'), 'CONTAINER_NAME_COLLISION_RISK')
        require(len(service.get('networks',{})) == 1, 'WRONG_NETWORK_ATTACHMENT')
        require(service.get('restart') == 'no', 'UNEXPECTED_RESTART_POLICY')
        for volume in service.get('volumes',[]):
            src = str(volume.get('source',''))
            require('/var/run/docker.sock' not in src, 'DOCKER_SOCK_FORBIDDEN')
            require(not src.startswith('mutevpn_remnawave_'), 'LIVE_VOLUME_FORBIDDEN')
    require(services['panel']['image'] == image, 'UNPINNED_PANEL_IMAGE')
    require(services['panel'].get('environment',{}).get('WEBHOOK_ENABLED') in (False,'false','False'),
            'WEBHOOK_NOT_DISABLED')
    require(services['panel'].get('environment',{}).get('IS_TELEGRAM_NOTIFICATIONS_ENABLED') in (False,'false','False'),
            'TELEGRAM_NOTIFICATIONS_NOT_DISABLED')
    require(all('remnawave-network' not in k for k in networks), 'LIVE_NETWORK_FORBIDDEN')
    require(model.get('volumes',{}).get('stage7_pg18',{}).get('external') is True,
            'STAGE7_VOLUME_MUST_BE_EXTERNAL')
    print('STAGE9_COMPOSE_PARSE=PASS')
    print('STAGE9_INTERNAL_NETWORK_ONLY=YES')
    print('STAGE9_PUBLISHED_PORTS=ZERO')
    print('STAGE9_PRODUCTION_SECRETS_IN_SANDBOX=NO')
    print('STAGE9_PANEL_IMAGE_DIGEST_PINNED=YES')


def main() -> None:
    require(os.geteuid()==0,'NEED_ROOT')
    require(len(sys.argv)==2 and IMAGE_RE.fullmatch(sys.argv[1]),'INVALID_PINNED_IMAGE')
    image = sys.argv[1]
    require(run('docker','inspect','-f','{{.State.Running}}','remnanode') == 'true',
            'PL_REMNANODE_NOT_RUNNING')
    require(run('docker','inspect','-f','{{.State.Running}}','remnawave-nginx') == 'true',
            'PL_NGINX_NOT_RUNNING')
    require(run('docker','inspect','-f','{{.State.Status}}','mutevpn-stage7-panel-pg18') == 'exited',
            'STAGE7_DB_MUST_BE_COLD')
    run('docker','volume','inspect','mutevpn_stage7_panel_pg18')
    safe_file(READY)
    require(PASS.is_file() and not PASS.is_symlink() and PASS.stat().st_uid == 0,
            'STAGE7_PASSWORD_FILE_UNSAFE')
    require((Path('/etc/mutevpn').stat().st_mode & 0o077) == 0,
            'STAGE7_PASSWORD_PARENT_PERMISSIONS_UNSAFE')
    for f in ['panel-source.env.disabled','panel-source-compose.yml.disabled','panel-source-nginx.conf.disabled']:
        safe_file(REF_DIR / f)
    require((REF_DIR.stat().st_mode & 0o077)==0, 'REFERENCE_DIRECTORY_PERMISSIONS_UNSAFE')
    keys=panel_reference_keys()
    require({'DATABASE_URL','APP_SECRET','FRONT_END_DOMAIN','SUB_PUBLIC_DOMAIN','JWT_AUTH_SECRET'} <= keys,
            'STAGE8_MISSING_REQUIRED_KEYS')
    require(int(run('sh','-c',"awk '/MemAvailable:/ {print $2}' /proc/meminfo")) > 200000,
            'LOW_RAM_EVEN_FOR_OFFLINE_PREPARATION')
    require(int(run('sh','-c',"df -Pk /opt | awk 'END {print $4}'")) > 2097152,
            'LOW_DISK_FOR_FUTURE_PANEL')
    # Source Stage 7 password is only read locally as root, never sent to Ansible.
    passphrase=PASS.read_text(encoding='utf-8').strip()
    require(len(passphrase)>=32 and '\n' not in passphrase, 'BAD_STAGE7_PASSWORD')
    require(TARGET.parent.is_dir() and not TARGET.parent.is_symlink(), 'STAGE6_PARENT_MISSING')
    if TARGET.exists():
        require(TARGET.is_dir() and not TARGET.is_symlink() and
                TARGET.stat().st_uid==0 and (TARGET.stat().st_mode & 0o077)==0,
                'EXISTING_CANDIDATE_DIR_UNTRUSTED')
        safe_file(COMPOSE); safe_file(SANDBOX)
        require(COMPOSE.read_text()==compose_text(image), 'CANDIDATE_EXISTING_DIFFERS_REFUSE_OVERWRITE')
        print('STAGE9_ALREADY_PREPARED=YES')
        validate(image)
    else:
        TARGET.mkdir(mode=0o700)
        try:
            SANDBOX.write_text(text_env(passphrase),encoding='utf-8')
            SANDBOX.chmod(0o600)
            COMPOSE.write_text(compose_text(image),encoding='utf-8')
            COMPOSE.chmod(0o600)
            validate(image)
        except Exception:
            # Do not delete anything older: the entire directory was just created.
            SANDBOX.unlink(missing_ok=True)
            COMPOSE.unlink(missing_ok=True)
            TARGET.rmdir()
            raise
    # Idempotent marker; no container starts, no data modifications.
    print('STAGE9_LIVE_PANEL_STARTED=NO')
    print('STAGE9_STAGE7_DATABASE_REMAINS_COLD=YES')
    print('STAGE9_PRODUCTION_PL_NETWORK_UNCHANGED=YES')
    print('STAGE9_FINAL_SYNC_REQUIRED=YES')
    print('STAGE9_OFFLINE_PANEL_CANDIDATE=READY')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'STAGE9_FAILED={str(exc)}',file=sys.stderr)
        sys.exit(1)
