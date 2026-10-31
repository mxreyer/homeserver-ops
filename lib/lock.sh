#!/bin/bash
# ==============================================================================
# Script Name: lib/lock.sh
# Description: One lock shared by every job that stops, starts or updates
#              containers, so they run one after another instead of fighting
#              each other. auto-container-update.sh takes it with
#              acquire_lock; the backup takes the same file in its cron line
#              ("flock -w 14400 /run/homeserver-ops.lock borgmatic ...").
#              The file lives in /run (writable only by root), not in the
#              world-writable /run/lock: there, a lock file left by another
#              user cannot be opened even by root (fs.protected_regular), and
#              every job fails with "cannot open lock file: Permission denied".
# ==============================================================================

LOCK_FILE="${LOCK_FILE:-/run/homeserver-ops.lock}"
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
