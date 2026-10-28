#!/bin/bash
# ==============================================================================
# Script Name: server-health-ping.sh
# Description : Ping healthcheck to signal that server is alive. Should be
#               scheduled with cron, e.g.
#               0 * * * * /bin/bash -c '<scriptdir>/server-health-ping.sh >> <logs_dir>/server-health-ping.log 2>&1'
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

source "${SCRIPT_DIR}/lib/ping.sh"

# === Configuration ===
HEALTHCHECK_URL="$HCHK_SERVER_PING"

echo "----- 🛜 Pinging healthcheck at $(date) ⏰ -----"

ping_success || exit 1
echo "✅ Healthcheck ping successful!"
