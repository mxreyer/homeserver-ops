#!/bin/bash
# ==============================================================================
# Script Name: exports/mealie.sh
# Description : Calls the mealie API to create a backup and extracts the
#               resulting ZIP archive (extracted, so borg can deduplicate it).
#
# Preparation :
#   1. Get a mealie API key (APIKY_MEALIE in CONFIG.sh)
#
# Restore instructions :
#   1. Extract the backup folder from the borg archive.
#   2. Create zip archive backup.zip of its contents.
#   3. Upload to the mealie instance via web interface or API.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

# === Configuration ===
MEALIE_BACKUP_URL="https://mealie.${TS_DOMAIN}/api/admin/backups"
MEALIE_BACKUP_FOLDER="${DOCKER_BINDS_DIR}/mealie/export" # where mealie puts backups
BACKUP_DIR="${DOCKER_BINDS_DIR}/mealie/backup"

response=$(mktemp)
trap 'rm -f "$response"' EXIT

# Calls the API; the key goes to curl on stdin, so it never shows up in the
# process list. Prints the HTTP status, writes the body to $response.
api() {
  printf 'Authorization: Bearer %s\n' "${APIKY_MEALIE}" \
    | curl -s -w "%{http_code}" -o "$response" -X "$1" "$2" -H "Accept: application/json" -H @-
}

# Leftovers from an earlier failed run would be picked up as "the" backup
rm -rf "${MEALIE_BACKUP_FOLDER:?}"/*

# === Step 1: Trigger mealie backup ===
echo "💾 Requesting mealie backup..."
status=$(api POST "$MEALIE_BACKUP_URL")
if [[ "$status" != 201 ]]; then
  echo "❌ Failed to create backup (HTTP ${status}): $(cat "$response")" >&2
  exit 1
fi

# === Step 2: Extract generated backup ===
zipfiles=("${MEALIE_BACKUP_FOLDER}"/*.zip)
if (( ${#zipfiles[@]} != 1 )); then
  echo "❌ Expected exactly one backup .zip in ${MEALIE_BACKUP_FOLDER}, found ${#zipfiles[@]}." >&2
  exit 1
fi
zipfile="${zipfiles[0]}"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
unzip -q "$zipfile" -d "$BACKUP_DIR"
echo "✅ Extracted $(basename "$zipfile") to ${BACKUP_DIR}."

# === Step 3: Delete the backup inside mealie ===
status=$(api DELETE "${MEALIE_BACKUP_URL}/$(basename "$zipfile")")
if [[ "$status" != 200 ]]; then
  echo "❌ Failed to delete backup in mealie (HTTP ${status}): $(cat "$response")" >&2
  exit 1
fi
echo "✅ Export complete."
