#!/usr/bin/env bash
# MuteSettings / Stage 5: read-only inventory for NL -> PL production migration.
# Run on WSL, not on a VPS. Never prints environment variable values or secrets.
set -Eeuo pipefail
umask 077

KEY="${MUTE_HA_KEY:-$HOME/.ssh/mute_ha_ed25519}"
REPORT_DIR="${MUTE_HA_REPORT_DIR:-$HOME/mute-ha/artifacts}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$REPORT_DIR/stage5-pl-cutover-preflight-$STAMP.txt"

[[ -r "$KEY" ]] || { echo "STOP=SSH_KEY_MISSING ($KEY)" >&2; exit 2; }
mkdir -p "$REPORT_DIR"

read -r -d '' REMOTE <<'REMOTE' || true
set -u
export LC_ALL=C

printf 'HOST=%s\n' "$(hostname -s)"
printf 'UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'CPU_CORES=%s\n' "$(nproc)"
awk '/MemTotal:/ { printf "RAM_TOTAL_MIB=%d\n", $2/1024 } /MemAvailable:/ { printf "RAM_AVAILABLE_MIB=%d\n", $2/1024 } /SwapTotal:/ { printf "SWAP_TOTAL_MIB=%d\n", $2/1024 }' /proc/meminfo
printf 'ROOT_DISK='; df -hP / | tail -n 1 | awk '{print "total=" $2 " used=" $3 " available=" $4 " use=" $5}'
printf 'ROOT_FREE_KIB='; df -Pk / | tail -n 1 | awk '{print $4}'

printf '\n-- DOCKER SERVICES (no env values) --\n'
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}} | {{.Status}} | {{.Image}}' 2>/dev/null \
    | grep -Ei 'remnawave|remnanode|mutevpn|postgres|redis|nginx|rw-' \
    | head -n 35 || true
else
  echo 'DOCKER=NOT_INSTALLED'
fi

printf '\n-- COMPOSE PROJECT LABELS --\n'
for c in remnawave mutevpn_remnawave-web-1 mutevpn_remnawave-bot-1 mutevpn_staging-bot-1 remnanode remnawave-nginx; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker inspect -f 'CONTAINER={{.Name}} PROJECT={{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null || true
  fi
done

printf '\n-- PRODUCTION DATABASE READINESS --\n'
for c in remnawave-db mutevpn_remnawave-db-1 mutevpn_staging-db-1; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    continue
  fi
  printf 'DB_CONTAINER=%s\n' "$c"
  printf 'STATUS='; docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true
  printf 'IMAGE='; docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true
  printf 'VOLUMES='; docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}:{{.Destination}};{{end}}{{end}}' "$c" 2>/dev/null || true
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]]; then
    printf "SELECT current_setting('server_version'), pg_is_in_recovery(), current_database();\n" \
      | timeout 10 docker exec -i "$c" sh -c \
        'exec psql -XAt -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"' \
      | sed 's/^/PG_VERSION_STANDBY_DB=/' || echo 'PG_READ_ONLY_QUERY=FAILED'
  fi
done

printf '\n-- LIVE 443 AND HTTPS ROUTING CONTEXT --\n'
ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -E ':(443|4443|8443|2222|3000|3010|8080|8081)$' | sort -u | head -n 20 || true
for path in /opt/remnawave /opt/remnanode /opt/mutevpn /opt/mutebackend-fixed /etc/mutevpn /srv/mutevpn; do
  [[ ! -d "$path" ]] || printf 'EXISTS_DIR=%s\n' "$path"
done

printf '\n-- KNOWN STAGE 4 BACKUPS --\n'
SNAPDIR=/var/backups/mutevpn/snapshots/20261101T125729Z
if [[ -d "$SNAPDIR" ]]; then
  echo 'STAGE4_BACKUPS_ON_THIS_SERVER=YES'
  for filename in remnawave-pg18.dump mutebackend-pg17.dump; do
    if [[ -s "$SNAPDIR/$filename" ]]; then
      echo "STAGE4_BACKUP_FILE_$filename=PRESENT_NONEMPTY"
    else
      echo "STAGE4_BACKUP_FILE_$filename=MISSING"
    fi
  done
else
  echo 'STAGE4_BACKUPS_ON_THIS_SERVER=NO'
fi

printf '\n-- CAPACITY GATES (advisory, not an install) --\n'
CORES=$(nproc)
MEM_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
if (( CORES < 2 || MEM_KB < 4000000 )); then
  echo 'FULL_PRODUCTION_RESOURCE_GATE=INSUFFICIENT_FOR_RELIABLE_HA'
else
  echo 'FULL_PRODUCTION_RESOURCE_GATE=PASS_MINIMUM_PLANNING_GATE'
fi
printf 'STAGE5_REMOTE_INVENTORY_COMPLETE=YES\n'
REMOTE

{
  echo '=== MUTEVPN STAGE 5 PREFLIGHT: READ ONLY ==='
  echo 'INTENDED_ROLES=PL_PRIMARY_FI_STANDBY_NL_VPN_NODE'
  echo 'CURRENT_PRODUCTION=NL_UNCHANGED'
  echo 'NO_SQL_WRITES_NO_DOCKER_RESTARTS_NO_DNS_CHANGES=YES'
  echo "UTC=$STAMP"
  echo

  ANY_FAILED=0
  for ITEM in 'NL 185.23.19.152' 'PL 192.144.78.148' 'FI_TIMUR 152.234.212.20'; do
    read -r NAME IP <<< "$ITEM"
    echo "===== $NAME ====="
    if OUTPUT="$(ssh -T -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
      -o ConnectTimeout=12 -o StrictHostKeyChecking=yes \
      "root@$IP" 'bash -s' <<< "$REMOTE" 2>&1)"; then
      printf '%s\n' "$OUTPUT"
      echo "SSH_$NAME=OK"
    else
      RC=$?
      printf '%s\n' "$OUTPUT"
      echo "SSH_$NAME=FAILED_RC_$RC"
      ANY_FAILED=1
    fi
    echo
  done
  echo '=== EXTERNAL HEALTH SNAPSHOTS (not a full VPN test) ==='
  for DOMAIN in api.mutevpn.shop remna.mutevpn.shop; do
    STATUS="$(curl -q -4 -sS --noproxy '*' --connect-timeout 5 --max-time 10 \
      --output /dev/null --write-out 'HTTP=%{http_code} CURL_RC=%{exitcode} CONNECT_S=%{time_connect} TLS_S=%{time_appconnect} TOTAL_S=%{time_total}' \
      "https://$DOMAIN/healthz" 2>/dev/null || true)"
    echo "DOMAIN=$DOMAIN $STATUS"
  done
  echo 'NOTE=HEALTH_ENDPOINTS_MAY_NOT_EXIST;_404_ALONE_IS_NOT_AN_OUTAGE'
  if (( ANY_FAILED )); then
    echo 'STAGE5_PREFLIGHT=PARTIAL_SSH_FAILURE'
  else
    echo 'STAGE5_PREFLIGHT=COLLECTED'
  fi
} | tee "$REPORT"

echo "REPORT_SAVED=$REPORT"
echo 'NEXT=REVIEW_RESOURCES_AND_COMPOSE_LAYOUT_BEFORE_DEPLOYING_REMNAWAVE_OR_BOT'
