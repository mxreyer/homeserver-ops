#!/bin/bash
# ==============================================================================
# Script Name: configure-borgmatic.sh
# Description: Generates borgmatic's configs from the templates in borgmatic/
#              and the backup settings in CONFIG.sh, validates them and
#              installs them in /etc/borgmatic.d/ (showing the changes first):
#              - local.yaml: daily backup to the local repository
#                (local.template.yaml + common.template.yaml)
#              - offsite.yaml: weekly backup to the offsite repository
#                (offsite.template.yaml + common.template.yaml)
#              Both get the command hooks in commands.template.yaml.
#              If TIMEMACHINE_DIRS is set, it also installs timemachine.yaml
#              from
#              borgmatic/timemachine.template.yaml (backup of the Time Machine
#              sparse bundles to their own offsite repository); otherwise it
#              removes that file.
#              /etc/borgmatic/config.yaml, the single config of earlier
#              versions, is renamed to config.yaml.old, so a bare "borgmatic"
#              does not back up the local repository twice. Finally it checks
#              root's crontab against the cron lines in the README.
#
# Usage: sudo ./configure-borgmatic.sh
#        Run it once during setup, and again after changing CONFIG.sh or
#        pulling updates of this repository. The backups themselves (cron)
#        call borgmatic directly and do not need this script.
#        BORGMATIC_LOCAL_FILE=<path>, BORGMATIC_OFFSITE_FILE=<path>,
#        BORGMATIC_TIMEMACHINE_FILE=<path> and BORGMATIC_OLD_FILE=<path> use
#        other paths (e.g. for testing).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

LOCAL_TARGET="${BORGMATIC_LOCAL_FILE:-/etc/borgmatic.d/local.yaml}"
OFFSITE_TARGET="${BORGMATIC_OFFSITE_FILE:-/etc/borgmatic.d/offsite.yaml}"
TIMEMACHINE_TARGET="${BORGMATIC_TIMEMACHINE_FILE:-/etc/borgmatic.d/timemachine.yaml}"
OLD_CONFIG="${BORGMATIC_OLD_FILE:-/etc/borgmatic/config.yaml}"
BORG_PASS_FILE="${BORG_PASS_FILE:-${SCRIPT_DIR}/.borg-pass}"
TIMEMACHINE_SERVICE="${TIMEMACHINE_SERVICE:-smbd}"
REPO_DIR="$SCRIPT_DIR"

die() { echo "❌ $*" >&2; exit 1; }

# === Check the settings ===
command -v envsubst > /dev/null \
  || die "envsubst is missing: install gettext-base (Debian, Ubuntu, Pi OS) or gettext-envsubst (Fedora)."
for var in BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP HCHK_OFFSITE_BACKUP DOCKER_BINDS_DIR; do
  [[ -n "${!var:-}" ]] || die "${var} is not set in CONFIG.sh."
