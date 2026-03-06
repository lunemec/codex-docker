#!/usr/bin/env bash
set -euo pipefail

ROOT="${AGENT_ROOT_DIR:-coordination}"
TASKCTL="${AGENT_TASKCTL:-scripts/taskctl.sh}"
DEFAULT_INTERVAL=30
REASONING_XHIGH_AGENTS="${AGENT_XHIGH_AGENTS:-pm coordinator planner researcher architect be review}"
REASONING_XHIGH_EFFORT="${AGENT_PLANNER_REASONING_EFFORT:-xhigh}"
REASONING_DEFAULT_EFFORT="${AGENT_DEFAULT_REASONING_EFFORT:-medium}"
LOCK_HEARTBEAT_INTERVAL="${AGENT_LOCK_HEARTBEAT_INTERVAL:-30}"

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
  AGENT_XHIGH_AGENTS      default: "pm coordinator planner researcher architect be review"
  AGENT_PLANNER_REASONING_EFFORT
                          default: xhigh (supports: default|null|none|minimal|low|medium|high|xhigh; null aliases to none)
  AGENT_DEFAULT_REASONING_EFFORT
                          default: medium (aliases: default|null->none)
  AGENT_LOCK_HEARTBEAT_INTERVAL
                          default: 30 seconds
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

run_taskctl() {
  TASK_ROOT_DIR="$ROOT" "$TASKCTL" "$@"
}

sanitize_single_line() {
  local text="$1"
  printf '%s' "$text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

is_valid_reasoning_effort() {
  local effort="$1"
  case "$effort" in
    none|minimal|low|medium|high|xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_reasoning_effort() {
  local effort="${1:-}"
  effort="${effort,,}"

  case "$effort" in
    ""|default|null)
      # Runtime does not accept model_reasoning_effort=null, so map legacy aliases safely.
      printf 'none'
      return 0
      ;;
  esac

  is_valid_reasoning_effort "$effort" || return 1
  printf '%s' "$effort"
}

validate_reasoning_config() {
  local normalized_xhigh normalized_default

  if ! normalized_xhigh="$(normalize_reasoning_effort "$REASONING_XHIGH_EFFORT")"; then
    echo "invalid AGENT_PLANNER_REASONING_EFFORT: $REASONING_XHIGH_EFFORT (expected default|none|minimal|low|medium|high|xhigh; alias: null->none)" >&2
    exit 1
  fi

  if ! normalized_default="$(normalize_reasoning_effort "$REASONING_DEFAULT_EFFORT")"; then
    echo "invalid AGENT_DEFAULT_REASONING_EFFORT: $REASONING_DEFAULT_EFFORT (expected default|none|minimal|low|medium|high|xhigh; alias: null->none)" >&2
    exit 1
  fi

  REASONING_XHIGH_EFFORT="$normalized_xhigh"
  REASONING_DEFAULT_EFFORT="$normalized_default"
}

validate_lock_config() {
  [[ "$LOCK_HEARTBEAT_INTERVAL" =~ ^[0-9]+$ ]] || {
    echo "invalid AGENT_LOCK_HEARTBEAT_INTERVAL: $LOCK_HEARTBEAT_INTERVAL (expected integer seconds > 0)" >&2
    exit 1
  }
  (( LOCK_HEARTBEAT_INTERVAL > 0 )) || {
    echo "invalid AGENT_LOCK_HEARTBEAT_INTERVAL: $LOCK_HEARTBEAT_INTERVAL (expected integer seconds > 0)" >&2
    exit 1
  }
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

  codex exec \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -C "$WORKDIR" \
    -c "model_reasoning_effort=\"$reasoning_effort\"" \
    - <"$prompt_file" >"$log_file" 2>&1
}

field_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}: //p" "$file" | head -n1
}

extract_frontmatter_to_file() {
  local source_file="$1"
  local out_file="$2"
  awk '
    BEGIN { section = 0 }
    /^---$/ { section++; next }
    section == 1 { print }
    section >= 2 { exit }
  ' "$source_file" >"$out_file"
}

