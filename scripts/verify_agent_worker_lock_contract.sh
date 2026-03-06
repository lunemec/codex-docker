#!/usr/bin/env bash
set -euo pipefail

TASKCTL="${1:-scripts/taskctl.sh}"
WORKER="${2:-scripts/agent_worker.sh}"
TEMPLATE_FILE="${3:-coordination/templates/TASK_TEMPLATE.md}"

if [[ ! -x "$TASKCTL" ]]; then
  echo "taskctl script not executable: $TASKCTL" >&2
  exit 1
fi

if [[ ! -x "$WORKER" ]]; then
  echo "worker script not executable: $WORKER" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "task template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

for cmd in jq yq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: $cmd" >&2
    exit 1
  fi
done

require_contains() {
  local haystack="$1"
  local needle="$2"
  local description="$3"

  if ! printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "missing expected output: $description" >&2
    echo "expected snippet: $needle" >&2
    exit 1
  fi
}

inject_result_evidence() {
  local task_file="$1"
  sed -i "s|^requirement_ids:.*|requirement_ids: ['REQ-LOCK-001']|" "$task_file"
  local tmp
  tmp="$(mktemp)"

  awk '
    BEGIN { in_result = 0; emitted = 0 }
    /^## Result$/ {
      print
      print "Requirement Statuses:"
      print "- REQ-LOCK-001: Met"
      print "Acceptance Criteria:"
      print "- PASS: lock contract setup"
      print "Command: lock-contract-smoke"
      print "Exit: 0"
      print "Log: /tmp/lock-contract-smoke.log"
      print "Observed: setup seeded"
      in_result = 1
      emitted = 1
      next
    }
    in_result && /^## [^#]/ {
      in_result = 0
      print
      next
    }
    in_result { next }
    { print }
    END {
      if (emitted == 0) {
        print "## Result"
        print "Requirement Statuses:"
        print "- REQ-LOCK-001: Met"
        print "Acceptance Criteria:"
        print "- PASS: lock contract setup"
        print "Command: lock-contract-smoke"
        print "Exit: 0"
        print "Log: /tmp/lock-contract-smoke.log"
        print "Observed: setup seeded"
      }
    }
  ' "$task_file" >"$tmp"

  mv "$tmp" "$task_file"
}

wait_for_locked_status() {
  local target="$1"
  local attempts="${2:-120}"
  local delay_seconds="${3:-0.1}"
  local status=""
  local i=0

  while (( i < attempts )); do
    status="$(run_taskctl lock-status "$target")"
    if printf '%s' "$status" | grep -Fq "status: locked"; then
      printf '%s' "$status"
      return 0
    fi
    sleep "$delay_seconds"
    i=$((i + 1))
  done

  echo "timed out waiting for lock on target: $target" >&2
  echo "$status" >&2
  return 1
}

smoke_root="$(mktemp -d /workspace/.agent-worker-lock-smoke.XXXXXX)"
worker1_pid=""

cleanup() {
  if [[ -n "$worker1_pid" ]] && kill -0 "$worker1_pid" >/dev/null 2>&1; then
    kill "$worker1_pid" >/dev/null 2>&1 || true
    wait "$worker1_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$smoke_root"
}
trap cleanup EXIT

mkdir -p "$smoke_root/templates"
cp "$TEMPLATE_FILE" "$smoke_root/templates/TASK_TEMPLATE.md"

run_taskctl() {
  TASK_ROOT_DIR="$smoke_root" "$TASKCTL" "$@"
}

task_one_id="worker-lock-a-$(date +%s)-$$"
task_two_id="worker-lock-b-$(date +%s)-$$"
task_fail_id="worker-lock-fail-$(date +%s)-$$"

run_taskctl create "$task_one_id" "Worker lock holder task" --to fe --from pm --priority 10 --write-target src/shared-target.txt >/dev/null
run_taskctl create "$task_two_id" "Worker lock conflict task" --to be --from pm --priority 10 --write-target src/shared-target.txt >/dev/null

task_one_file="$smoke_root/inbox/fe/010/${task_one_id}.md"
if [[ ! -f "$task_one_file" ]]; then
  echo "expected seeded task file missing: $task_one_file" >&2
  exit 1
fi
inject_result_evidence "$task_one_file"

AGENT_ROOT_DIR="$smoke_root" \
AGENT_TASKCTL="$TASKCTL" \
AGENT_EXEC_CMD='sleep 5' \
AGENT_LOCK_HEARTBEAT_INTERVAL=1 \
"$WORKER" fe --once >"$smoke_root/worker-one.log" 2>&1 &
worker1_pid="$!"

