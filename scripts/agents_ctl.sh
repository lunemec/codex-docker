#!/usr/bin/env bash
set -euo pipefail

ROOT="${AGENT_ROOT_DIR:-coordination}"
PID_DIR="$ROOT/runtime/pids"
LOG_DIR="$ROOT/runtime/logs"
WORKER="${AGENT_WORKER_SCRIPT:-scripts/agent_worker.sh}"
TASKCTL="${AGENT_TASKCTL:-scripts/taskctl.sh}"
INTERVAL="${AGENT_POLL_INTERVAL:-30}"
EXCLUDED_DEFAULT_START="${AGENTS_CTL_EXCLUDE:-pm coordinator}"

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
    echo "agents_ctl must run inside Docker (.dockerenv not found)" >&2
    exit 1
  }

  local cwd
  cwd="$(pwd -P)"
  [[ "$cwd" == "/workspace" || "$cwd" == /workspace/* ]] || {
    echo "agents_ctl must run from /workspace (current: $cwd)" >&2
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

  local worker_abs
  worker_abs="$(abs_path "$WORKER")"
  [[ "$worker_abs" == "/workspace" || "$worker_abs" == /workspace/* ]] || {
    echo "AGENT_WORKER_SCRIPT must resolve under /workspace (current: $worker_abs)" >&2
    exit 1
  }
}

require_container_workspace

usage() {
  cat <<USAGE
Usage:
  $0 start [--interval N] [--all] [agent ...]
  $0 stop [--all] [agent ...]
  $0 status [--all] [agent ...]
  $0 restart [--interval N] [--all] [agent ...]

Behavior:
  - If no agents are provided:
    - start/restart: runs all role-based agents except excluded orchestrators (default: pm, coordinator)
    - stop/status: uses any discovered role agents plus agents with pid files
  - Use --all to include orchestrator roles too.
USAGE
}

is_running() {
  local pid="$1"
  kill -0 "$pid" >/dev/null 2>&1
}

is_excluded_default() {
  local agent="$1"
  local item
  for item in $EXCLUDED_DEFAULT_START; do
    [[ "$agent" == "$item" ]] && return 0
  done
  return 1
}

discover_role_agents() {
  if [[ ! -d "$ROOT/roles" ]]; then
    return 0
  fi
  find "$ROOT/roles" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | sed 's/\.md$//' | sort -u
}

discover_pid_agents() {
  if [[ ! -d "$PID_DIR" ]]; then
    return 0
  fi
  find "$PID_DIR" -maxdepth 1 -type f -name '*.pid' -printf '%f\n' | sed 's/\.pid$//' | sort -u
}

unique_sorted() {
  awk 'NF' | sort -u
}

default_start_agents() {
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    if ! is_excluded_default "$agent"; then
      echo "$agent"
    fi
  done < <(discover_role_agents)
}

all_known_agents() {
  {
    discover_role_agents
    discover_pid_agents
  } | unique_sorted
}

resolve_agents() {
  local mode="$1"
  local include_all="$2"
  shift 2
  local explicit=("$@")

  if [[ ${#explicit[@]} -gt 0 ]]; then
    printf '%s\n' "${explicit[@]}" | unique_sorted
    return 0
  fi

  if [[ "$include_all" -eq 1 ]]; then
    all_known_agents
    return 0
  fi

  if [[ "$mode" == "start" || "$mode" == "restart" ]]; then
    default_start_agents
    return 0
  fi

  all_known_agents
}

start_one() {
  local agent="$1"
  local pid_file="$PID_DIR/${agent}.pid"
  local log_file="$LOG_DIR/${agent}.worker.log"

  "$TASKCTL" ensure-agent "$agent" >/dev/null

  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if is_running "$pid"; then
      echo "$agent already running (pid=$pid)"
      return
    fi
  fi

  mkdir -p "$PID_DIR" "$LOG_DIR"
  nohup "$WORKER" "$agent" --interval "$INTERVAL" >>"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" >"$pid_file"
  echo "started $agent (pid=$pid, interval=${INTERVAL}s)"
}

stop_one() {
  local agent="$1"
  local pid_file="$PID_DIR/${agent}.pid"

  if [[ ! -f "$pid_file" ]]; then
    echo "$agent not running"
    return
  fi

  local pid
  pid="$(cat "$pid_file")"
  if is_running "$pid"; then
    kill "$pid" || true
    sleep 0.2
    if is_running "$pid"; then
      kill -9 "$pid" || true
    fi
    echo "stopped $agent (pid=$pid)"
  else
    echo "$agent stale pid ($pid)"
  fi

  rm -f "$pid_file"
}

status_one() {
  local agent="$1"
  local pid_file="$PID_DIR/${agent}.pid"

  local inbox_count inprog_count blocked_count report_count
  inbox_count="$(count_md_files "$ROOT/inbox/$agent")"
  inprog_count="$(count_md_files "$ROOT/in_progress/$agent")"
  blocked_count="$(count_md_files "$ROOT/blocked/$agent")"
  report_count="$(count_md_files "$ROOT/reports/$agent")"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if is_running "$pid"; then
      echo "$agent: running pid=$pid inbox=$inbox_count in_progress=$inprog_count blocked=$blocked_count reports=$report_count"
      return
    fi
    echo "$agent: stale pid=$pid inbox=$inbox_count in_progress=$inprog_count blocked=$blocked_count reports=$report_count"
    return
  fi

  echo "$agent: stopped inbox=$inbox_count in_progress=$inprog_count blocked=$blocked_count reports=$report_count"
}

count_md_files() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    find "$dir" -type f -name '*.md' | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

CMD="${1:-}"
shift || true

case "$CMD" in
  start|stop|status|restart) ;;
  *)
    usage
    exit 1
    ;;
esac

INCLUDE_ALL=0
EXPLICIT_AGENTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --all)
      INCLUDE_ALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      EXPLICIT_AGENTS+=("$1")
      shift
      ;;
  esac
done

mapfile -t AGENTS < <(resolve_agents "$CMD" "$INCLUDE_ALL" "${EXPLICIT_AGENTS[@]}")

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  echo "no agents resolved" >&2
  exit 1
fi

case "$CMD" in
  start)
    for a in "${AGENTS[@]}"; do start_one "$a"; done
    ;;
  stop)
    for a in "${AGENTS[@]}"; do stop_one "$a"; done
    ;;
  status)
    for a in "${AGENTS[@]}"; do status_one "$a"; done
    ;;
  restart)
    for a in "${AGENTS[@]}"; do stop_one "$a"; done
    for a in "${AGENTS[@]}"; do start_one "$a"; done
    ;;
esac
