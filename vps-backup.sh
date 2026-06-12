#!/bin/bash

HEALTHCHECK_ID="943c3111-2789-44dd-8d1a-3c27e8e1033b"
LOCK_FILE="/tmp/vps-backup.lock"
SRC="/home/tako4ball"
DEST="pcloud_crypt:vps-backup/latest"
SNAPSHOT_DIR="pcloud_crypt:vps-backup/snapshots/$(date +%F)"
KEEP=7

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "[$(date)] Backup already running, exiting."; exit 0; }

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID/start" > /dev/null 2>&1 || true

echo "[$(date)] Starting backup"

rc=0
rclone copy "$SRC" "$DEST" \
  --backup-dir "$SNAPSHOT_DIR" \
  --local-no-check-updated \
  --ignore-errors \
  --retries 1 \
  --stats 30s \
  --transfers 4 \
  --checkers 8 || rc=$?

echo "[$(date)] Backup completed (exit=$rc)"

# Rotate: keep last KEEP snapshots
rclone lsf --dirs-only pcloud_crypt:vps-backup/snapshots | sort -r | tail -n +$((KEEP + 1)) | while read dir; do
  dir="${dir%/}"
  echo "[$(date)] Removing old snapshot: $dir"
  rclone purge "pcloud_crypt:vps-backup/snapshots/$dir" 2>&1
done

echo "[$(date)] Snapshot rotation completed"

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID" > /dev/null 2>&1 || true
exit $rc
