#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="/workspace"
QUIET=0
SKIP_BASELINE=0
FORCE_ROLES=0

CORE_AGENTS=(pm coordinator designer architect fe be db review)

usage() {
  cat <<USAGE
Usage:
  $0 [--workspace DIR] [--skip-baseline] [--force-roles] [--quiet]

Options:
  --workspace DIR   Workspace root to repair (default: /workspace)
  --skip-baseline   Do not call codex-init-workspace (only repair structure + roles)
  --force-roles     Force-refresh core role prompts via ensure-agent --force
  --quiet           Suppress non-error output
USAGE
}

log() {
  [[ "$QUIET" -eq 1 ]] || echo "$*"
}

abs_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$path"
  else
    readlink -f "$path"
  fi
}

require_container_workspace() {
  [[ -f /.dockerenv ]] || {
    echo "coordination_repair must run inside Docker (.dockerenv not found)" >&2
    exit 1
  }

  local cwd
  cwd="$(pwd -P)"
  [[ "$cwd" == "/workspace" || "$cwd" == /workspace/* ]] || {
    echo "coordination_repair must run from /workspace (current: $cwd)" >&2
    exit 1
  }

  local ws_abs
  ws_abs="$(abs_path "$WORKSPACE_ROOT")"
  [[ "$ws_abs" == "/workspace" || "$ws_abs" == /workspace/* ]] || {
    echo "--workspace must resolve under /workspace (current: $ws_abs)" >&2
    exit 1
  }
}

seed_from_baseline() {
  [[ "$SKIP_BASELINE" -eq 1 ]] && return 0

  if command -v codex-init-workspace >/dev/null 2>&1; then
    log "seeding missing baseline files via codex-init-workspace"
    if [[ "$QUIET" -eq 1 ]]; then
      codex-init-workspace --workspace "$WORKSPACE_ROOT" --quiet
    else
      codex-init-workspace --workspace "$WORKSPACE_ROOT"
    fi
    return 0
  fi

  log "codex-init-workspace not found; skipping baseline seeding"
}

ensure_coordination_dirs() {
  local croot="$WORKSPACE_ROOT/coordination"

  mkdir -p \
    "$croot" \
    "$croot/inbox" \
    "$croot/in_progress" \
    "$croot/done" \
    "$croot/blocked" \
    "$croot/reports" \
    "$croot/roles" \
    "$croot/prompts" \
    "$croot/templates" \
    "$croot/examples" \
    "$croot/runtime/logs" \
    "$croot/runtime/pids" \
    "$croot/runtime/role_backups"

  log "ensured coordination directory skeleton under $croot"
}

repair_top_level_prompt() {
  local prompt_file="$WORKSPACE_ROOT/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md"
  [[ -f "$prompt_file" ]] && return 0

  local baseline_prompt="/opt/codex-baseline/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md"
  if [[ -f "$baseline_prompt" ]]; then
    cp -a "$baseline_prompt" "$prompt_file"
    log "restored missing top-level prompt from baseline: $prompt_file"
    return 0
  fi

  cat >"$prompt_file" <<'EOF'
You are the top-level orchestration agent for this workspace (`pm` or `coordinator`).
Use scripts/taskctl.sh ensure-agent, create/delegate tasks, run scripts/agents_ctl.sh once <agents...>, aggregate results, and close with validation evidence.
EOF
  log "created minimal fallback top-level prompt: $prompt_file"
}

ensure_core_agents() {
  local taskctl="$WORKSPACE_ROOT/scripts/taskctl.sh"
  [[ -x "$taskctl" ]] || {
    echo "missing required taskctl script: $taskctl" >&2
    exit 1
  }

  local agent
  for agent in "${CORE_AGENTS[@]}"; do
    if [[ "$FORCE_ROLES" -eq 1 ]]; then
      TASK_ROOT_DIR="$WORKSPACE_ROOT/coordination" "$taskctl" ensure-agent "$agent" --force >/dev/null
    else
      TASK_ROOT_DIR="$WORKSPACE_ROOT/coordination" "$taskctl" ensure-agent "$agent" >/dev/null
    fi
    log "ensured agent lane: $agent"
  done
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace)
        WORKSPACE_ROOT="$2"
        shift 2
        ;;
      --skip-baseline)
        SKIP_BASELINE=1
        shift
        ;;
      --force-roles)
        FORCE_ROLES=1
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

  require_container_workspace
  mkdir -p "$WORKSPACE_ROOT"
  cd "$WORKSPACE_ROOT"

  seed_from_baseline
  ensure_coordination_dirs
  repair_top_level_prompt
  ensure_core_agents

  log "coordination repair complete for $WORKSPACE_ROOT"
}

main "$@"
