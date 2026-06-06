#!/bin/bash
set -e

HEALTHCHECK_ID="943c3111-2789-44dd-8d1a-3c27e8e1033b"
LOG_FILE="/home/tako4ball/.local/share/vps-backup/backup.log"
LOCK_FILE="/tmp/vps-backup.lock"
SRC="/home/tako4ball"
DEST="pcloud_crypt:vps-backup/latest"

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "[$(date)] Daily backup already running, exiting." >> "$LOG_FILE"; exit 0; }

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID/start" > /dev/null 2>&1 || true

echo "[$(date)] Starting daily backup" >> "$LOG_FILE"

rclone copy "$SRC" "$DEST" \
  --log-file="$LOG_FILE" \
  --log-level INFO \
  --stats 30s \
  --transfers 4 \
  --checkers 8

echo "[$(date)] Daily backup completed" >> "$LOG_FILE"

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID" > /dev/null 2>&1 || true
