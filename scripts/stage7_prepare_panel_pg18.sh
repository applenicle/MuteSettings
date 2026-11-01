#!/usr/bin/env bash
# MuteVPN Stage 7: create a NEW, disposable, network-isolated PG18 panel restore
# on PL, verify it, then stop it to release scarce RAM. NEVER changes existing
# PostgreSQL services, ingress, VPN nodes, bot, or NL production.
set -Eeuo pipefail
umask 077

SNAPSHOT_ID="${1:-20261101T125729Z}"
if [[ ! "$SNAPSHOT_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  echo 'ERROR=INVALID_SNAPSHOT_ID'; exit 2
fi
[[ "$(id -u)" == 0 ]] || { echo 'ERROR=REQUIRES_ROOT'; exit 2; }
[[ "$(hostname -s)" != node-27629 ]] || { echo 'ERROR=REFUSE_KNOWN_NL_PRODUCTION_HOST'; exit 2; }
command -v docker >/dev/null || { echo 'ERROR=DOCKER_MISSING'; exit 2; }
docker info >/dev/null 2>&1 || { echo 'ERROR=DOCKER_DAEMON_UNAVAILABLE'; exit 2; }

SOURCE="/root/mute-ha-stage3-backups/$SNAPSHOT_ID"
BACKUP="/var/backups/mutevpn/snapshots/$SNAPSHOT_ID/remnawave-pg18.dump"
DUMP_NAME='remnawave-pg18.dump'
CONTAINER='mutevpn-stage7-panel-pg18'
VOLUME='mutevpn_stage7_panel_pg18'
MARKER='/var/lib/mutevpn/stage7_panel_pg18.ready'
PASSFILE='/etc/mutevpn/stage7_panel_pg18.password'

printf '%s\n' '=== STAGE 7: PL REMNAWAVE PANEL DATABASE COLD PREPARATION ==='
echo "SNAPSHOT_ID=$SNAPSHOT_ID"
echo 'SOURCE_PRODUCTION=NL_UNCHANGED'
echo 'TARGET=PL_STAGING_VOLUME_ONLY'
echo 'PANEL_PROCESS_STARTED=NO BOT_STARTED=NO HTTP_PORTS_OPENED=NO'

[[ -s "$BACKUP" ]] || { echo 'ERROR=STAGE4_VERIFIED_DUMP_MISSING'; exit 2; }
[[ -r "$SOURCE/SHA256SUMS" ]] || { echo 'ERROR=ORIGINAL_SHA256_MANIFEST_MISSING'; exit 2; }
(cd "$SOURCE" && sha256sum -c --status SHA256SUMS) || { echo 'ERROR=ORIGINAL_BACKUP_SHA256_FAILED'; exit 2; }
[[ -s "$SOURCE/$DUMP_NAME" ]] || { echo 'ERROR=STAGE3_ORIGINAL_DUMP_MISSING'; exit 2; }
SRC_HASH="$(sha256sum "$SOURCE/$DUMP_NAME" | awk '{print $1}')"
BACKUP_HASH="$(sha256sum "$BACKUP" | awk '{print $1}')"
[[ "$SRC_HASH" == "$BACKUP_HASH" ]] || { echo 'ERROR=STAGE4_BACKUP_SHA256_MISMATCH'; exit 2; }
echo 'BACKUP_INTEGRITY=SHA256_MATCH'

available_mem="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
free_disk="$(df -Pk /var/lib/docker | awk 'END {print $4}')"
if (( available_mem < 700000 )); then
  echo "STOP=LESS_THAN_700000_KIB_AVAILABLE_RAM_$available_mem"; exit 2
fi
if (( free_disk < 4194304 )); then
  echo "STOP=LESS_THAN_4_GIB_FREE_DISK_$free_disk"; exit 2
fi

# Idempotent when this exact verified snapshot has already been restored.
if [[ -e "$MARKER" ]]; then
  IFS=' ' read -r existing_id existing_sha < "$MARKER" || true
  [[ "$existing_id" == "$SNAPSHOT_ID" && "$existing_sha" == "$BACKUP_HASH" ]] || {
    echo 'STOP=PREVIOUS_SNAPSHOT_MARKER_DIFFERS'; exit 2;
  }
  docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo 'STOP=STAGED_VOLUME_MISSING'; exit 2; }
  docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo 'STOP=STAGED_CONTAINER_MISSING'; exit 2; }
  stage_label="$(docker inspect -f '{{index .Config.Labels "mutevpn.stage"}}' "$CONTAINER")"
  status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER")"
  [[ "$stage_label" == '7' && "$status" == 'exited' ]] || {
    echo 'STOP=STAGED_CONTAINER_NOT_STOPPED_OR_NOT_OWNED'; exit 2;
  }
  echo 'STAGE7_ALREADY_PREPARED=YES'
  echo 'STAGED_DATABASE_STATE=STOPPED'
  echo 'CURRENT_PRODUCTION_UNCHANGED=YES'
  exit 0
fi

