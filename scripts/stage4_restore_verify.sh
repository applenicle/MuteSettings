#!/usr/bin/env bash
# Stage 4: Copy verified NL->PL snapshots to /var/backups/mutevpn on PL,
# then restore each into a temporary isolated PostgreSQL container.
# No production DB/container is modified; no VPN/bot/nginx restarts.
set -Eeuo pipefail
umask 077

PL_HOST="${PL_HOST:-192.144.78.148}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/mute_ha_ed25519}"
SNAPSHOT_ID="${1:-20261101T125729Z}"

if [[ ! "$SNAPSHOT_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  echo 'ERROR=INVALID_SNAPSHOT_ID' >&2
  exit 2
fi
if [[ ! -f "$SSH_KEY" ]]; then
  echo 'ERROR=SSH_KEY_NOT_FOUND' >&2
  exit 2
fi

echo "=== MUTEVPN STAGE 4: ISOLATED PL RESTORE VERIFICATION ==="
echo "SNAPSHOT_ID=$SNAPSHOT_ID"
echo "TARGET_PL=$PL_HOST"
echo 'PRODUCTION_CHANGES=NONE'
echo 'NOTE=RESTORE_ISOLATED_ONLY_NOT_A_CUTOVER'

ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=yes "root@$PL_HOST" 'bash -s' -- "$SNAPSHOT_ID" <<'REMOTE'
set -Eeuo pipefail
umask 077
SNAPSHOT_ID="$1"
SOURCE="/root/mute-ha-stage3-backups/$SNAPSHOT_ID"
DEST="/var/backups/mutevpn/snapshots/$SNAPSHOT_ID"

if [[ "$(id -u)" -ne 0 ]]; then echo 'ERROR=NOT_ROOT'; exit 2; fi
if [[ ! -f "$SOURCE/remnawave-pg18.dump" || ! -f "$SOURCE/mutebackend-pg17.dump" ]]; then
  echo 'ERROR=SOURCE_SNAPSHOTS_MISSING'; exit 2
fi
command -v docker >/dev/null || { echo 'ERROR=DOCKER_MISSING'; exit 2; }
docker info >/dev/null || { echo 'ERROR=DOCKER_DAEMON_UNAVAILABLE'; exit 2; }
free_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
if (( free_kb < 420000 )); then
  echo "ERROR=INSUFFICIENT_AVAILABLE_RAM_KB_$free_kb"; exit 2
fi
free_kb_disk=$(df -Pk /var | awk 'NR==2 {print $4}')
if (( free_kb_disk < 1048576 )); then
  echo "ERROR=INSUFFICIENT_DISK_FREE_KB_$free_kb_disk"; exit 2
fi

install -d -m 700 /var/backups/mutevpn /var/backups/mutevpn/snapshots
install -d -m 700 "$DEST"
for name in remnawave-pg18.dump mutebackend-pg17.dump; do
  src_sha=$(sha256sum "$SOURCE/$name" | awk '{print $1}')
  if [[ -e "$DEST/$name" ]]; then
    dst_sha=$(sha256sum "$DEST/$name" | awk '{print $1}')
    if [[ "$src_sha" != "$dst_sha" ]]; then
      echo "ERROR=EXISTING_BACKUP_MISMATCH_$name"; exit 2
    fi
  else
    install -m 600 "$SOURCE/$name" "$DEST/$name"
  fi
  dst_sha=$(sha256sum "$DEST/$name" | awk '{print $1}')
  [[ "$src_sha" == "$dst_sha" ]] || { echo "ERROR=SHA_MISMATCH_$name"; exit 2; }
  echo "BACKUP_COPY_$name=SHA256_VERIFIED"
done
chmod 700 "$DEST"

# One test container at a time; constrained resources, no network, no ports.
current_container=''
current_volume=''
cleanup() {
  rc=$?
  trap - EXIT
  if [[ -n "$current_container" ]]; then
    docker rm -f "$current_container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$current_volume" ]]; then
    docker volume rm "$current_volume" >/dev/null 2>&1 || true
  fi
  if (( rc != 0 )); then
    echo "STAGE4_FAILED_RC=$rc" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

restore_one() {
  local role="$1" major="$2" dump="$3" db="$4" mount="$5"
  local ident="${SNAPSHOT_ID//[^a-zA-Z0-9]/}"
  current_container="mute-stage4-${role}-${ident}"
  current_volume="mute_stage4_${role}_${ident}"
  echo "=== RESTORE_TEST=$role PG_MAJOR=$major ==="

  if docker container inspect "$current_container" >/dev/null 2>&1; then
    echo "ERROR=TEMP_CONTAINER_EXISTS_$role"; return 2
  fi
  if docker volume inspect "$current_volume" >/dev/null 2>&1; then
    echo "ERROR=TEMP_VOLUME_EXISTS_$role"; return 2
  fi

  docker volume create "$current_volume" >/dev/null
  docker run -d --rm --network none --memory 512m --cpus 0.75 --pids-limit 128 \
    --name "$current_container" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "$current_volume:$mount" \
    "postgres:$major" >/dev/null

  local ready=''
  for _ in $(seq 1 45); do
    if docker exec "$current_container" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      ready=yes
      break
    fi
    sleep 1
  done
  if [[ "$ready" != yes ]]; then
    echo "ERROR=TEST_POSTGRES_NOT_READY_$role"; return 1
  fi

  if [[ "$db" != postgres ]]; then
    docker exec "$current_container" createdb -U postgres "$db" >/dev/null
  fi

  # Passing data on stdin; neither PostgreSQL container is on a network.
  docker exec -i "$current_container" pg_restore -U postgres -d "$db" \
    --no-owner --no-acl --exit-on-error < "$DEST/$dump" >/dev/null

  local count
  count=$(docker exec "$current_container" psql -XAt -U postgres -d "$db" \
    -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';" \
    | tr -d '\r\n')
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || {
    echo "ERROR=RESTORED_TABLES_MISSING_$role"; return 1
  }
  echo "RESTORE_$role=PASS"
  echo "RESTORED_PUBLIC_TABLES_$role=$count"
  if [[ "$role" == mutebackend ]]; then
    if docker exec "$current_container" psql -XAt -U postgres -d "$db" -v ON_ERROR_STOP=1 \
      -c "SELECT to_regclass('public.subscription_links') IS NOT NULL;" | grep -qx t; then
      echo 'SUBSCRIPTION_LINKS_TABLE=FOUND'
    else
      echo 'ERROR=SUBSCRIPTION_LINKS_TABLE_MISSING'; return 1
    fi
  fi
  docker rm -f "$current_container" >/dev/null
  current_container=''
  docker volume rm "$current_volume" >/dev/null
  current_volume=''
}

restore_one remnawave 18 remnawave-pg18.dump postgres /var/lib/postgresql
restore_one mutebackend 17 mutebackend-pg17.dump mutevpn /var/lib/postgresql/data

# Old source copies intentionally kept until production migration is complete.
echo "VERIFIED_BACKUPS_DIR=$DEST"
echo 'OLD_ROOT_BACKUPS_PRESERVED=YES'
echo 'TEMP_CONTAINERS_REMOVED=YES'
echo 'PRODUCTION_UNCHANGED=YES'
echo 'STAGE4_RESTORE_VERIFIED=YES'
REMOTE
