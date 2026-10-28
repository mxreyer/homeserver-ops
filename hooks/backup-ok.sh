#!/bin/bash
# ==============================================================================
# Script Name: hooks/backup-ok.sh
# Description: borgmatic command hook, run after a successful backup. Records
#              its time in $STATE_DIR/last-backup-ok, which
#              auto-container-update.sh requires before updating anything.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

STATE_DIR="${STATE_DIR:-/var/lib/homeserver-ops}"
mkdir -p "$STATE_DIR"
touch "${STATE_DIR}/last-backup-ok"