# Refuse reuse of unknown existing resources. No destructive migration actions.
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo 'STOP=STAGE7_CONTAINER_ALREADY_EXISTS_WITHOUT_MARKER'; exit 2
fi
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo 'STOP=STAGE7_VOLUME_ALREADY_EXISTS_WITHOUT_MARKER'; exit 2
fi

[[ -d /etc/mutevpn && -d /var/lib/mutevpn ]] || {
  echo 'ERROR=STAGE6_STANDARD_DIRECTORIES_MISSING'; exit 2;
}
if [[ -e "$PASSFILE" ]]; then
  echo 'STOP=STAGE7_PASSWORD_FILE_EXISTS_WITHOUT_COMPLETION_MARKER'; exit 2
fi
command -v openssl >/dev/null || { echo 'ERROR=OPENSSL_NOT_INSTALLED'; exit 2; }
# Directory is 0700; file is readable inside the isolated container through an
# explicit read-only bind mount. Never print this secret or put it into Git.
openssl rand -hex 32 > "$PASSFILE"
chmod 0444 "$PASSFILE"

created_volume=''
created_container=''
completed=0
cleanup() {
  rc=$?
  trap - EXIT
  if (( completed != 1 )); then
    if [[ -n "$created_container" ]]; then
      docker rm -f "$created_container" >/dev/null 2>&1 || true
    fi
    if [[ -n "$created_volume" ]]; then
      docker volume rm "$created_volume" >/dev/null 2>&1 || true
    fi
    rm -f "$PASSFILE"
    echo "STAGE7_FAILED_RC=$rc" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

echo '=== CREATE ISOLATED PG18.3 STAGING VOLUME ==='
docker volume create --label mutevpn.stage=7 --label mutevpn.component=remnawave "$VOLUME" >/dev/null
created_volume="$VOLUME"

docker run -d \
  --name "$CONTAINER" \
  --label mutevpn.stage=7 \
  --label mutevpn.component=remnawave \
  --network none \
  --restart no \
  --memory 320m \
  --memory-swap 512m \
  --cpus 0.55 \
  --pids-limit 128 \
  --security-opt no-new-privileges \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  --mount "type=bind,source=$PASSFILE,target=/run/secrets/postgres_password,readonly" \
  --mount "type=volume,source=$VOLUME,target=/var/lib/postgresql" \
  postgres:18.3 \
  -c shared_buffers=32MB -c max_connections=20 -c work_mem=4MB \
  >/dev/null
created_container="$CONTAINER"

ready=0
for i in $(seq 1 100); do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]] && \
    docker exec "$CONTAINER" pg_isready -q -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1 && \
    [[ "$(docker exec -u postgres "$CONTAINER" psql -XAt -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' 2>/dev/null | tr -d '\r\n')" == 1 ]]; then
    sleep 2
    ready=1
    break
  fi
  sleep 1
done
if (( ready != 1 )); then
  echo 'ERROR=PG18_STAGING_NOT_READY'; exit 1
fi
major="$(docker exec -u postgres "$CONTAINER" psql -XAt -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'SHOW server_version_num' | awk '{print int($1/10000)}')"
[[ "$major" == 18 ]] || { echo 'ERROR=UNEXPECTED_POSTGRES_MAJOR'; exit 1; }
echo 'STAGING_POSTGRES_18=READY_ISOLATED'

# Snapshot data comes exclusively from the already verified NL backup.
docker exec -i -u postgres "$CONTAINER" pg_restore -U postgres -d postgres \
  --no-owner --no-acl --single-transaction --exit-on-error < "$BACKUP" >/dev/null
count="$(docker exec -u postgres "$CONTAINER" psql -XAt -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';" | tr -d '\r\n')"
[[ "$count" =~ ^[0-9]+$ ]] && (( count >= 30 )) || {
  echo 'ERROR=REMWAVE_STAGING_TABLE_COUNT_UNEXPECTED'; exit 1;
}
echo "STAGING_REMNAWAVE_PUBLIC_TABLES=$count"

# Cold data preparation: stop staged DB so the 2 GiB PL machine keeps RAM free.
docker stop -t 30 "$CONTAINER" >/dev/null
[[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER")" == exited ]] || {
  echo 'ERROR=STAGING_DATABASE_NOT_STOPPED'; exit 1;
}
printf '%s %s\n' "$SNAPSHOT_ID" "$BACKUP_HASH" > "$MARKER.tmp"
chmod 0600 "$MARKER.tmp"
mv -f "$MARKER.tmp" "$MARKER"
completed=1

echo 'STAGED_DATABASE_STATE=STOPPED'
echo "STAGED_VOLUME_NAME=$VOLUME"
echo 'PANEL_PROCESS_STARTED=NO BOT_STARTED=NO HTTP_PORTS_OPENED=NO'
echo 'LIVE_PL_POSTGRES17_UNCHANGED=YES'
echo 'LIVE_PL_VPN_AND_NGINX_UNCHANGED=YES'
echo 'CURRENT_NL_PRODUCTION_UNCHANGED=YES'
echo 'FINAL_SYNC_STILL_REQUIRED=YES'
echo 'STAGE7_PANEL_DB_PREPARED=YES'
