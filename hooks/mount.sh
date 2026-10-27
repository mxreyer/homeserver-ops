#!/bin/bash
# ==============================================================================
# Script Name: hooks/mount.sh
# Description: Drop-in for "mount" that borgmatic calls to mount each LVM
#              snapshot read-only (lvm: mount_command, set by backup.sh), as
#              "mount -o ro <device> <path>".
#
#              XFS (e.g. Fedora Server) refuses to mount a snapshot as is: it
#              carries the same filesystem UUID as the original, and a
#              read-only mount cannot replay the log. Add the options for that.
#              Any other file system is mounted unchanged.
# ==============================================================================

set -euo pipefail

device="${*: -2:1}"
mountpoint="${*: -1}"

if [[ "$(blkid -s TYPE -o value "$device" 2>/dev/null)" == xfs ]]; then
  exec mount -o ro,nouuid,norecovery "$device" "$mountpoint"
fi
exec mount "$@"
