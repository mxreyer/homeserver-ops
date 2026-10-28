#!/bin/bash
# ==============================================================================
# Script Name: hooks/containers.sh
# Description: borgmatic command hook. Usage: containers.sh stop|start
#
#   stop   Stops all running containers (with CONTAINER_STOP_TIMEOUT) right
#          before each repository's archive is created, so their data is
#          backed up in a cleanly shut-down state. Fails if anything did not
#          stop, which makes borgmatic abort before archiving.
#   start  Starts them again. Idempotent; run after the create action, on
#          error and on exit of backup.sh, so containers always come back.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

STATE_DIR="${STATE_DIR:-/var/lib/homeserver-ops}"
STOPPED_FILE="${STATE_DIR}/stopped-containers"

case "${1:-}" in
  stop)
    mkdir -p "$STATE_DIR"
    stop_containers "$STOPPED_FILE"
    ;;
  start)
    start_containers "$STOPPED_FILE"
    ;;
  *)
    echo "Usage: $0 stop|start" >&2
    exit 1
    ;;
esac
