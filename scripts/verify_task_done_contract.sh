#!/usr/bin/env bash
set -euo pipefail

TASKCTL="${1:-scripts/taskctl.sh}"
TEMPLATE_FILE="${2:-coordination/templates/TASK_TEMPLATE.md}"

if [[ ! -x "$TASKCTL" ]]; then
  echo "taskctl script not executable: $TASKCTL" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "task template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

smoke_root="$(mktemp -d /workspace/.taskctl-verify-done.XXXXXX)"
trap 'rm -rf "$smoke_root"' EXIT

mkdir -p "$smoke_root/templates"
cp "$TEMPLATE_FILE" "$smoke_root/templates/TASK_TEMPLATE.md"

run_taskctl() {
  TASK_ROOT_DIR="$smoke_root" "$TASKCTL" "$@"
}

inject_result_block() {
  local task_file="$1"
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { in_result = 0; emitted = 0 }
    /^## Result$/ {
      print
      print "Requirement Statuses:"
      print "- REQ-001: Met"
      print "Acceptance Criteria:"
      print "- PASS: Criterion 1"
      print "Command: go test ./pkg/service -count=1"
      print "Exit: 0"
      print "Log: /tmp/verify-done.log"
      print "Observed: PASS"
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
        print "- REQ-001: Met"
        print "Acceptance Criteria:"
        print "- PASS: Criterion 1"
        print "Command: go test ./pkg/service -count=1"
        print "Exit: 0"
        print "Log: /tmp/verify-done.log"
        print "Observed: PASS"
      }
    }
  ' "$task_file" >"$tmp"
  mv "$tmp" "$task_file"
}

exec_task_id="verify-done-exec-$(date +%s)-$$"
run_taskctl create "$exec_task_id" "Execute phase done verification" --to be --from pm --priority 20 --phase execute --write-target scripts/taskctl.sh >/dev/null
run_taskctl claim be >/dev/null

exec_task_file="$smoke_root/in_progress/be/${exec_task_id}.md"
if [[ ! -f "$exec_task_file" ]]; then
  echo "expected execute task in progress not found: $exec_task_file" >&2
  exit 1
fi

set +e
verify_fail_output="$(run_taskctl verify-done be "$exec_task_id" 2>&1)"
verify_fail_rc=$?
set -e

if [[ "$verify_fail_rc" -eq 0 ]]; then
  echo "expected verify-done failure for placeholder execute result" >&2
  exit 1
fi

if ! printf '%s' "$verify_fail_output" | grep -Fq "requires non-placeholder ## Result evidence"; then
  echo "unexpected verify-done failure output" >&2
  echo "$verify_fail_output" >&2
  exit 1
fi

artifact_path="$smoke_root/runtime/verify-done-artifact.txt"
mkdir -p "$(dirname "$artifact_path")"
echo "artifact" > "$artifact_path"

sed -i "s|^requirement_ids:.*|requirement_ids: ['REQ-001']|" "$exec_task_file"
sed -i "s|^evidence_commands:.*|evidence_commands: ['go test ./pkg/service -count=1']|" "$exec_task_file"
sed -i "s|^evidence_artifacts:.*|evidence_artifacts: ['$artifact_path']|" "$exec_task_file"
inject_result_block "$exec_task_file"

run_taskctl verify-done be "$exec_task_id" >/dev/null
run_taskctl done be "$exec_task_id" "verified done contract smoke" >/dev/null

done_exec_file="$(find "$smoke_root/done/be" -type f -name "${exec_task_id}.md" | head -n1)"
if [[ -z "$done_exec_file" ]]; then
  echo "expected execute task in done queue after verify-done success" >&2
  exit 1
fi

plan_task_id="verify-done-plan-$(date +%s)-$$"
run_taskctl create "$plan_task_id" "Plan phase completion note fallback" --to planner --from pm --priority 30 --phase plan >/dev/null
run_taskctl claim planner >/dev/null
run_taskctl done planner "$plan_task_id" "plan artifact synthesized and handed off" >/dev/null

done_plan_file="$(find "$smoke_root/done/planner" -type f -name "${plan_task_id}.md" | head -n1)"
if [[ -z "$done_plan_file" ]]; then
  echo "expected plan task in done queue after completion note fallback" >&2
  exit 1
fi

echo "task done verification contract checks passed: $TASKCTL"
