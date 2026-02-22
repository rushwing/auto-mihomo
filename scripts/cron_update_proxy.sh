#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOCK_FILE="/tmp/auto-mihomo-update.lock"
LOG_FILE="${PROJECT_DIR}/cron-noon-update.log"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] skipped: update already running" >> "$LOG_FILE"
    exit 0
fi

cd "$PROJECT_DIR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] begin noon update" >> "$LOG_FILE"
if bash "${PROJECT_DIR}/scripts/update_sub.sh" --probe-strategy=best >> "$LOG_FILE" 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] success" >> "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] failed" >> "$LOG_FILE"
    exit 1
fi
