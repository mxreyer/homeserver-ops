#!/bin/bash
# ==============================================================================
# Script Name: exports/beszel.sh
# Description : Calls the beszel API to create a backup and extracts the
#               resulting ZIP archive (extracted, so borg can deduplicate it).
#
# Preparation :
#   1. Get a beszel API key (APIKY_BESZEL in CONFIG.sh)
#
# Restore instructions :
#   1. Extract the backup folder from the borg archive. It contains a folder
#      `backup` and a file `backup.zip.attrs`.
#   2. Create zip archive backup.zip of the `backup` folder.
#   3. Upload backup.zip and backup.zip.attrs to the beszel instance via web
#      interface or API.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

# === Configuration ===
BESZEL_BACKUP_URL="https://beszel.${TS_DOMAIN}/api/backups"
BESZEL_BACKUP_FOLDER="${DOCKER_BINDS_DIR}/beszel/beszel_data/backups" # where beszel puts backups
BACKUP_DIR="${DOCKER_BINDS_DIR}/beszel/backup"

response=$(mktemp)
trap 'rm -f "$response"' EXIT

api_message() { jq -r '.message // ""' "$response" 2>/dev/null || cat "$response"; }

# Leftovers from an earlier failed run would be picked up as "the" backup
rm -rf "${BESZEL_BACKUP_FOLDER:?}"/*

# === Step 1: Trigger beszel backup ===
echo "💾 Requesting beszel backup..."
status=$(curl -s -w "%{http_code}" -o "$response" -X POST "$BESZEL_BACKUP_URL" \
  -H "Accept: application/json" -H "Authorization: Bearer ${APIKY_BESZEL}")
if [[ "$status" != 204 ]]; then
  echo "❌ Failed to create backup (HTTP ${status}): $(api_message)" >&2
  exit 1
fi

# === Step 2: Extract generated backup ===
zipfiles=("${BESZEL_BACKUP_FOLDER}"/*.zip)
if (( ${#zipfiles[@]} != 1 )); then
  echo "❌ Expected exactly one backup .zip in ${BESZEL_BACKUP_FOLDER}, found ${#zipfiles[@]}." >&2
  exit 1
fi
zipfile="${zipfiles[0]}"
attrsfile="${zipfile}.attrs"
if [[ ! -f "$attrsfile" ]]; then
  echo "❌ Missing ${attrsfile}" >&2
  exit 1
fi
rm -rf "$BACKUP_DIR"
mkdir -p "${BACKUP_DIR}/backup"
unzip -q "$zipfile" -d "${BACKUP_DIR}/backup"
cp "$attrsfile" "${BACKUP_DIR}/backup.zip.attrs"
echo "✅ Extracted $(basename "$zipfile") to ${BACKUP_DIR}."

# === Step 3: Delete the backup inside beszel ===
status=$(curl -s -w "%{http_code}" -o "$response" -X DELETE "${BESZEL_BACKUP_URL}/$(basename "$zipfile")" \
  -H "Accept: application/json" -H "Authorization: Bearer ${APIKY_BESZEL}")
if [[ "$status" != 204 ]]; then
  echo "❌ Failed to delete backup in beszel (HTTP ${status}): $(api_message)" >&2
  exit 1
fi
echo "✅ Export complete."
