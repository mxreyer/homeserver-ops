#!/bin/bash
# ==============================================================================
# Script Name: hooks/lvcreate.sh
# Description: Drop-in for "lvcreate" that borgmatic calls for each LVM
#              snapshot (lvm: lvcreate_command, set by backup.sh).
#
#              If LVM_SNAPSHOT_PVS lists physical volumes, each snapshot is
#              allocated on those of them that belong to the origin LV's
#              volume group (LVM cannot place a snapshot outside it). If none
#              of them does, LVM allocates anywhere in that volume group.
#
#              A listed PV that is not allocatable (reserved as snapshot
#              space, e.g. with "pvchange --allocatable n /dev/mmcblk0p1") is
#              opened only for the lvcreate call, then restored. PVs that are
#              allocatable anyway are left untouched.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# LVM_SNAPSHOT_PV is the older, single-PV name of the setting
read -ra configured <<< "${LVM_SNAPSHOT_PVS:-${LVM_SNAPSHOT_PV:-}}"
(( ${#configured[@]} > 0 )) || exec lvcreate "$@"

trim() { tr -d '[:space:]'; }

origin="${!#}" # borgmatic passes the origin LV last
origin_vg="$(lvs --noheadings -o vg_name "$origin" | trim)"

selected=() reopened=()
for pv in "${configured[@]}"; do
  if ! pv_vg="$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | trim)"; then
    echo "❌ LVM_SNAPSHOT_PVS: ${pv} is not a physical volume." >&2
    exit 1
  fi
  [[ "$pv_vg" == "$origin_vg" ]] && selected+=("$pv")
done

if (( ${#selected[@]} == 0 )); then
  echo "ℹ️  None of LVM_SNAPSHOT_PVS is in volume group ${origin_vg}; LVM picks the space for ${origin}."
  exec lvcreate "$@"
fi

# Put reserved PVs back the way they were, however lvcreate ends
restore() {
  local pv
  for pv in "${reopened[@]}"; do
    pvchange --allocatable n "$pv" > /dev/null || echo "⚠️  Could not reserve ${pv} again." >&2
  done
}
trap restore EXIT

for pv in "${selected[@]}"; do
  attr="$(pvs --noheadings -o pv_attr "$pv" | trim)"
  if [[ "$attr" != a* ]]; then
    pvchange --allocatable y "$pv" > /dev/null
    reopened+=("$pv")
  fi
done

lvcreate "$@" "${selected[@]}" # PVs to allocate on go after the origin LV
