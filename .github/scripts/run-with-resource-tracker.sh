#!/usr/bin/env bash
# Run a command wrapped by resource-tracker (process-tree mode).
#
# Use shell-wrapper mode so CPU/memory attribution follows the tracked command
# and its child processes. For workloads where work happens outside the process
# tree (e.g. docker buildx driving buildkitd), use standalone mode instead: run
# resource-tracker in the background with no wrapped command.
#
# Expects TRACKER_* metadata and optional SENTINEL_API_TOKEN in the environment.
set -euo pipefail

if ! command -v resource-tracker >/dev/null 2>&1; then
  echo "run-with-resource-tracker: resource-tracker not found in PATH" >&2
  exit 1
fi

quiet=()
case "${TRACKER_QUIET:-}" in
  true|1|yes) quiet+=(--quiet) ;;
esac

# Do not pass --tag flags: v0.1.12 serializes tags as ["key=value"] strings but
# Sentinel expects [{"key":"…","value":"…"}], which causes start_run HTTP 422.
resource-tracker "${quiet[@]}" -- "$@"
