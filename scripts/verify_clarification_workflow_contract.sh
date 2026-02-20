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

field_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}: //p" "$file" | head -n1
}

count_open_blocker_reports_for_parent() {
  local root="$1"
  local parent_task_id="$2"
  local count=0
  local blocker_file blocked_task_file blocked_parent

  while IFS= read -r blocker_file; do
    blocked_task_file="$(sed -n 's/^- blocked_task_file: //p' "$blocker_file" | head -n1)"
    [[ -n "$blocked_task_file" && -f "$blocked_task_file" ]] || continue

    blocked_parent="$(field_value "$blocked_task_file" "parent_task_id")"
    if [[ "$blocked_parent" == "$parent_task_id" ]]; then
      count=$((count + 1))
    fi
  done < <(find "$root/inbox" "$root/in_progress" -type f -name 'BLK-*.md' 2>/dev/null | sort)

  printf '%d' "$count"
}

parent_has_unresolved_critical_assumptions() {
  local parent_task_file="$1"
  rg -qi 'unresolved critical assumptions?|critical assumption unresolved' "$parent_task_file"
}

clarification_gate_ready() {
  local root="$1"
  local parent_task_file="$2"
  local explicit_user_confirmation="$3"

  local parent_task_id open_blockers
  parent_task_id="$(field_value "$parent_task_file" "id")"
  [[ -n "$parent_task_id" ]] || {
    echo "parent task is missing id field: $parent_task_file" >&2
    return 2
  }

  if [[ "$explicit_user_confirmation" != "yes" ]]; then
    echo "clarification gate blocked: explicit user confirmation missing"
    return 1
  fi

  open_blockers="$(count_open_blocker_reports_for_parent "$root" "$parent_task_id")"
  if [[ "$open_blockers" != "0" ]]; then
    echo "clarification gate blocked: open blocker reports=$open_blockers"
    return 1
  fi

  if parent_has_unresolved_critical_assumptions "$parent_task_file"; then
    echo "clarification gate blocked: unresolved critical assumptions remain"
    return 1
  fi

  echo "clarification gate ready: parent_task_id=$parent_task_id"
}

smoke_root="$(mktemp -d /workspace/.clarification-workflow-smoke.XXXXXX)"
trap 'rm -rf "$smoke_root"' EXIT

mkdir -p "$smoke_root/templates"
cp "$TEMPLATE_FILE" "$smoke_root/templates/TASK_TEMPLATE.md"

run_taskctl() {
  TASK_ROOT_DIR="$smoke_root" "$TASKCTL" "$@"
}

parent_task_id="clarify-parent-$(date +%s)-$$"
child_task_id="clarify-child-$(date +%s)-$$"

run_taskctl create "$parent_task_id" "Clarification parent task" --to coordinator --from pm --priority 10 >/dev/null
run_taskctl claim coordinator >/dev/null

parent_task_file="$smoke_root/in_progress/coordinator/${parent_task_id}.md"
if [[ ! -f "$parent_task_file" ]]; then
  echo "expected parent task in progress file not found: $parent_task_file" >&2
  exit 1
fi

run_taskctl delegate coordinator fe "$child_task_id" "Clarification specialist discovery" --priority 15 --parent "$parent_task_id" --write-target src/shared-spec.md >/dev/null
run_taskctl claim fe >/dev/null
run_taskctl block fe "$child_task_id" "write lock conflict for target=src/shared-spec.md" >/dev/null

blocked_child_file="$(find "$smoke_root/blocked/fe" -type f -name "${child_task_id}.md" | head -n1)"
if [[ -z "$blocked_child_file" ]]; then
  echo "expected blocked child task not found: $child_task_id" >&2
  exit 1
fi

blocker_report_file="$(find "$smoke_root/inbox/coordinator/000" -type f -name "BLK-${child_task_id}-*.md" | sort | head -n1)"
if [[ -z "$blocker_report_file" ]]; then
  echo "expected blocker report task not found for blocked child task: $child_task_id" >&2
  exit 1
fi

set +e
missing_confirmation_output="$(clarification_gate_ready "$smoke_root" "$parent_task_file" "no" 2>&1)"
missing_confirmation_rc=$?
set -e

if [[ "$missing_confirmation_rc" -eq 0 ]]; then
  echo "expected clarification gate failure without explicit user confirmation" >&2
  exit 1
fi
require_contains "$missing_confirmation_output" "explicit user confirmation missing" "confirmation gate failure message"

set +e
open_blocker_output="$(clarification_gate_ready "$smoke_root" "$parent_task_file" "yes" 2>&1)"
open_blocker_rc=$?
set -e

if [[ "$open_blocker_rc" -eq 0 ]]; then
  echo "expected clarification gate failure while blocker report is open" >&2
  exit 1
fi
require_contains "$open_blocker_output" "open blocker reports=1" "blocker gate failure message"

blocker_report_id="$(basename "$blocker_report_file" .md)"
run_taskctl claim coordinator >/dev/null
run_taskctl done coordinator "$blocker_report_id" "Blocker triaged for clarification workflow simulation" >/dev/null

resolved_report_file="$(find "$smoke_root/done/coordinator" -type f -name "${blocker_report_id}.md" | head -n1)"
if [[ -z "$resolved_report_file" ]]; then
  echo "expected blocker report in done queue after resolution: $blocker_report_id" >&2
  exit 1
fi

cat >>"$parent_task_file" <<'EOF'

## Clarification Notes
- unresolved critical assumption: API ownership not confirmed
EOF

set +e
assumption_output="$(clarification_gate_ready "$smoke_root" "$parent_task_file" "yes" 2>&1)"
assumption_rc=$?
set -e

if [[ "$assumption_rc" -eq 0 ]]; then
  echo "expected clarification gate failure while unresolved assumptions exist" >&2
  exit 1
fi
require_contains "$assumption_output" "unresolved critical assumptions remain" "assumption gate failure message"

sed -i 's/unresolved critical assumption:/resolved critical assumption:/' "$parent_task_file"

final_gate_output="$(clarification_gate_ready "$smoke_root" "$parent_task_file" "yes")"
require_contains "$final_gate_output" "clarification gate ready" "final gate pass message"

echo "clarification workflow contract checks passed: $TASKCTL"