task_intended_write_targets() {
  local task_file="$1"

  command -v yq >/dev/null 2>&1 || {
    echo "missing required command: yq" >&2
    return 1
  }

  local frontmatter_file
  frontmatter_file="$(mktemp)"
  extract_frontmatter_to_file "$task_file" "$frontmatter_file"

  if [[ ! -s "$frontmatter_file" ]]; then
    rm -f "$frontmatter_file"
    return 0
  fi

  local parsed_targets rc
  if parsed_targets="$(yq -r '.intended_write_targets // [] | if type == "array" then .[] else empty end' "$frontmatter_file" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi

  rm -f "$frontmatter_file"

  if [[ $rc -ne 0 ]]; then
    echo "failed to parse intended_write_targets from task frontmatter: $task_file" >&2
    return 1
  fi

  if [[ -n "$parsed_targets" ]]; then
    printf '%s\n' "$parsed_targets" | sed '/^$/d'
  fi
}

in_progress_task_path() {
  local task_id="$1"
  printf '%s/in_progress/%s/%s.md' "$ROOT" "$AGENT" "$task_id"
}

find_task_in_state() {
  local state="$1"
  local task_id="$2"
  local dir="$ROOT/$state/$AGENT"

  [[ -d "$dir" ]] || return 0
  find "$dir" -type f -name "${task_id}.md" | sort | head -n1
}

task_terminal_state() {
  local task_id="$1"
  local done_file blocked_file

  done_file="$(find_task_in_state done "$task_id")"
  if [[ -n "$done_file" ]]; then
    printf 'done:%s' "$done_file"
    return 0
  fi

  blocked_file="$(find_task_in_state blocked "$task_id")"
  if [[ -n "$blocked_file" ]]; then
    printf 'blocked:%s' "$blocked_file"
    return 0
  fi

  return 1
}

first_in_progress_task() {
  find "$ROOT/in_progress/$AGENT" -maxdepth 1 -type f -name '*.md' | sort | head -n1
}

has_non_whitespace_content() {
  local content="$1"
  printf '%s' "$content" | grep -q '[^[:space:]]'
}

task_sidecar_root() {
  local task_id="$1"
  printf '%s/task_prompts/%s' "$ROOT" "$task_id"
}

extract_task_section() {
  local task_file="$1"
  local section_name="$2"

  awk -v section_name="$section_name" '
    BEGIN { in_section = 0 }
    $0 == "## " section_name { in_section = 1; next }
    in_section && /^## [^#]/ { exit }
    in_section { print }
  ' "$task_file"
}

read_sidecar_section_fragments() {
  local sidecar_root="$1"
  local section_key="$2"
  local section_name="$3"
  local section_dir="$sidecar_root/$section_key"

  [[ -d "$section_dir" ]] || return 0
  [[ -r "$section_dir" && -x "$section_dir" ]] || {
    echo "unreadable sidecar section directory for task section ${section_name}: $section_dir" >&2
    return 1
  }

  local -a fragments=()
  mapfile -t fragments < <(find "$section_dir" -maxdepth 1 -type f -name '*.md' ! -name '.*' -printf '%f\n' | sort)

  local fragment
  for fragment in "${fragments[@]}"; do
    cat "$section_dir/$fragment"
    printf '\n'
  done
}

