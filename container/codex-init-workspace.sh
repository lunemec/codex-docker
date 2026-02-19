#!/usr/bin/env bash
set -euo pipefail

BASELINE_ROOT="/opt/codex-baseline"
WORKSPACE_ROOT="/workspace"
FORCE=0
QUIET=0

usage() {
  cat <<USAGE
Usage:
  $0 [--workspace DIR] [--force] [--quiet]

Options:
  --workspace DIR   Target workspace path (default: /workspace)
  --force           Overwrite existing files from baseline
  --quiet           Suppress non-error output
USAGE
}

log() {
  [[ "$QUIET" -eq 1 ]] || echo "$*"
}

copy_tree_missing_only() {
  local src="$1"
  local dst="$2"

  mkdir -p "$dst"

  local rel
  while IFS= read -r -d '' rel; do
    mkdir -p "$dst/$rel"
  done < <(cd "$src" && find . -mindepth 1 -type d -print0)

  while IFS= read -r -d '' rel; do
    local src_file="$src/$rel"
    local dst_file="$dst/$rel"
    if [[ ! -e "$dst_file" ]]; then
      mkdir -p "$(dirname "$dst_file")"
      cp -a "$src_file" "$dst_file"
      log "seeded $dst_file"
    fi
  done < <(cd "$src" && find . -mindepth 1 -type f -print0)
}

copy_tree_force() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  log "refreshed $dst from baseline"
}

seed_workspace() {
  local src="$1"
  local dst="$2"

  if [[ "$FORCE" -eq 1 ]]; then
    copy_tree_force "$src" "$dst"
  else
    copy_tree_missing_only "$src" "$dst"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace)
        WORKSPACE_ROOT="$2"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --quiet)
        QUIET=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  [[ -d "$BASELINE_ROOT" ]] || {
    echo "baseline not found: $BASELINE_ROOT" >&2
    exit 1
  }

  mkdir -p "$WORKSPACE_ROOT"

  local baseline_scripts="$BASELINE_ROOT/scripts"
  local baseline_coord="$BASELINE_ROOT/coordination"

  [[ -d "$baseline_scripts" ]] || {
    echo "baseline scripts directory missing: $baseline_scripts" >&2
    exit 1
  }
  [[ -d "$baseline_coord" ]] || {
    echo "baseline coordination directory missing: $baseline_coord" >&2
    exit 1
  }

  seed_workspace "$baseline_scripts" "$WORKSPACE_ROOT/scripts"
  seed_workspace "$baseline_coord" "$WORKSPACE_ROOT/coordination"
}

main "$@"
