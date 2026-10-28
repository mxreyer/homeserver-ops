#!/bin/bash
# ==============================================================================
# Script Name: hooks/exports.sh
# Description: borgmatic command hook. Runs exports/<project>.sh for every
#              running compose project that has one. These write database
#              dumps and app-level exports into the service's data directory,
#              so they end up in the backup next to the raw data.
#
# Notes:
#   - An export script is named after its compose project, e.g.
#     exports/immich.sh for the project "immich".
#   - Each export pings its own healthcheck HCHK_<PROJECT> (upper case, dashes
#     removed, e.g. HCHK_PAPERLESS) if set in CONFIG.sh. An export whose
#     project is not running is skipped without a ping, so that healthcheck
#     reports it as missing.
#   - A failed export is reported there but does not fail the backup: the raw
#     data of that service is still backed up.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"
source "${SCRIPT_DIR}/lib/ping.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

running="$(running_projects | cut -f1)"

for script in "${SCRIPT_DIR}"/exports/*.sh; do
  [[ -x "$script" ]] || continue
  service="$(basename "$script" .sh)"
  if ! grep -qxF "$service" <<< "$running"; then
    echo "ℹ️  Skipping export of ${service}: compose project not running."
    continue
  fi

  hchk_var="HCHK_${service^^}"
  hchk_var="${hchk_var//-/}"
  HEALTHCHECK_URL="${!hchk_var:-}"

  echo "----- 📤 Exporting ${service} -----"
  if "$script"; then
    echo "✅ Export of ${service} done."
    ping_success || true
  else
    echo "❌ Export of ${service} failed."
    ping_fail || true
  fi
done

exit 0