done
[[ -d "$DOCKER_BINDS_DIR" ]] || die "DOCKER_BINDS_DIR does not exist: ${DOCKER_BINDS_DIR}"
[[ -s "$BORG_PASS_FILE" ]] || die "Missing or empty passphrase file: ${BORG_PASS_FILE}"
read -ra timemachine_dirs <<< "${TIMEMACHINE_DIRS:-}"
if (( ${#timemachine_dirs[@]} > 0 )); then
  for var in BORG_REPO_OFFSITE_TMCHN HCHK_TIMEMACHINE_BACKUP; do
    [[ -n "${!var:-}" ]] || die "${var} is not set in CONFIG.sh (needed for TIMEMACHINE_DIRS)."
  done
  for dir in "${timemachine_dirs[@]}"; do
    [[ -d "$dir" ]] || die "TIMEMACHINE_DIRS: folder does not exist: ${dir}"
  done
fi
# Values are inserted into single-quoted YAML strings and borgmatic commands
for var in BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP HCHK_OFFSITE_BACKUP DOCKER_BINDS_DIR \
           BORG_PASS_FILE REPO_DIR EXTRA_BACKUP_DIRS EXTRA_EXCLUDES \
           TIMEMACHINE_DIRS TIMEMACHINE_SERVICE HCHK_TIMEMACHINE_BACKUP BORG_REPO_OFFSITE_TMCHN; do
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
BORG_REPO_OFFSITE_TMCHN="${BORG_REPO_OFFSITE_TMCHN:-}"
export REPO_DIR
# The hooks shared by the local and offsite configs, without the header
# comment, with their own placeholders already filled in
# shellcheck disable=SC2016 # the variable name is meant literally here
COMMON_COMMANDS_YAML="$(grep -v '^#' "${SCRIPT_DIR}/borgmatic/commands.template.yaml" | envsubst '${REPO_DIR}')"
export BORG_REPO_LOCAL BORG_REPO_OFFSITE HCHK_SERVER_BACKUP HCHK_OFFSITE_BACKUP DOCKER_BINDS_DIR \
       BORG_PASS_FILE REPO_DIR EXTRA_BACKUP_DIRS_YAML EXTRA_EXCLUDES_YAML \
       TIMEMACHINE_DIRS_YAML TIMEMACHINE_SERVICE HCHK_TIMEMACHINE_BACKUP BORG_REPO_OFFSITE_TMCHN \
       COMMON_COMMANDS_YAML

generated="$(mktemp)"
trap 'rm -f "$generated"' EXIT

# Render the templates $2... (concatenated in that order), validate the result
# and install it as $1 (showing the changes)
install_config() {
  local target="$1" leftover
  shift
  # Only these variables are replaced; anything else in ${...} form is left in
  # place and caught below (borgmatic's validation does not notice it)
  # shellcheck disable=SC2016 # the variable names are meant literally here
  envsubst '${BORG_REPO_LOCAL} ${BORG_REPO_OFFSITE} ${HCHK_SERVER_BACKUP} ${HCHK_OFFSITE_BACKUP} ${DOCKER_BINDS_DIR}
            ${BORG_PASS_FILE} ${REPO_DIR} ${EXTRA_BACKUP_DIRS_YAML} ${EXTRA_EXCLUDES_YAML}
            ${TIMEMACHINE_DIRS_YAML} ${TIMEMACHINE_SERVICE} ${HCHK_TIMEMACHINE_BACKUP}
            ${BORG_REPO_OFFSITE_TMCHN} ${COMMON_COMMANDS_YAML}' \
    < <(cat "$@") > "$generated"
  leftover="$(grep -oE '\$\{[A-Za-z_]+\}' "$generated" | head -n 1 || true)"
  [[ -z "$leftover" ]] || die "Unknown placeholder ${leftover} in the templates for ${target}."
  borgmatic config validate --config "$generated" > /dev/null \
    || die "The generated config for ${target} is not valid; see borgmatic's error above."

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

install_config "$LOCAL_TARGET" \
  "${SCRIPT_DIR}/borgmatic/local.template.yaml" "${SCRIPT_DIR}/borgmatic/common.template.yaml"
install_config "$OFFSITE_TARGET" \
  "${SCRIPT_DIR}/borgmatic/offsite.template.yaml" "${SCRIPT_DIR}/borgmatic/common.template.yaml"
if (( ${#timemachine_dirs[@]} > 0 )); then
  install_config "$TIMEMACHINE_TARGET" "${SCRIPT_DIR}/borgmatic/timemachine.template.yaml"
elif [[ -f "$TIMEMACHINE_TARGET" ]]; then
  rm -f "$TIMEMACHINE_TARGET"
  echo "✅ Removed ${TIMEMACHINE_TARGET} (TIMEMACHINE_DIRS is not set)."
fi

# Earlier versions generated one config for all repositories here. borgmatic
# reads it by default next to /etc/borgmatic.d/, so a bare "borgmatic" would
# back up to the local repository twice. Keep it as .old for reference.
if [[ -f "$OLD_CONFIG" ]]; then
  if grep -q 'Generated by configure-borgmatic.sh' "$OLD_CONFIG"; then
    mv "$OLD_CONFIG" "${OLD_CONFIG}.old"
    echo "✅ Renamed the old ${OLD_CONFIG} to ${OLD_CONFIG}.old (replaced by ${LOCAL_TARGET})."
  else
    echo "⚠️  ${OLD_CONFIG} exists but was not generated by this script. borgmatic runs it"
    echo "   too whenever it is called without --config; remove it if it is not needed."
  fi
fi

# Compare root's crontab with the cron lines in the README (step 8)
cron_lines="$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -w borgmatic || true)"
if [[ -n "$cron_lines" ]]; then
  cron_warning() { echo "⚠️  root's crontab: $*"; echo "   Update it to the cron lines in the README (step 8)."; }
  if grep -vq -- '--config' <<< "$cron_lines"; then
    cron_warning "a borgmatic line has no --config, so it runs the local, offsite and Time Machine backups together."
  fi
  if grep -qF "$OLD_CONFIG" <<< "$cron_lines"; then
    cron_warning "a borgmatic line still uses ${OLD_CONFIG}, which no longer exists."
  fi
  if (( ${#timemachine_dirs[@]} > 0 )) && ! grep -qF "$TIMEMACHINE_TARGET" <<< "$cron_lines"; then
    cron_warning "no borgmatic line runs ${TIMEMACHINE_TARGET}, so the Time Machine bundles are not backed up."
  elif (( ${#timemachine_dirs[@]} == 0 )) && grep -qF "$TIMEMACHINE_TARGET" <<< "$cron_lines"; then
    cron_warning "a borgmatic line runs ${TIMEMACHINE_TARGET}, which no longer exists, so that run fails."
  fi
fi
