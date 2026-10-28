#!/bin/bash
# ==============================================================================
# Script Name: backup.sh
# Description: Back up the server, including all docker volumes and bind
#              mounts, with borgmatic (see borgmatic/config.yaml). Containers
#              are stopped while each archive is written. The OS file systems
#              are snapshotted where the host supports it (SNAPSHOTS in
#              CONFIG.sh): LVM (e.g. Ubuntu, Fedora Server), Btrfs (e.g.
#              Fedora Workstation), or none (e.g. Raspberry Pi OS).
#
# Usage:
#   backup.sh                 create, prune, compact and (when due) check.
#                             Schedule this in root's crontab, e.g.
#                             0 3 * * * <scriptdir>/backup.sh >> <logs_dir>/backup.log 2>&1
#   backup.sh <borgmatic args>
#                             any other borgmatic action against the same
#                             config, e.g. "repo-list", "mount --archive latest
#                             --mount-point /mnt/restore", "extract ...",
#                             "repo-create --encryption repokey", "key export".
#
# Preparation: see README.md
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"
source "${SCRIPT_DIR}/lib/lock.sh"
source "${SCRIPT_DIR}/lib/ping.sh"
HEALTHCHECK_URL="${HCHK_SERVER_BACKUP:-}"

STATE_DIR="${STATE_DIR:-/var/lib/homeserver-ops}"
PATTERNS_FILE="${STATE_DIR}/patterns"
BORGMATIC_CONFIG="${STATE_DIR}/borgmatic.yaml" # generated; includes borgmatic/config.yaml
LAST_SUCCESS_FILE="${STATE_DIR}/last-backup-ok"

# Variables interpolated into borgmatic/config.yaml and used by the hooks
export SCRIPT_DIR STATE_DIR PATTERNS_FILE BACKUP_LOC BACKUP_SSH HCHK_SERVER_BACKUP
export BORG_REPO_NAME="${BORG_REPO_NAME:-homeserver}"
export BORG_PASS_FILE="${BORG_PASS_FILE:-${SCRIPT_DIR}/.borg-pass}"
SNAPSHOTS="${SNAPSHOTS:-auto}"
LVM_SNAPSHOT_SIZE="${LVM_SNAPSHOT_SIZE:-10G}"

# Split the space-separated lists from CONFIG.sh without expanding globs
read -ra add_srcs <<< "${ADD_SERVER_BACKUP_SOURCES:-}"
read -ra add_excl <<< "${ADD_SERVER_BACKUP_EXCLSNS:-}"

# Server directories to back up; docker's own data under /var/lib/docker is
# excluded below, except for the volumes
BACKUP_SRCS=(/etc /home /root /usr/local /opt /var/lib /var/spool/cron /boot /mnt
             "${DOCKER_BINDS_DIR:-}" "${DOCKER_VOL_LOC:-}" "${add_srcs[@]}")
BACKUP_EXCL=(/var/lib/containers /var/lib/containerd /var/lib/rancher/k3s/agent
             /var/lib/flatpak /var/lib/systemd /var/lib/kubelet /var/cache /var/tmp
             /mnt/backup "${BACKUP_LOC:-}" "$STATE_DIR"
             "${DOCKER_BINDS_DIR:-}/immich/library/thumbs"
             "${DOCKER_BINDS_DIR:-}/immich/library/encoded-video"
             "${add_excl[@]}")
# File systems whose nested mounts get backed up (others are virtual or remote)
BACKUP_FSTYPES="ext2 ext3 ext4 xfs btrfs f2fs vfat exfat"

# For failures before borgmatic runs; borgmatic itself pings HCHK_SERVER_BACKUP
die() { echo "❌ $*" >&2; ping_fail || true; exit 1; }

version_at_least() { [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]; }

