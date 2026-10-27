#!/bin/bash
# ==============================================================================
# Script Name: lib/lock.sh
# Description: One lock shared by every job that stops, starts or updates
#              containers (backup.sh, auto-container-update.sh),
#              so they run one after another instead of fighting each other.
# ==============================================================================

LOCK_FILE="${LOCK_FILE:-/run/lock/homeserver-borgmatic.lock}"
LOCK_WAIT="${LOCK_WAIT:-14400}" # seconds to wait for a running job to finish

# Take the lock for the rest of the calling script's life. It is released
# automatically when the process exits, however it exits.
acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "⏳ Another job holds ${LOCK_FILE}; waiting up to ${LOCK_WAIT}s..."
    if ! flock -w "$LOCK_WAIT" 9; then
      echo "❌ Gave up waiting for ${LOCK_FILE}." >&2
      return 1
    fi
  fi
}
