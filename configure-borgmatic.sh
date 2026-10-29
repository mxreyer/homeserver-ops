#!/bin/bash
# ==============================================================================
# Script Name: configure-borgmatic.sh
# Description: Generates borgmatic's config from borgmatic/config.template.yaml
#              and the backup settings in CONFIG.sh, validates it and installs
#              it as /etc/borgmatic/config.yaml (shows the changes first).
#              If TIMEMACHINE_DIRS is set, it also installs
#              /etc/borgmatic.d/timemachine.yaml from
#              borgmatic/timemachine.template.yaml (offsite backup of the Time
#              Machine sparse bundles); otherwise it removes that file.
#
# Usage: sudo ./configure-borgmatic.sh
#        Run it once during setup, and again after changing CONFIG.sh or
#        pulling updates of this repository. The backup itself (cron) calls
#        borgmatic directly and does not need this script.
#        BORGMATIC_CONFIG_FILE=<path> and BORGMATIC_TIMEMACHINE_FILE=<path>
#        write somewhere else (e.g. for testing).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

TARGET="${BORGMATIC_CONFIG_FILE:-/etc/borgmatic/config.yaml}"
TIMEMACHINE_TARGET="${BORGMATIC_TIMEMACHINE_FILE:-/etc/borgmatic.d/timemachine.yaml}"
BORG_PASS_FILE="${BORG_PASS_FILE:-${SCRIPT_DIR}/.borg-pass}"
TIMEMACHINE_SERVICE="${TIMEMACHINE_SERVICE:-smbd}"
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
read -ra timemachine_dirs <<< "${TIMEMACHINE_DIRS:-}"
if (( ${#timemachine_dirs[@]} > 0 )); then
  [[ -n "${HCHK_TIMEMACHINE_BACKUP:-}" ]] || die "HCHK_TIMEMACHINE_BACKUP is not set in CONFIG.sh (needed for TIMEMACHINE_DIRS)."
  for dir in "${timemachine_dirs[@]}"; do
    [[ -d "$dir" ]] || die "TIMEMACHINE_DIRS: folder does not exist: ${dir}"
  done
fi
# Values are inserted into single-quoted YAML strings and borgmatic commands
for var in BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP DOCKER_BINDS_DIR \
           BORG_PASS_FILE REPO_DIR EXTRA_BACKUP_DIRS EXTRA_EXCLUDES \
           TIMEMACHINE_DIRS TIMEMACHINE_SERVICE HCHK_TIMEMACHINE_BACKUP; do
  [[ "${!var:-}" != *[\'$'\n']* ]] || die "${var} must not contain quotes or line breaks."
done
for var in BORG_PASS_FILE REPO_DIR TIMEMACHINE_SERVICE; do
  [[ "${!var}" != *[[:space:]]* ]] || die "${var} must not contain spaces: ${!var}"
done

# === Fill the templates ===
# Turn a space-separated list into YAML list items (globs are kept, not expanded)
yaml_list() {
  local items item
  read -ra items <<< "$1"
  for item in "${items[@]}"; do printf "    - '%s'\n" "$item"; done
}
EXTRA_BACKUP_DIRS_YAML="$(yaml_list "${EXTRA_BACKUP_DIRS:-}")"
EXTRA_EXCLUDES_YAML="$(yaml_list "${EXTRA_EXCLUDES:-}")"
TIMEMACHINE_DIRS_YAML="$(yaml_list "${TIMEMACHINE_DIRS:-}")"
HCHK_TIMEMACHINE_BACKUP="${HCHK_TIMEMACHINE_BACKUP:-}"
export BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP DOCKER_BINDS_DIR \
       BORG_PASS_FILE REPO_DIR EXTRA_BACKUP_DIRS_YAML EXTRA_EXCLUDES_YAML \
       TIMEMACHINE_DIRS_YAML TIMEMACHINE_SERVICE HCHK_TIMEMACHINE_BACKUP

generated="$(mktemp)"
trap 'rm -f "$generated"' EXIT

# Render template $1, validate it and install it as $2 (showing the changes)
install_config() {
  local template="$1" target="$2" leftover
  # Only these variables are replaced; anything else in ${...} form is left in
  # place and caught below (borgmatic's validation does not notice it)
  # shellcheck disable=SC2016 # the variable names are meant literally here
  envsubst '${BORG_REPO_LOCAL} ${BORG_REPO_OFFSITE} ${HCHK_SERVER_BACKUP} ${DOCKER_BINDS_DIR}
            ${BORG_PASS_FILE} ${REPO_DIR} ${EXTRA_BACKUP_DIRS_YAML} ${EXTRA_EXCLUDES_YAML}
            ${TIMEMACHINE_DIRS_YAML} ${TIMEMACHINE_SERVICE} ${HCHK_TIMEMACHINE_BACKUP}' \
    < "$template" > "$generated"
  leftover="$(grep -oE '\$\{[A-Za-z_]+\}' "$generated" | head -n 1 || true)"
  [[ -z "$leftover" ]] || die "Unknown placeholder ${leftover} in ${template}."
  borgmatic config validate --config "$generated" > /dev/null \
    || die "The generated config from ${template} is not valid; see borgmatic's error above."

  if [[ -f "$target" ]] && cmp -s "$generated" "$target"; then
    echo "✅ ${target} is up to date."
    return 0
  fi
  if [[ -f "$target" ]]; then
    echo "Changes to ${target}:"
    diff -u "$target" "$generated" || true
  fi
  mkdir -p "$(dirname "$target")"
  install -m 600 "$generated" "${target}.new"
  mv "${target}.new" "$target"
  echo "✅ Installed ${target}."
}

install_config "${SCRIPT_DIR}/borgmatic/config.template.yaml" "$TARGET"
if (( ${#timemachine_dirs[@]} > 0 )); then
  install_config "${SCRIPT_DIR}/borgmatic/timemachine.template.yaml" "$TIMEMACHINE_TARGET"
elif [[ -f "$TIMEMACHINE_TARGET" ]]; then
  rm -f "$TIMEMACHINE_TARGET"
  echo "✅ Removed ${TIMEMACHINE_TARGET} (TIMEMACHINE_DIRS is not set)."
fi
