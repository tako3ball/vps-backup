#!/bin/bash
set -e

HEALTHCHECK_ID="943c3111-2789-44dd-8d1a-3c27e8e1033b"
LOG_FILE="/home/tako4ball/.local/share/vps-backup/backup.log"
LOCK_FILE="/tmp/vps-backup.lock"
SRC="/home/tako4ball"
DEST="pcloud_crypt:vps-backup/latest"
WEEKLY_DIR="pcloud_crypt:vps-backup/weekly/$(date +%F)"
KEEP=4

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "[$(date)] Weekly backup already running, exiting." >> "$LOG_FILE"; exit 0; }

echo "[$(date)] Starting weekly snapshot" >> "$LOG_FILE"

rclone copy "$SRC" "$DEST" \
  --backup-dir "$WEEKLY_DIR" \
  --log-file="$LOG_FILE" \
  --log-level INFO \
  --stats 30s \
  --transfers 4 \
  --checkers 8

echo "[$(date)] Weekly snapshot completed" >> "$LOG_FILE"

rclone lsf --dirs-only pcloud_crypt:vps-backup/weekly | sort -r | tail -n +$((KEEP + 1)) | while read dir; do
  dir="${dir%/}"
  echo "[$(date)] Removing old snapshot: $dir" >> "$LOG_FILE"
  rclone purge "pcloud_crypt:vps-backup/weekly/$dir" >> "$LOG_FILE" 2>&1
done

echo "[$(date)] Weekly snapshot rotation completed" >> "$LOG_FILE"

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID" > /dev/null 2>&1 || true
