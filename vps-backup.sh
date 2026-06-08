#!/bin/bash

HEALTHCHECK_ID="943c3111-2789-44dd-8d1a-3c27e8e1033b"
LOCK_FILE="/tmp/vps-backup.lock"
SRC="/home/tako4ball"
DEST="pcloud_crypt:vps-backup/latest"

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "[$(date)] Daily backup already running, exiting."; exit 0; }

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID/start" > /dev/null 2>&1 || true

echo "[$(date)] Starting daily backup"

rc=0
rclone copy "$SRC" "$DEST" \
  --local-no-check-updated \
  --ignore-errors \
  --stats 30s \
  --transfers 4 \
  --checkers 8 || rc=$?

echo "[$(date)] Daily backup completed (exit=$rc)"

curl -fsS -m 10 "https://hc-ping.com/$HEALTHCHECK_ID" > /dev/null 2>&1 || true
exit $rc
