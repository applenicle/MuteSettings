#!/usr/bin/env bash
# MuteVPN / MuteSettings - Stage 4, revision 2.
# Copies already verified NL snapshots on PL to /var/backups/mutevpn;
# validates them in disposable, network-isolated PG18 + PG17 containers.
# Never updates an existing database, starts production processes or changes ingress.
set -Eeuo pipefail
umask 077

PL_HOST="${PL_HOST:-192.144.78.148}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/mute_ha_ed25519}"
SNAPSHOT_ID="${1:-20261101T125729Z}"

if [[ ! "$SNAPSHOT_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  echo 'ERROR=INVALID_SNAPSHOT_ID' >&2; exit 2
fi
if [[ ! -r "$SSH_KEY" ]]; then
  echo 'ERROR=SSH_KEY_NOT_READABLE' >&2; exit 2
fi

echo '=== MUTEVPN STAGE 4 V2: ISOLATED RESTORE VERIFICATION ==='
echo "SNAPSHOT_ID=$SNAPSHOT_ID"
echo "TARGET_PL=$PL_HOST"
echo 'PRODUCTION_CHANGES=NONE'
echo 'POSTGRES_READY_CHECK=FINAL_TCP_SERVER_NOT_INITDB_TEMP_SOCKET'

ssh -T -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes \
  -o ConnectTimeout=12 -o StrictHostKeyChecking=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "root@$PL_HOST" 'bash -s --' "$SNAPSHOT_ID" <<'REMOTE'
set -Eeuo pipefail
umask 077

SNAPSHOT_ID="${1:?Missing snapshot ID}"
SOURCE="/root/mute-ha-stage3-backups/$SNAPSHOT_ID"
DEST="/var/backups/mutevpn/snapshots/$SNAPSHOT_ID"

[[ "$(id -u)" -eq 0 ]] || { echo 'ERROR=REMOTE_USER_NOT_ROOT'; exit 2; }
command -v docker >/dev/null || { echo 'ERROR=DOCKER_NOT_INSTALLED'; exit 2; }
docker info >/dev/null 2>&1 || { echo 'ERROR=DOCKER_UNAVAILABLE'; exit 2; }
for name in remnawave-pg18.dump mutebackend-pg17.dump; do
  [[ -s "$SOURCE/$name" ]] || { echo "ERROR=MISSING_DUMP_$name"; exit 2; }
done

# The original Stage 3 job wrote a checksum manifest on PL.
if [[ -r "$SOURCE/SHA256SUMS" ]]; then
  (cd "$SOURCE" && sha256sum --check --status SHA256SUMS) || {
    echo 'ERROR=ORIGINAL_STAGE3_SHA256_CHECK_FAILED'; exit 2;
  }
  echo 'STAGE3_SOURCE_MANIFEST=SHA256_VERIFIED'
else
  echo 'WARN=STAGE3_SOURCE_MANIFEST_MISSING_CHECK_AGAINST_COPIED_FILE_ONLY'
fi

available_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
free_disk_kb="$(df -Pk /var | awk 'NR==2 {print $4}')"
if (( available_kb < 650000 )); then
  echo "STOP=LOW_AVAILABLE_RAM_KB_$available_kb"; exit 2
fi
if (( free_disk_kb < 2097152 )); then
  echo "STOP=LESS_THAN_2_GIB_FREE_ON_PL_KB_$free_disk_kb"; exit 2
fi

install -d -m 700 /var/backups/mutevpn /var/backups/mutevpn/snapshots "$DEST"
for name in remnawave-pg18.dump mutebackend-pg17.dump; do
  src_sha="$(sha256sum "$SOURCE/$name" | awk '{print $1}')"
  if [[ ! -e "$DEST/$name" ]]; then
    install -m 600 "$SOURCE/$name" "$DEST/$name"
  fi
  dst_sha="$(sha256sum "$DEST/$name" | awk '{print $1}')"
  [[ "$src_sha" == "$dst_sha" ]] || {
    echo "ERROR=DESTINATION_CHECKSUM_MISMATCH_$name"; exit 2;
  }
  chmod 600 "$DEST/$name"
  echo "BACKUP_COPY_$name=SHA256_VERIFIED"
done

# Unique names + ownership flags make cleanup safe even on reruns/failed attempts.
active_container=''
active_volume=''
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$active_container" ]]; then
    docker rm -f "$active_container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$active_volume" ]]; then
    docker volume rm "$active_volume" >/dev/null 2>&1 || true
  fi
  if (( result != 0 )); then
    echo "STAGE4_FAILED_RC=$result" >&2
  fi
  exit "$result"
}
trap cleanup EXIT

