#!/usr/bin/env bash
set -euo pipefail

ROOT="coordination"
TASKCTL="scripts/taskctl.sh"
DEFAULT_INTERVAL=30

usage() {
  cat <<USAGE
Usage:
  $0 <agent> [--interval N] [--once]

Environment overrides:
  AGENT_ROOT_DIR          default: coordination
  AGENT_POLL_INTERVAL     default: 30
  AGENT_EXEC_CMD          default: codex exec ...

Example:
  $0 be --interval 20
USAGE
}

require_agent() {
  case "$1" in
    db|be|fe|review) ;;
    *) echo "invalid specialist agent: $1" >&2; exit 1 ;;
  esac
}

log() {
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$AGENT" "$*"
}

field_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}: //p" "$file" | head -n1
}

first_in_progress_task() {
  find "$ROOT/in_progress/$AGENT" -maxdepth 1 -type f -name 'TASK-*.md' | sort | head -n1
}

build_prompt_file() {
  local task_file="$1"
  local prompt_file="$2"
  local role_file="$ROOT/roles/$AGENT.md"

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
- If you cannot complete due to dependency or ambiguity, clearly state blocker in the task file and exit non-zero.
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
  build_prompt_file "$task_file" "$prompt_file"

  log "starting $task_id"

  local exec_cmd
  exec_cmd="${AGENT_EXEC_CMD:-codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C \"$WORKDIR\" -}"

  set +e
  bash -lc "$exec_cmd" <"$prompt_file" >"$log_file" 2>&1
  local rc=$?
  set -e

  rm -f "$prompt_file"

  if [[ $rc -eq 0 ]]; then
    "$TASKCTL" done "$AGENT" "$task_id" >/dev/null
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

ROOT="${AGENT_ROOT_DIR:-$ROOT}"
WORKDIR="$(pwd)"
TASKCTL="${TASKCTL}"
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

mkdir -p "$ROOT/runtime/logs/$AGENT" "$ROOT/runtime/pids"
log "worker started (interval=${INTERVAL}s, once=$RUN_ONCE)"
main_loop
log "worker stopped"
