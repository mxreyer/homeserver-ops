#!/bin/bash
# ==============================================================================
# Script Name: exports/immich.sh
# Description: Dumps the immich postgres database into the upload location,
#              following https://docs.immich.app/administration/backup-and-restore/
#
# Restore instructions : See the link above.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

# === Configuration ===
DUMP_DIR="${DOCKER_BINDS_DIR}/immich/library/database-backup"
DUMP_FILE="${DUMP_DIR}/immich-database.sql"

# === Dump database ===
# No "docker exec -t": a TTY turns every \n of the dump into \r\n.
# Dump to a temporary file first, so a failed dump never replaces the last good one.
echo "💩 dumping postgres database..."
mkdir -p "$DUMP_DIR"
docker exec immich-database-1 pg_dumpall --clean --if-exists --username=postgres > "${DUMP_FILE}.tmp"
mv "${DUMP_FILE}.tmp" "$DUMP_FILE"
echo "✅ Dumped database to ${DUMP_FILE}."
