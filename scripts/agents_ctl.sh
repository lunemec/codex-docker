#!/usr/bin/env bash
set -euo pipefail

ROOT="coordination"
PID_DIR="$ROOT/runtime/pids"
LOG_DIR="$ROOT/runtime/logs"
WORKER="scripts/agent_worker.sh"
AGENTS=(db be fe review)
INTERVAL="${AGENT_POLL_INTERVAL:-30}"

usage() {
  cat <<USAGE
Usage:
  $0 start [--interval N]
  $0 stop
  $0 status
  $0 restart [--interval N]

Controls background specialist workers: db, be, fe, review.
USAGE
}

is_running() {
  local pid="$1"
  kill -0 "$pid" >/dev/null 2>&1
}

start_one() {
  local agent="$1"
  local pid_file="$PID_DIR/${agent}.pid"
  local log_file="$LOG_DIR/${agent}.worker.log"

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
  local inbox_count inprog_count
  inbox_count="$(find "$ROOT/inbox/$agent" -maxdepth 1 -type f -name 'TASK-*.md' | wc -l | tr -d ' ')"
  inprog_count="$(find "$ROOT/in_progress/$agent" -maxdepth 1 -type f -name 'TASK-*.md' | wc -l | tr -d ' ')"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if is_running "$pid"; then
      echo "$agent: running pid=$pid inbox=$inbox_count in_progress=$inprog_count"
      return
    fi
    echo "$agent: stale pid=$pid inbox=$inbox_count in_progress=$inprog_count"
    return
  fi

  echo "$agent: stopped inbox=$inbox_count in_progress=$inprog_count"
}

CMD="${1:-}"
shift || true

case "$CMD" in
  start)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
      esac
    done
    for a in "${AGENTS[@]}"; do start_one "$a"; done
    ;;
  stop)
    for a in "${AGENTS[@]}"; do stop_one "$a"; done
    ;;
  status)
    for a in "${AGENTS[@]}"; do status_one "$a"; done
    ;;
  restart)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
      esac
    done
    for a in "${AGENTS[@]}"; do stop_one "$a"; done
    for a in "${AGENTS[@]}"; do start_one "$a"; done
    ;;
  *)
    usage
    exit 1
    ;;
esac