build_prompt_file() {
  local task_file="$1"
  local prompt_file="$2"
  shift 2
  local -a write_targets=("$@")
  local task_id task_title owner_agent creator_agent
  task_id="$(field_value "$task_file" "id")"
  [[ -n "$task_id" ]] || task_id="$(basename "$task_file" .md)"
  task_title="$(field_value "$task_file" "title")"
  owner_agent="$(field_value "$task_file" "owner_agent")"
  creator_agent="$(field_value "$task_file" "creator_agent")"

  local sidecar_root sidecar_present=0
  sidecar_root="$(task_sidecar_root "$task_id")"
  if [[ -e "$sidecar_root" ]]; then
    [[ -d "$sidecar_root" ]] || {
      echo "task sidecar path is not a directory: $sidecar_root" >&2
      return 1
    }
    [[ -r "$sidecar_root" && -x "$sidecar_root" ]] || {
      echo "task sidecar root is unreadable: $sidecar_root" >&2
      return 1
    }
    sidecar_present=1
  fi

  cat >"$prompt_file" <<PROMPT
You are running as background worker agent '$AGENT' in repository '$WORKDIR'.

Task file path: $task_file

Task metadata:
- id: ${task_id}
- title: ${task_title:-unknown}
- owner_agent: ${owner_agent:-unknown}
- creator_agent: ${creator_agent:-unknown}
- sidecar_prompt_root: ${sidecar_root}
PROMPT

  local -a section_names=("Prompt" "Context" "Deliverables" "Validation")
  local -a section_keys=("prompt" "context" "deliverables" "validation")
  local idx section_name section_key section_content
  for idx in "${!section_names[@]}"; do
    section_name="${section_names[$idx]}"
    section_key="${section_keys[$idx]}"
    section_content=""

    if [[ "$sidecar_present" -eq 1 ]]; then
      if ! section_content="$(read_sidecar_section_fragments "$sidecar_root" "$section_key" "$section_name")"; then
        return 1
      fi
    fi

    if ! has_non_whitespace_content "$section_content"; then
      section_content="$(extract_task_section "$task_file" "$section_name")"
    fi

    if ! has_non_whitespace_content "$section_content"; then
      section_content="MISSING SECTION: $section_name"
    fi

    printf '\n## %s\n%s\n' "$section_name" "$section_content" >>"$prompt_file"
  done

  cat >>"$prompt_file" <<'PROMPT'

Execution requirements:
- Implement the task in the current repository.
- Keep changes scoped to the task.
- Run relevant checks/tests for touched areas.
- Update the task file's "## Result" section with explicit evidence:
  - `Requirement Statuses:` entries in format `- <requirement_id>: Met|Partial|Missing|Unverifiable`
  - `Acceptance Criteria:` with pass/fail status for scoped criteria
  - one or more `Command:` lines
  - corresponding `Exit:` lines
  - corresponding `Log:` lines
  - concise observed output summary
- For benchmark tasks, include `Gate Statuses:` entries and category score lines expected by task metadata/profile.
- If blocked by dependency or ambiguity, clearly state blocker in the task file and exit non-zero.
PROMPT

  if (( ${#write_targets[@]} > 0 )); then
    cat >>"$prompt_file" <<'PROMPT'
- Worker lock policy is enforced from `intended_write_targets`; do not modify files outside declared targets.
- If additional files must be modified, stop and block with a clear reason to request task metadata updates.

Declared write targets:
PROMPT
    local target
    for target in "${write_targets[@]}"; do
      printf -- "- %s\n" "$target" >>"$prompt_file"
    done
  fi
}

acquire_task_write_locks() {
  local task_id="$1"
  local -n targets_ref="$2"
  local -n acquired_ref="$3"
  local -n lock_error_ref="$4"
  lock_error_ref=""

  local target lock_output rc
  for target in "${targets_ref[@]}"; do
    if lock_output="$(run_taskctl lock-acquire "$task_id" "$AGENT" "$target" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
      acquired_ref+=("$target")
      continue
    fi

    lock_output="$(sanitize_single_line "$lock_output")"
    if [[ $rc -eq 2 ]]; then
      lock_error_ref="write lock conflict for target=$target; ${lock_output:-lock conflict}"
      return 2
    fi

    lock_error_ref="write lock acquisition failed for target=$target (exit=$rc); ${lock_output:-taskctl lock-acquire failed}"
    return 1
  done

  return 0
}

heartbeat_lock_targets_loop() {
  local task_id="$1"
  shift
  local -a targets=("$@")

  while true; do
    sleep "$LOCK_HEARTBEAT_INTERVAL"
    local target hb_output hb_rc
    for target in "${targets[@]}"; do
      if hb_output="$(run_taskctl lock-heartbeat "$task_id" "$AGENT" "$target" 2>&1)"; then
        hb_rc=0
      else
        hb_rc=$?
      fi

      if [[ $hb_rc -ne 0 ]]; then
        log "lock heartbeat failed for $task_id target=$target (exit=$hb_rc): $(sanitize_single_line "$hb_output")"
      fi
    done
  done
}

start_lock_heartbeat_loop() {
  local -n pid_ref="$1"
  local task_id="$2"
  shift 2
  local -a targets=("$@")
  pid_ref=""

  if (( ${#targets[@]} == 0 )); then
    return 0
  fi

  heartbeat_lock_targets_loop "$task_id" "${targets[@]}" &
  pid_ref="$!"
}

stop_background_loop() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0

  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

release_task_locks() {
  local task_id="$1"
  local output rc
  if output="$(run_taskctl lock-release-task "$task_id" "$AGENT" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    log "warning: lock release failed for $task_id (exit=$rc): $(sanitize_single_line "$output")"
    return 1
  fi

  log "$(sanitize_single_line "$output")"
}

run_task() {
  local task_file="$1"
  local task_id
  task_id="$(field_value "$task_file" "id")"
  [[ -n "$task_id" ]] || task_id="$(basename "$task_file" .md)"

  local -a write_targets=()
  if ! mapfile -t write_targets < <(task_intended_write_targets "$task_file"); then
    local metadata_reason
    metadata_reason="worker failed to parse intended_write_targets metadata for $task_id"
    local metadata_in_progress
    metadata_in_progress="$(in_progress_task_path "$task_id")"
    if [[ -f "$metadata_in_progress" ]]; then
      run_taskctl block "$AGENT" "$task_id" "$metadata_reason" >/dev/null || true
      log "blocked $task_id ($metadata_reason)"
    else
      log "$metadata_reason but task is no longer in progress"
    fi
    return
  fi

  local run_dir="$ROOT/runtime/logs/$AGENT"
  mkdir -p "$run_dir"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local log_file="$run_dir/${task_id}-${stamp}.log"
  local in_progress_file
  in_progress_file="$(in_progress_task_path "$task_id")"

  local prompt_file
  prompt_file="$(mktemp)"
  local build_error=""
  if ! build_error="$(build_prompt_file "$task_file" "$prompt_file" "${write_targets[@]}" 2>&1)"; then
    rm -f "$prompt_file"
    build_error="$(sanitize_single_line "$build_error")"
    local prompt_reason
    prompt_reason="worker prompt assembly failed for $task_id; ${build_error:-unknown prompt assembly error}"
    if [[ -f "$in_progress_file" ]]; then
      run_taskctl block "$AGENT" "$task_id" "$prompt_reason" >/dev/null || true
      log "blocked $task_id ($prompt_reason)"
    else
      log "$prompt_reason but task is no longer in progress"
    fi
    return
  fi

  local reasoning_effort
  reasoning_effort="$(reasoning_effort_for_agent)"
  log "starting $task_id (reasoning_effort=$reasoning_effort, write_targets=${#write_targets[@]})"

  local -a acquired_targets=()
  local lock_error=""
  local lock_rc=0
  local heartbeat_pid=""

  if (( ${#write_targets[@]} > 0 )); then
    if acquire_task_write_locks "$task_id" write_targets acquired_targets lock_error; then
      lock_rc=0
    else
      lock_rc=$?
    fi

    if [[ $lock_rc -ne 0 ]]; then
      rm -f "$prompt_file"
      release_task_locks "$task_id" >/dev/null 2>&1 || true
      if [[ -f "$in_progress_file" ]]; then
        run_taskctl block "$AGENT" "$task_id" "$lock_error" >/dev/null || true
        log "blocked $task_id ($lock_error)"
      else
        local terminal_state
        terminal_state="$(task_terminal_state "$task_id" || true)"
        if [[ -n "$terminal_state" ]]; then
          log "lock enforcement for $task_id failed after transition (state=$terminal_state, reason=$lock_error)"
        else
          log "lock enforcement for $task_id failed but task is no longer in progress (reason=$lock_error)"
        fi
      fi
      return
    fi

    start_lock_heartbeat_loop heartbeat_pid "$task_id" "${acquired_targets[@]}"
  fi

  set +e
  if [[ -n "${AGENT_EXEC_CMD:-}" ]]; then
    bash -lc "$AGENT_EXEC_CMD" <"$prompt_file" >"$log_file" 2>&1
  else
    run_default_exec_cmd "$prompt_file" "$log_file" "$reasoning_effort"
  fi
  local rc=$?
  set -e

  stop_background_loop "$heartbeat_pid"
  if (( ${#write_targets[@]} > 0 )); then
    release_task_locks "$task_id" >/dev/null 2>&1 || true
  fi

  rm -f "$prompt_file"

  if [[ $rc -eq 0 ]]; then
    if [[ -f "$in_progress_file" ]]; then
      local verify_output verify_rc
      if verify_output="$(run_taskctl verify-done "$AGENT" "$task_id" 2>&1)"; then
        verify_rc=0
      else
        verify_rc=$?
      fi

      if [[ $verify_rc -ne 0 ]]; then
        local verify_reason
        verify_reason="done verification failed: $(sanitize_single_line "$verify_output")"
        run_taskctl block "$AGENT" "$task_id" "$verify_reason" >/dev/null || true
        log "blocked $task_id ($verify_reason, log: $log_file)"
      elif run_taskctl done "$AGENT" "$task_id" "Completed by worker; log: $log_file" >/dev/null; then
        log "completed $task_id (log: $log_file)"
      else
        local terminal_state
        terminal_state="$(task_terminal_state "$task_id" || true)"
        if [[ -n "$terminal_state" ]]; then
          log "completed $task_id (already transitioned: $terminal_state, log: $log_file)"
        else
          log "completed $task_id but done transition failed (log: $log_file)"
        fi
      fi
    else
      local terminal_state
      terminal_state="$(task_terminal_state "$task_id" || true)"
      if [[ -n "$terminal_state" ]]; then
        log "completed $task_id (already transitioned: $terminal_state, log: $log_file)"
      else
        log "completed $task_id but task is no longer in progress (log: $log_file)"
      fi
    fi
  else
    if [[ -f "$in_progress_file" ]]; then
      run_taskctl block "$AGENT" "$task_id" "worker command failed (exit=$rc); see $log_file" >/dev/null || true
      log "blocked $task_id (exit=$rc, log: $log_file)"
    else
      local terminal_state
      terminal_state="$(task_terminal_state "$task_id" || true)"
      if [[ -n "$terminal_state" ]]; then
        log "task $task_id already transitioned after worker failure (state=$terminal_state, exit=$rc, log: $log_file)"
      else
        log "worker failed for $task_id (exit=$rc, log: $log_file); task no longer in progress, transition skipped"
      fi
    fi
  fi
}

main_loop() {
  while true; do
    local task_file
    task_file="$(first_in_progress_task)"

    if [[ -z "$task_file" ]]; then
      run_taskctl claim "$AGENT" >/tmp/agent-claim-${AGENT}.out 2>/tmp/agent-claim-${AGENT}.err || true
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

validate_reasoning_config
validate_lock_config

mkdir -p "$ROOT/runtime/logs/$AGENT" "$ROOT/runtime/pids"
log "worker started (interval=${INTERVAL}s, once=$RUN_ONCE)"
main_loop
log "worker stopped"
