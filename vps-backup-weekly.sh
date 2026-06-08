#!/bin/bash

HEALTHCHECK_ID="943c3111-2789-44dd-8d1a-3c27e8e1033b"
LOCK_FILE="/tmp/vps-backup.lock"
SRC="/home/tako4ball"
DEST="pcloud_crypt:vps-backup/latest"
WEEKLY_DIR="pcloud_crypt:vps-backup/weekly/$(date +%F)"
KEEP=4

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "[$(date)] Weekly backup already running, exiting."; exit 0; }

echo "[$(date)] Starting weekly snapshot"

rc=0
rclone copy "$SRC" "$DEST" \
  --backup-dir "$WEEKLY_DIR" \
  --local-no-check-updated \
  --ignore-errors \
  --stats 30s \
  --transfers 4 \
  --checkers 8 || rc=$?

echo "[$(date)] Weekly snapshot completed (exit=$rc)"

rclone lsf --dirs-only pcloud_crypt:vps-backup/weekly | sort -r | tail -n +$((KEEP + 1)) | while read dir; do
  dir="${dir%/}"
  echo "[$(date)] Removing old snapshot: $dir"
  rclone purge "pcloud_crypt:vps-backup/weekly/$dir" 2>&1
done

echo "[$(date)] Weekly snapshot rotation completed"

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID" > /dev/null 2>&1 || true
exit $rc
