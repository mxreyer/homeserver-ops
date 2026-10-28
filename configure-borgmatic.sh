#!/bin/bash
# ==============================================================================
# Script Name: configure-borgmatic.sh
# Description: Generates borgmatic's config from borgmatic/config.template.yaml
#              and the backup settings in CONFIG.sh, validates it and installs
#              it as /etc/borgmatic/config.yaml (shows the changes first).
#
# Usage: sudo ./configure-borgmatic.sh
#        Run it once during setup, and again after changing CONFIG.sh or
#        pulling updates of this repository. The backup itself (cron) calls
#        borgmatic directly and does not need this script.
#        BORGMATIC_CONFIG_FILE=<path> writes somewhere else (e.g. for testing).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

TEMPLATE="${SCRIPT_DIR}/borgmatic/config.template.yaml"
TARGET="${BORGMATIC_CONFIG_FILE:-/etc/borgmatic/config.yaml}"
BORG_PASS_FILE="${BORG_PASS_FILE:-${SCRIPT_DIR}/.borg-pass}"
REPO_DIR="$SCRIPT_DIR"

die() { echo "❌ $*" >&2; exit 1; }

# === Check the settings ===
command -v envsubst > /dev/null \
  || die "envsubst is missing: install gettext-base (Debian, Ubuntu, Pi OS) or gettext-envsubst (Fedora)."
for var in BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP DOCKER_BINDS_DIR; do
  [[ -n "${!var:-}" ]] || die "${var} is not set in CONFIG.sh."
done
[[ -d "$DOCKER_BINDS_DIR" ]] || die "DOCKER_BINDS_DIR does not exist: ${DOCKER_BINDS_DIR}"
[[ -s "$BORG_PASS_FILE" ]] || die "Missing or empty passphrase file: ${BORG_PASS_FILE}"
# Values are inserted into single-quoted YAML strings and borgmatic commands
for var in BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP DOCKER_BINDS_DIR \
           BORG_PASS_FILE REPO_DIR EXTRA_BACKUP_DIRS EXTRA_EXCLUDES; do
  [[ "${!var:-}" != *[\'$'\n']* ]] || die "${var} must not contain quotes or line breaks."
done
for var in BORG_PASS_FILE REPO_DIR; do
  [[ "${!var}" != *[[:space:]]* ]] || die "${var} must not contain spaces: ${!var}"
done

# === Fill the template ===
# Turn a space-separated list into YAML list items (globs are kept, not expanded)
yaml_list() {
  local items item
  read -ra items <<< "$1"
  for item in "${items[@]}"; do printf "    - '%s'\n" "$item"; done
}
EXTRA_BACKUP_DIRS_YAML="$(yaml_list "${EXTRA_BACKUP_DIRS:-}")"
EXTRA_EXCLUDES_YAML="$(yaml_list "${EXTRA_EXCLUDES:-}")"
BORG_REPO_EXCLUDE="$BORG_REPO_LOCAL" # refined below
export BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP DOCKER_BINDS_DIR \
       BORG_PASS_FILE REPO_DIR EXTRA_BACKUP_DIRS_YAML EXTRA_EXCLUDES_YAML BORG_REPO_EXCLUDE

# Only these variables are replaced; anything else in ${...} form is left in
# place and caught below (borgmatic's validation does not notice it)
render() {
  # shellcheck disable=SC2016 # the variable names are meant literally here
  envsubst '${BORG_REPO_LOCAL} ${BORG_REPO_OFFSITE} ${HCHK_SERVER_BACKUP} ${DOCKER_BINDS_DIR}
            ${BORG_PASS_FILE} ${REPO_DIR} ${EXTRA_BACKUP_DIRS_YAML} ${EXTRA_EXCLUDES_YAML}
            ${BORG_REPO_EXCLUDE}' < "$TEMPLATE"
}

# Print the source_directories of a rendered config, one per line
source_dirs() {
  awk '/^source_directories:/ {in_list = 1; next}
       in_list && /^ *- / {sub(/^ *- */, ""); sub(/ +#.*/, ""); gsub(/\047/, ""); print; next}
       in_list && /^[^ #]/ {in_list = 0}' "$1"
}

# What to exclude for the local repository: the whole mount point when the
# repository is on a separate disk, so nothing else on that disk (e.g. old
# repositories) gets backed up; just the repository directory when its file
# system also holds backed-up data (the root file system, /home, ...).
repo_exclude() {
  local path="$BORG_REPO_LOCAL" mnt src
  while [[ ! -e "$path" ]]; do path="$(dirname "$path")"; done
  mnt="$(findmnt -n -o TARGET --target "$path")"
  if [[ "$mnt" != / ]]; then
    while read -r src; do
      [[ "$src" == "$mnt" || "$src" == "$mnt"/* ]] && mnt=/
    done < <(source_dirs "$1")
  fi
  if [[ "$mnt" == / ]]; then echo "$BORG_REPO_LOCAL"; else echo "$mnt"; fi
}

generated="$(mktemp)"
trap 'rm -f "$generated"' EXIT
render > "$generated"
BORG_REPO_EXCLUDE="$(repo_exclude "$generated")"
[[ "$BORG_REPO_EXCLUDE" != *[\'$'\n']* ]] || die "The backup disk's mount point must not contain quotes."
echo "ℹ️  Excluding the local backup disk/repository: ${BORG_REPO_EXCLUDE}"
render > "$generated"
leftover="$(grep -oE '\$\{[A-Za-z_]+\}' "$generated" | head -n 1 || true)"
[[ -z "$leftover" ]] || die "Unknown placeholder ${leftover} in ${TEMPLATE}."
borgmatic config validate --config "$generated" > /dev/null \
  || die "The generated config is not valid; see borgmatic's error above."

# === Show the changes and install ===
if [[ -f "$TARGET" ]] && cmp -s "$generated" "$TARGET"; then
  echo "✅ ${TARGET} is up to date."
  exit 0
fi
if [[ -f "$TARGET" ]]; then
  echo "Changes to ${TARGET}:"
  diff -u "$TARGET" "$generated" || true
fi
mkdir -p "$(dirname "$TARGET")"
install -m 600 "$generated" "${TARGET}.new"
mv "${TARGET}.new" "$TARGET"
echo "✅ Installed ${TARGET}."
