#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

BASELINE="$TMPDIR/baseline"
WS="$TMPDIR/workspace"
mkdir -p "$BASELINE/scripts" "$BASELINE/coordination" "$WS"

mkdir -p "$BASELINE/coordination/prompts" "$BASELINE/coordination/roles" "$BASELINE/coordination/templates" "$BASELINE/coordination/benchmark_profiles" "$BASELINE/coordination/examples"
echo "baseline-script-v2" > "$BASELINE/scripts/taskctl.sh"
echo "baseline-prompt-v2" > "$BASELINE/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md"
echo "baseline-role-v2" > "$BASELINE/coordination/roles/be.md"
echo "baseline-template-v2" > "$BASELINE/coordination/templates/task.md"
echo "baseline-benchmark-profile-v2" > "$BASELINE/coordination/benchmark_profiles/profile.json"
echo "baseline-example-v2" > "$BASELINE/coordination/examples/sample.md"

mkdir -p "$WS/scripts" "$WS/coordination/prompts" "$WS/coordination/benchmark_profiles" "$WS/coordination/inbox/be/010" "$WS/coordination/in_progress/be" "$WS/coordination/done/be/050" "$WS/coordination/blocked/be/001" "$WS/coordination/reports/be" "$WS/coordination/runtime/logs" "$WS/coordination/task_prompts/TASK-KEEP"

echo "old-script" > "$WS/scripts/taskctl.sh"
echo "old-prompt" > "$WS/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md"
echo "old-benchmark-profile" > "$WS/coordination/benchmark_profiles/profile.json"
echo "task-data" > "$WS/coordination/inbox/be/010/TASK-KEEP.md"
echo "inprogress-data" > "$WS/coordination/in_progress/be/TASK-IP.md"
echo "done-data" > "$WS/coordination/done/be/050/TASK-DONE.md"
echo "blocked-data" > "$WS/coordination/blocked/be/001/TASK-BLK.md"
echo "report-data" > "$WS/coordination/reports/be/REPORT.md"
echo "runtime-data" > "$WS/coordination/runtime/logs/worker.log"
echo "task-prompt-data" > "$WS/coordination/task_prompts/TASK-KEEP/prompt.md"

( 
  export BASELINE_ROOT="$BASELINE"
  "$ROOT/container/codex-init-workspace.sh" --workspace "$WS" --force --quiet
)

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $msg (expected='$expected' actual='$actual')" >&2
    exit 1
  fi
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "FAIL: missing file $path" >&2; exit 1; }
}

assert_file "$WS/scripts/taskctl.sh"
assert_file "$WS/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md"
assert_eq "baseline-script-v2" "$(cat "$WS/scripts/taskctl.sh")" "scripts should refresh from baseline"
assert_eq "baseline-prompt-v2" "$(cat "$WS/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md")" "prompt should refresh from baseline"
assert_eq "baseline-role-v2" "$(cat "$WS/coordination/roles/be.md")" "roles should refresh from baseline"
assert_eq "baseline-template-v2" "$(cat "$WS/coordination/templates/task.md")" "templates should refresh from baseline"
assert_eq "baseline-benchmark-profile-v2" "$(cat "$WS/coordination/benchmark_profiles/profile.json")" "benchmark profiles should refresh from baseline"
assert_eq "baseline-example-v2" "$(cat "$WS/coordination/examples/sample.md")" "examples should refresh from baseline"

assert_eq "task-data" "$(cat "$WS/coordination/inbox/be/010/TASK-KEEP.md")" "inbox task must be preserved"
assert_eq "inprogress-data" "$(cat "$WS/coordination/in_progress/be/TASK-IP.md")" "in_progress task must be preserved"
assert_eq "done-data" "$(cat "$WS/coordination/done/be/050/TASK-DONE.md")" "done task must be preserved"
assert_eq "blocked-data" "$(cat "$WS/coordination/blocked/be/001/TASK-BLK.md")" "blocked task must be preserved"
assert_eq "report-data" "$(cat "$WS/coordination/reports/be/REPORT.md")" "reports must be preserved"
assert_eq "runtime-data" "$(cat "$WS/coordination/runtime/logs/worker.log")" "runtime must be preserved"
assert_eq "task-prompt-data" "$(cat "$WS/coordination/task_prompts/TASK-KEEP/prompt.md")" "task local prompts must be preserved"

echo "PASS: coordination repair contract verified"