lock_status="$(wait_for_locked_status src/shared-target.txt)"
lock_file="$(printf '%s\n' "$lock_status" | sed -n 's/^lock_file: //p' | head -n1)"

if [[ -z "$lock_file" || ! -f "$lock_file" ]]; then
  echo "unable to resolve lock file for heartbeat validation" >&2
  echo "$lock_status" >&2
  exit 1
fi

initial_heartbeat="$(jq -r '.heartbeat_at // ""' "$lock_file")"
if [[ -z "$initial_heartbeat" ]]; then
  echo "missing initial heartbeat value" >&2
  cat "$lock_file" >&2
  exit 1
fi

set +e
AGENT_ROOT_DIR="$smoke_root" \
AGENT_TASKCTL="$TASKCTL" \
AGENT_EXEC_CMD='echo should-not-run' \
AGENT_LOCK_HEARTBEAT_INTERVAL=1 \
"$WORKER" be --once >"$smoke_root/worker-two.log" 2>&1
worker2_rc=$?
set -e

if [[ "$worker2_rc" -ne 0 ]]; then
  echo "second worker invocation failed unexpectedly (exit=$worker2_rc)" >&2
  cat "$smoke_root/worker-two.log" >&2
  exit 1
fi

sleep 2

if [[ ! -f "$lock_file" ]]; then
  echo "lock file vanished before heartbeat update check" >&2
  exit 1
fi

updated_heartbeat="$(jq -r '.heartbeat_at // ""' "$lock_file")"
if [[ -z "$updated_heartbeat" || "$updated_heartbeat" == "$initial_heartbeat" ]]; then
  echo "lock heartbeat did not update while worker was active" >&2
  echo "initial=$initial_heartbeat updated=$updated_heartbeat" >&2
  cat "$lock_file" >&2
  exit 1
fi

if ! wait "$worker1_pid"; then
  echo "first worker failed unexpectedly" >&2
  cat "$smoke_root/worker-one.log" >&2
  exit 1
fi
worker1_pid=""

done_file_one="$(find "$smoke_root/done/fe" -type f -name "${task_one_id}.md" | head -n1)"
blocked_file_two="$(find "$smoke_root/blocked/be" -type f -name "${task_two_id}.md" | head -n1)"

if [[ -z "$done_file_one" ]]; then
  echo "expected first task in done queue: $task_one_id" >&2
  exit 1
fi

if [[ -z "$blocked_file_two" ]]; then
  echo "expected second task in blocked queue: $task_two_id" >&2
  exit 1
fi

blocked_two_content="$(cat "$blocked_file_two")"
require_contains "$blocked_two_content" "write lock conflict" "conflicting task blocked with lock reason"

conflict_lock_status="$(run_taskctl lock-status src/shared-target.txt)"
require_contains "$conflict_lock_status" "status: unlocked" "shared target lock released after success/conflict handling"

run_taskctl create "$task_fail_id" "Worker failure lock release task" --to fe --from pm --priority 12 --write-target src/failure-target.txt >/dev/null

set +e
AGENT_ROOT_DIR="$smoke_root" \
AGENT_TASKCTL="$TASKCTL" \
AGENT_EXEC_CMD='exit 7' \
AGENT_LOCK_HEARTBEAT_INTERVAL=1 \
"$WORKER" fe --once >"$smoke_root/worker-fail.log" 2>&1
worker_fail_rc=$?
set -e

if [[ "$worker_fail_rc" -ne 0 ]]; then
  echo "failure-path worker invocation returned non-zero unexpectedly (exit=$worker_fail_rc)" >&2
  cat "$smoke_root/worker-fail.log" >&2
  exit 1
fi

blocked_file_fail="$(find "$smoke_root/blocked/fe" -type f -name "${task_fail_id}.md" | head -n1)"
if [[ -z "$blocked_file_fail" ]]; then
  echo "expected failed task in blocked queue: $task_fail_id" >&2
  exit 1
fi

blocked_fail_content="$(cat "$blocked_file_fail")"
require_contains "$blocked_fail_content" "worker command failed (exit=7)" "failed task recorded worker failure reason"

failure_lock_status="$(run_taskctl lock-status src/failure-target.txt)"
require_contains "$failure_lock_status" "status: unlocked" "failure target lock released after worker error"

echo "agent worker lock contract checks passed: $WORKER"
