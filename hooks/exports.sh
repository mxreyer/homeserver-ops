#!/bin/bash
# ==============================================================================
# Script Name: hooks/exports.sh
# Description: borgmatic command hook. Runs exports/<service>.sh for every
#              service listed in WEB_SERVICES that has one. These write
#              database dumps and app-level exports into the service's data
#              directory, so they end up in the backup next to the raw data.
#
# Notes:
#   - Each export pings its own healthcheck HCHK_<SERVICE> (upper case, dashes
#     removed, e.g. HCHK_PAPERLESS) if set in CONFIG.sh.
#   - A failed export is reported there but does not fail the backup: the raw
#     data of that service is still backed up from the snapshot.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"
source "${SCRIPT_DIR}/lib/ping.sh"

for service in ${WEB_SERVICES:-}; do
  script="${SCRIPT_DIR}/exports/${service}.sh"
  [[ -x "$script" ]] || continue

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