# Is path $1 equal to or below one of the paths $2...?
is_under() {
  local path="$1" other
  shift
  for other in "$@"; do
    [[ "$path" == "$other" || "$path" == "$other"/* ]] && return 0
  done
  return 1
}

check_requirements() {
  [[ $EUID -eq 0 ]] || die "Must run as root (sudo $0)."
  command -v borgmatic > /dev/null || die "borgmatic is not installed (see README.md)."
  command -v borg > /dev/null || die "borg is not installed (see README.md)."
  version_at_least "$(borgmatic --version)" 2.0 || die "borgmatic >= 2.0 required."
  version_at_least "$(borg --version | awk '{print $2}')" 1.4 || die "borg >= 1.4 required."
  local var
  for var in BACKUP_LOC BACKUP_SSH HCHK_SERVER_BACKUP; do
    [[ -n "${!var:-}" ]] || die "${var} is not set in CONFIG.sh."
  done
  [[ -s "$BORG_PASS_FILE" ]] || die "Missing or empty passfile: ${BORG_PASS_FILE}"
}

# Write the borg patterns file: one root per source directory, plus one per
# real file system mounted below it (one_file_system keeps borg from crossing
# into them otherwise), followed by the excludes.
write_patterns() {
  local roots=() excl=() src mnt fstype docker_root entry

  for src in "${BACKUP_EXCL[@]}"; do
    [[ -n "$src" ]] && excl+=("${src%/}")
  done
  # Exclude everything docker keeps besides the volumes (images, containers,
  # build cache...), whatever the docker version calls those directories
  if [[ -n "${DOCKER_VOL_LOC:-}" ]]; then
    docker_root="$(dirname "${DOCKER_VOL_LOC%/}")"
    for entry in "$docker_root"/*; do
      [[ "$entry" == "${DOCKER_VOL_LOC%/}" ]] || excl+=("$entry")
    done
    # Nextcloud AIO backs itself up with its own borg
    excl+=("${DOCKER_VOL_LOC%/}/nextcloud_aio_*")
  fi

  for src in "${BACKUP_SRCS[@]}"; do
    [[ -n "$src" ]] || continue
    src="${src%/}"
    if [[ ! -e "$src" ]]; then
      echo "⚠️  Skipping missing source ${src}"
      continue
    fi
    roots+=("$src")
    while read -r mnt fstype; do
      mnt="$(printf '%b' "$mnt")" # findmnt -r escapes blanks as \x20
      [[ " $BACKUP_FSTYPES " == *" $fstype "* ]] && roots+=("$mnt")
    done < <(findmnt -rn -o TARGET,FSTYPE | awk -v s="$src" 'index($1, s "/") == 1')
  done

  {
    echo "# Generated by backup.sh on $(date). Do not edit."
    printf '%s\n' "${roots[@]}" | sort -u | while read -r src; do
      # A root inside an excluded path or inside another root on the same
      # file system would be stored twice or against the excludes
      is_under "$src" "${excl[@]}" && continue
      local parent
      parent="$(dirname "$src")"
      while [[ "$parent" != / ]]; do
        if printf '%s\n' "${roots[@]}" | grep -qxF "$parent" \
          && [[ "$(stat -c %d "$parent")" == "$(stat -c %d "$src")" ]]; then
          continue 2
        fi
        parent="$(dirname "$parent")"
      done
      echo "R ${src}"
    done
    for src in "${excl[@]}"; do
      if [[ "$src" == *[*?[]* ]]; then
        echo "! sh:${src}"
      else
        echo "! pp:${src}"
      fi
    done
  } > "$PATTERNS_FILE"
}

# Print the snapshot backends to use ("lvm", "btrfs"; none if empty).
# With SNAPSHOTS=auto: lvm if a root sits on an LVM logical volume, btrfs if a
# root is on btrfs, each only if its tools are installed. borgmatic's btrfs
# support must not be enabled on hosts without btrfs-progs, so only the
# backends that apply are ever switched on.
snapshot_backends() {
  local root fstype src found=() missing=()
  if [[ "$SNAPSHOTS" != auto ]]; then
    for src in $SNAPSHOTS; do
      [[ " lvm btrfs none " == *" $src "* ]] || die "Unknown SNAPSHOTS value: ${src}"
      [[ "$src" == none ]] || found+=("$src")
    done
  else
    while read -r root; do
      fstype="$(findmnt -n -o FSTYPE --target "$root")"
      src="$(findmnt -n -o SOURCE --target "$root")"
      src="${src%%\[*}" # strip btrfs subvolume suffix like [/root]
      if [[ "$fstype" == btrfs ]]; then
        if command -v btrfs > /dev/null; then found+=(btrfs); else missing+=(btrfs-progs); fi
      fi
      if [[ "$(lsblk -dno TYPE "$src" 2>/dev/null)" == lvm ]]; then
        if command -v lvcreate > /dev/null; then found+=(lvm); else missing+=(lvm2); fi
      fi
    done < <(sed -n 's/^R //p' "$PATTERNS_FILE")
  fi
  if (( ${#missing[@]} > 0 )); then
    for src in $(printf '%s\n' "${missing[@]}" | sort -u); do
      echo "⚠️  Backed-up file systems could be snapshotted, but ${src} is not installed." >&2
    done
  fi
  if (( ${#found[@]} > 0 )); then printf '%s\n' "${found[@]}" | sort -u | tr '\n' ' '; fi
}

# Write the borgmatic config: borgmatic/config.yaml plus the snapshot
# settings that fit this host
write_config() {
  local backends
  backends="$(snapshot_backends)"
  echo "📸 Snapshots: ${backends:-none (backing up the live file systems)}"
  {
    echo "# Generated by backup.sh on $(date). Do not edit."
    echo "<<: !include ${SCRIPT_DIR}/borgmatic/config.yaml"
    if [[ " $backends " == *" lvm "* ]]; then
      echo "lvm:"
      echo "    snapshot_size: ${LVM_SNAPSHOT_SIZE}"
      echo "    lvcreate_command: ${SCRIPT_DIR}/hooks/lvcreate.sh"
      echo "    mount_command: ${SCRIPT_DIR}/hooks/mount.sh"
    fi
    if [[ " $backends " == *" btrfs "* ]]; then
      echo "btrfs:"
    fi
  } > "$BORGMATIC_CONFIG"
}

check_requirements
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
write_patterns
write_config

if (( $# > 0 )); then
  exec borgmatic --config "$BORGMATIC_CONFIG" "$@"
fi

echo "----- 💾 Running backup at $(date) ⏰ -----"
acquire_lock
# Whatever happens, never leave containers stopped
trap '"${SCRIPT_DIR}/hooks/containers.sh" start' EXIT

borgmatic --config "$BORGMATIC_CONFIG" --verbosity 1
touch "$LAST_SUCCESS_FILE"
echo "✅ Backup complete."
