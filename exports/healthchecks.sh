#!/bin/bash
# ==============================================================================
# Script Name: exports/healthchecks.sh
# Description: Dumps the healthchecks postgres database into the service's
#              bind directory.
#
# Restore instructions:
#     - Start the db container alone (without the web container), read in the
#       database dump, then start the web container.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

# === Configuration ===
DUMP_DIR="${DOCKER_BINDS_DIR}/healthchecks/backup"
DUMP_FILE="${DUMP_DIR}/healthchecks_postgres_dump.sql"

# === Dump database ===
# No "docker exec -t": a TTY turns every \n of the dump into \r\n.
# Dump to a temporary file first, so a failed dump never replaces the last good one.
echo "💩 dumping postgres database..."
mkdir -p "$DUMP_DIR"
docker exec healthchecks-db-1 pg_dumpall --clean --if-exists --username=postgres > "${DUMP_FILE}.tmp"
mv "${DUMP_FILE}.tmp" "$DUMP_FILE"
echo "✅ Dumped database to ${DUMP_FILE}."