ready_query() {
  local c="$1"
  # Entrypoint's temporary initdb server listens on Unix socket only.
  # TCP 127.0.0.1 (inside the no-network container) becomes reachable
  # only when the final production postgres process has started.
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" == true ]] || return 1
  docker exec "$c" pg_isready -q -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1 || return 1
  [[ "$(docker exec "$c" psql -h 127.0.0.1 -XAt \
     -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' 2>/dev/null | tr -d '\r\n')" == 1 ]]
}

restore_one() {
  local role="$1" pg_major="$2" filename="$3" db_name="$4" volume_mount="$5"
  local run_id c vol ready='' i major count
  run_id="$(date -u +%s%N)-$$-$RANDOM"
  c="mute-stage4-${role}-${run_id}"
  vol="mute_stage4_${role}_${run_id}"

  echo "=== RESTORE_TEST=$role PG_MAJOR=$pg_major ==="
  docker volume create "$vol" >/dev/null
  active_volume="$vol"
  docker run -d --rm --network none --memory 512m --cpus 0.60 --pids-limit 128 \
    --name "$c" -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "$vol:$volume_mount" "postgres:$pg_major" \
    -c shared_buffers=32MB -c max_connections=20 >/dev/null
  active_container="$c"

  for ((i=1; i<=90; i++)); do
    if ready_query "$c"; then
      # Guard against startup transitions; do not accept a single early success.
      sleep 2
      if ready_query "$c"; then ready=yes; break; fi
    fi
    sleep 1
  done
  if [[ "$ready" != yes ]]; then
    echo "ERROR=TEMP_POSTGRES_FINAL_SERVER_NOT_READY_$role"
    echo "TEMP_CONTAINER_STATUS_$role=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo removed)"
    echo "TEMP_CONTAINER_OOM_$role=$(docker inspect -f '{{.State.OOMKilled}}' "$c" 2>/dev/null || echo unknown)"
    # Only counts of diagnostic keywords; do not expose raw service logs.
    startup_errors="$(docker logs --tail 80 "$c" 2>&1 | grep -Eic 'fatal|error|permission denied|no space left|out of memory' || true)"
    echo "TEMP_POSTGRES_STARTUP_ERROR_LINES_$role=$startup_errors"
    return 1
  fi
  echo "PG_FINAL_TCP_READY_$role=YES"

  major="$(docker exec "$c" psql -h 127.0.0.1 -XAt -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -c 'SHOW server_version_num' | awk '{print int($1/10000)}')"
  [[ "$major" == "$pg_major" ]] || {
    echo "ERROR=WRONG_PG_MAJOR_$role"; return 1;
  }
  if [[ "$db_name" != postgres ]]; then
    docker exec "$c" createdb -h 127.0.0.1 -U postgres "$db_name"
  fi
  docker exec -i "$c" pg_restore -h 127.0.0.1 -U postgres -d "$db_name" \
    --no-owner --no-acl --single-transaction --exit-on-error \
    < "$DEST/$filename" >/dev/null

  count="$(docker exec "$c" psql -h 127.0.0.1 -XAt -U postgres -d "$db_name" \
    -v ON_ERROR_STOP=1 -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';" | tr -d '\r\n')"
  [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) || {
    echo "ERROR=RESTORED_PUBLIC_TABLES_MISSING_$role"; return 1;
  }
  echo "RESTORE_$role=PASS"
  echo "RESTORED_PUBLIC_TABLES_$role=$count"

  if [[ "$role" == mutebackend ]]; then
    if [[ "$(docker exec "$c" psql -h 127.0.0.1 -XAt -U postgres -d "$db_name" \
      -v ON_ERROR_STOP=1 -c "SELECT to_regclass('public.subscription_links') IS NOT NULL;" | tr -d '\r\n')" == t ]]; then
      echo 'SUBSCRIPTION_LINKS_TABLE=FOUND'
    else
      echo 'ERROR=SUBSCRIPTION_LINKS_TABLE_MISSING'; return 1
    fi
  fi
  docker rm -f "$c" >/dev/null
  active_container=''
  docker volume rm "$vol" >/dev/null
  active_volume=''
  echo "TEMP_${role}_REMOVED=YES"
}

# PG 18 official image volume is /var/lib/postgresql (not /data).
restore_one remnawave 18 remnawave-pg18.dump postgres /var/lib/postgresql
restore_one mutebackend 17 mutebackend-pg17.dump mutevpn /var/lib/postgresql/data

echo "VERIFIED_BACKUPS_DIR=$DEST"
echo 'OLD_ROOT_BACKUPS_PRESERVED=YES'
echo 'TEMP_CONTAINERS_REMOVED=YES'
echo 'PRODUCTION_UNCHANGED=YES'
echo 'STAGE4_RESTORE_VERIFIED=YES'
REMOTE
