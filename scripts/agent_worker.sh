#!/usr/bin/env bash
set -euo pipefail

ROOT="${AGENT_ROOT_DIR:-coordination}"
TASKCTL="${AGENT_TASKCTL:-scripts/taskctl.sh}"
DEFAULT_INTERVAL=30
REASONING_XHIGH_AGENTS="${AGENT_XHIGH_AGENTS:-pm coordinator architect}"
REASONING_XHIGH_EFFORT="${AGENT_PLANNER_REASONING_EFFORT:-xhigh}"
REASONING_DEFAULT_EFFORT="${AGENT_DEFAULT_REASONING_EFFORT:-null}"

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
    echo "agent_worker must run inside Docker (.dockerenv not found)" >&2
    exit 1
  }

  local cwd
  cwd="$(pwd -P)"
  [[ "$cwd" == "/workspace" || "$cwd" == /workspace/* ]] || {
    echo "agent_worker must run from /workspace (current: $cwd)" >&2
    exit 1
  }

  local root_abs
  root_abs="$(abs_path "$ROOT")"
  [[ "$root_abs" == "/workspace" || "$root_abs" == /workspace/* ]] || {
    echo "AGENT_ROOT_DIR must resolve under /workspace (current: $root_abs)" >&2
    exit 1
  }

  local taskctl_abs
  taskctl_abs="$(abs_path "$TASKCTL")"
  [[ "$taskctl_abs" == "/workspace" || "$taskctl_abs" == /workspace/* ]] || {
    echo "AGENT_TASKCTL must resolve under /workspace (current: $taskctl_abs)" >&2
    exit 1
  }
}

require_container_workspace

usage() {
  cat <<USAGE
Usage:
  $0 <agent> [--interval N] [--once]

Environment overrides:
  AGENT_ROOT_DIR          default: coordination
  AGENT_POLL_INTERVAL     default: 30
  AGENT_XHIGH_AGENTS      default: "pm coordinator architect"
  AGENT_PLANNER_REASONING_EFFORT
                          default: xhigh (supports: default|null|none|minimal|low|medium|high|xhigh)
  AGENT_DEFAULT_REASONING_EFFORT
                          default: null (alias: default; Codex model default reasoning)
  AGENT_EXEC_CMD          optional custom command; bypasses built-in reasoning policy
  AGENT_TASKCTL           default: scripts/taskctl.sh
USAGE
}

require_agent() {
  local agent="$1"
  [[ "$agent" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
    echo "invalid agent: $agent" >&2
    exit 1
  }
}

log() {
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$AGENT" "$*"
}

is_valid_reasoning_effort() {
  local effort="$1"
  case "$effort" in
    null|none|minimal|low|medium|high|xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_reasoning_effort() {
  local effort="${1:-}"
  effort="${effort,,}"

  case "$effort" in
    ""|default|null)
      printf 'null'
      return 0
      ;;
  esac

  is_valid_reasoning_effort "$effort" || return 1
  printf '%s' "$effort"
}

validate_reasoning_config() {
  local normalized_xhigh normalized_default

  if ! normalized_xhigh="$(normalize_reasoning_effort "$REASONING_XHIGH_EFFORT")"; then
    echo "invalid AGENT_PLANNER_REASONING_EFFORT: $REASONING_XHIGH_EFFORT (expected default|null|none|minimal|low|medium|high|xhigh)" >&2
    exit 1
  fi

  if ! normalized_default="$(normalize_reasoning_effort "$REASONING_DEFAULT_EFFORT")"; then
    echo "invalid AGENT_DEFAULT_REASONING_EFFORT: $REASONING_DEFAULT_EFFORT (expected default|null|none|minimal|low|medium|high|xhigh)" >&2
    exit 1
  fi

  REASONING_XHIGH_EFFORT="$normalized_xhigh"
  REASONING_DEFAULT_EFFORT="$normalized_default"
}

agent_uses_xhigh_reasoning() {
  local item
  for item in $REASONING_XHIGH_AGENTS; do
    [[ "$AGENT" == "$item" ]] && return 0
  done
  return 1
}

reasoning_effort_for_agent() {
  if agent_uses_xhigh_reasoning; then
    printf '%s' "$REASONING_XHIGH_EFFORT"
  else
    printf '%s' "$REASONING_DEFAULT_EFFORT"
  fi
}

run_default_exec_cmd() {
  local prompt_file="$1"
  local log_file="$2"
  local reasoning_effort="$3"
  local reasoning_config

  if [[ "$reasoning_effort" == "null" ]]; then
    reasoning_config='model_reasoning_effort=null'
  else
    reasoning_config="model_reasoning_effort=\"$reasoning_effort\""
  fi

  codex exec \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -C "$WORKDIR" \
    -c "$reasoning_config" \
    - <"$prompt_file" >"$log_file" 2>&1
}

field_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}: //p" "$file" | head -n1
}

first_in_progress_task() {
  find "$ROOT/in_progress/$AGENT" -maxdepth 1 -type f -name '*.md' | sort | head -n1
}

build_prompt_file() {
  local task_file="$1"
  local prompt_file="$2"
  local role_file="$ROOT/roles/$AGENT.md"

  [[ -f "$role_file" ]] || { echo "missing role file: $role_file" >&2; exit 1; }

  cat >"$prompt_file" <<PROMPT
You are running as background worker agent '$AGENT' in repository '$WORKDIR'.

Follow this role guidance:
PROMPT
  cat "$role_file" >>"$prompt_file"

  cat >>"$prompt_file" <<PROMPT

Task file path: $task_file

Task content:
PROMPT
  cat "$task_file" >>"$prompt_file"

  cat >>"$prompt_file" <<'PROMPT'

Execution requirements:
- Implement the task in the current repository.
- Keep changes scoped to the task.
- Run relevant checks/tests for touched areas.
- Update the task file's "## Result" section with concise outcomes and verification commands.
- If blocked by dependency or ambiguity, clearly state blocker in the task file and exit non-zero.
PROMPT
}

run_task() {
  local task_file="$1"
  local task_id
  task_id="$(field_value "$task_file" "id")"
  [[ -n "$task_id" ]] || task_id="$(basename "$task_file" .md)"

  local run_dir="$ROOT/runtime/logs/$AGENT"
  mkdir -p "$run_dir"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local log_file="$run_dir/${task_id}-${stamp}.log"

  local prompt_file
  prompt_file="$(mktemp)"
  "$TASKCTL" ensure-agent "$AGENT" --task "$task_file" >/dev/null
  build_prompt_file "$task_file" "$prompt_file"

  local reasoning_effort
  reasoning_effort="$(reasoning_effort_for_agent)"
  log "starting $task_id (reasoning_effort=$reasoning_effort)"

  set +e
  if [[ -n "${AGENT_EXEC_CMD:-}" ]]; then
    bash -lc "$AGENT_EXEC_CMD" <"$prompt_file" >"$log_file" 2>&1
  else
    run_default_exec_cmd "$prompt_file" "$log_file" "$reasoning_effort"
  fi
  local rc=$?
  set -e

  rm -f "$prompt_file"

  if [[ $rc -eq 0 ]]; then
    "$TASKCTL" done "$AGENT" "$task_id" "Completed by worker; log: $log_file" >/dev/null
    log "completed $task_id (log: $log_file)"
  else
    "$TASKCTL" block "$AGENT" "$task_id" "worker command failed (exit=$rc); see $log_file" >/dev/null || true
    log "blocked $task_id (exit=$rc, log: $log_file)"
  fi
}

main_loop() {
  while true; do
    local task_file
    task_file="$(first_in_progress_task)"

    if [[ -z "$task_file" ]]; then
      "$TASKCTL" claim "$AGENT" >/tmp/agent-claim-${AGENT}.out 2>/tmp/agent-claim-${AGENT}.err || true
      task_file="$(first_in_progress_task)"
    fi

    if [[ -n "$task_file" ]]; then
      run_task "$task_file"
      if [[ "$RUN_ONCE" -eq 1 ]]; then
        break
      fi
      continue
    fi

    if [[ "$RUN_ONCE" -eq 1 ]]; then
      log "no task found"
      break
    fi

    sleep "$INTERVAL"
  done
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then
  usage
  exit 0
fi

AGENT="$1"
shift || true
require_agent "$AGENT"

WORKDIR="$(pwd)"
INTERVAL="${AGENT_POLL_INTERVAL:-$DEFAULT_INTERVAL}"
RUN_ONCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --once)
      RUN_ONCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

"$TASKCTL" ensure-agent "$AGENT" >/dev/null

validate_reasoning_config

mkdir -p "$ROOT/runtime/logs/$AGENT" "$ROOT/runtime/pids"
log "worker started (interval=${INTERVAL}s, once=$RUN_ONCE)"
main_loop
log "worker stopped"
