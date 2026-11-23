#!/bin/bash
# ==============================================================================
# Script Name: lib/docker.sh
# Description: Functions to stop, start and update the running containers.
#
# Notes:
#   - Containers are discovered at runtime, so nothing has to be listed by
#     hand: compose projects through their labels, plus containers started
#     outside compose (e.g. plain "docker run").
#   - Nextcloud AIO containers are left alone: AIO runs its own backup (its
#     volumes are excluded from ours) and updates itself. Its mastercontainer
#     creates them with only the label com.docker.compose.project=nextcloud-aio
#     and no compose file, so "docker compose -p nextcloud-aio" cannot operate
#     them; running_projects skips such projects.
#   - Compose projects listed in SKIP_PROJECTS (CONFIG.sh) are left alone
#     too: never stopped, started, updated or exported.
#   - stop_containers records what it stopped in a state file, and
#     start_containers starts exactly those again. A second stop merges into
#     the file, so it never forgets what the first one stopped.
# ==============================================================================

STOP_TIMEOUT="${CONTAINER_STOP_TIMEOUT:-120}" # seconds to shut down before docker kills

# Print "project<TAB>working_dir" for every running compose project. Projects
# without a working directory were not started by docker compose (e.g. the
# containers Nextcloud AIO creates) and are skipped, as are SKIP_PROJECTS.
running_projects() {
  docker ps \
    --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}' \
    | awk -F'\t' -v skip=" ${SKIP_PROJECTS:-} " \
        '$1 != "" && $2 != "" && index(skip, " " $1 " ") == 0' \
    | sort -u
}

# Print the names of running containers that are not part of a compose
# project, except Nextcloud AIO
running_standalone() {
  docker ps --format '{{.Names}}	{{.Label "com.docker.compose.project"}}' \
    | awk -F'\t' '$2 == "" && $1 !~ /^nextcloud-aio-/ {print $1}' | sort -u
}

# Stop all running containers, recording them in state file $1 as
# "compose<TAB>project" or "container<TAB>name". Fails if anything did not
# stop cleanly, so a backup never runs against half-stopped data.
stop_containers() {
  local state="$1" kind name rc=0
  {
    running_projects | cut -f1 | sed 's/^/compose\t/'
    running_standalone | sed 's/^/container\t/'
    if [[ -f "$state" ]]; then cat "$state"; fi
  } | sort -u > "${state}.new"
  mv "${state}.new" "$state"

  echo "🐳 Stopping containers (timeout ${STOP_TIMEOUT}s)..."
  while IFS=$'\t' read -r kind name; do
    echo "   stopping ${kind} ${name}"
    case "$kind" in
      compose)   docker compose -p "$name" stop --timeout "$STOP_TIMEOUT" < /dev/null || rc=1 ;;
      container) docker stop --time "$STOP_TIMEOUT" "$name" < /dev/null > /dev/null || rc=1 ;;
    esac
  done < "$state"
  (( rc == 0 )) || echo "❌ Some containers failed to stop." >&2
  return "$rc"
}

# Start the containers recorded in state file $1 (compose projects first),
# then remove it
start_containers() {
  local state="$1" kind name rc=0
  [[ -f "$state" ]] || return 0
  echo "🐳 Starting containers..."
  while IFS=$'\t' read -r kind name; do
    echo "   starting ${kind} ${name}"
    case "$kind" in
      compose)   docker compose -p "$name" start < /dev/null || rc=1 ;;
      container) docker start "$name" < /dev/null > /dev/null || rc=1 ;;
    esac
  done < <(grep '^compose' "$state"; grep '^container' "$state")
  if (( rc == 0 )); then
    rm -f "$state"
  else
    echo "❌ Some containers failed to start; kept ${state} for the next attempt." >&2
  fi
  return "$rc"
}

# Pull the images of compose project $1, retrying with a growing delay:
# registries (notably ghcr.io) sometimes answer with a transient rate-limit
# error. A retry only fetches the layers that are still missing.
pull_with_retry() {
  local project="$1" attempt attempts=3
  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    docker compose -p "$project" pull && return 0
    (( attempt < attempts )) || break
    echo "   ⚠️  pull of ${project} failed (attempt ${attempt}/${attempts}), retrying in $(( attempt * 30 ))s..." >&2
    sleep $(( attempt * 30 ))
  done
  echo "❌ pull of ${project} failed after ${attempts} attempts." >&2
  return 1
}

# Pull new images for every running compose project and recreate only the
# containers whose image changed. No project is stopped first.
update_projects() {
  local project dir rc=0
  echo "🐳 Updating compose projects..."
  while IFS=$'\t' read -r project dir; do
    echo "   updating ${project} (${dir})"
    (cd "$dir" && pull_with_retry "$project" && docker compose -p "$project" up -d) < /dev/null || rc=1
  done < <(running_projects)
  return "$rc"
}
