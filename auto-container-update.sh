#!/bin/bash
# ==============================================================================
# Script Name: auto-container-update.sh
# Description: Pulls new images for all running docker compose projects and
#              recreates only the containers whose image changed, then removes
#              unused images. Refuses to run unless backup.sh succeeded within
#              the last MAX_BACKUP_AGE_H hours, so there is always a fresh
#              backup to roll back to. Should be run from root's crontab after
#              the backup, e.g.
#              30 4 * * 1 <scriptdir>/auto-container-update.sh >> <logs_dir>/auto-container-update.log 2>&1
#
# Usage: auto-container-update.sh [--force]   (--force skips the backup check)
#
# Notes:
#   - Pin major versions in your compose files (e.g. postgres:16), so this
#     only applies minor updates; do major upgrades by hand.
#   - Nextcloud AIO updates itself through its mastercontainer.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"
source "${SCRIPT_DIR}/lib/lock.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/ping.sh"

# === Configuration === #
HEALTHCHECK_URL="${HCHK_CONTAINER_UPDATE:-}"
STATE_DIR="${STATE_DIR:-/var/lib/homeserver-ops}"
LAST_SUCCESS_FILE="${STATE_DIR}/last-backup-ok"
MAX_BACKUP_AGE_H=26

on_error() {
  echo "❌ Update failed."
  ping_fail || true
}
trap on_error ERR

# === Script logic === #
echo "----- ⬆️  Updating containers at $(date) ⏰ -----"

if [[ "${1:-}" != "--force" ]]; then
  if [[ -z "$(find "$LAST_SUCCESS_FILE" -mmin -$(( MAX_BACKUP_AGE_H * 60 )) 2>/dev/null)" ]]; then
    echo "❌ No successful backup in the last ${MAX_BACKUP_AGE_H}h (${LAST_SUCCESS_FILE}); not updating." >&2
    false
  fi
fi

acquire_lock
update_projects
docker image prune -f

ping_success || exit 1
echo "✅ Updates complete."
