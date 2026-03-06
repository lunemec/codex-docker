#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_FILE="${1:-coordination/templates/TASK_TEMPLATE.md}"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "task template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

require_line() {
  local needle="$1"
  local description="$2"

  if ! rg -q --fixed-strings "$needle" "$TEMPLATE_FILE"; then
    echo "missing task template contract clause: $description" >&2
    echo "expected line: $needle" >&2
    exit 1
  fi
}

extract_frontmatter() {
  local source_file="$1"
  local out_file="$2"

  awk '
    BEGIN { section = 0 }
    /^---$/ { section++; next }
    section == 1 { print }
    section >= 2 { exit }
  ' "$source_file" >"$out_file"

  if [[ ! -s "$out_file" ]]; then
    echo "unable to extract YAML frontmatter from: $source_file" >&2
    exit 1
  fi
}

assert_yaml_expr() {
  local yaml_file="$1"
  local expr="$2"
  local description="$3"

  if ! yq -e "$expr" "$yaml_file" >/dev/null; then
    echo "yaml assertion failed: $description" >&2
    echo "expression: $expr" >&2
    exit 1
  fi
}

require_line "intended_write_targets: []" "intended_write_targets default list"
require_line "lock_scope: file" "lock scope default"
require_line "lock_policy: block_on_conflict" "lock policy default"
require_line "phase: plan" "task phase default"
require_line "requirement_ids: []" "requirement_ids default list"
require_line "evidence_commands: []" "evidence_commands default list"
require_line "evidence_artifacts: []" "evidence_artifacts default list"
require_line "benchmark_profile: none" "benchmark_profile default"
require_line "gate_targets: []" "gate_targets default list"
require_line "scorecard_artifact: none" "scorecard_artifact default"

template_frontmatter="$(mktemp)"
smoke_root="$(mktemp -d /workspace/.task-template-lock-smoke.XXXXXX)"
trap 'rm -f "$template_frontmatter"; rm -rf "$smoke_root"' EXIT

extract_frontmatter "$TEMPLATE_FILE" "$template_frontmatter"
assert_yaml_expr "$template_frontmatter" '.intended_write_targets | type == "array"' "intended_write_targets is an array"
assert_yaml_expr "$template_frontmatter" '.intended_write_targets == []' "intended_write_targets defaults to an empty list"
assert_yaml_expr "$template_frontmatter" '.lock_scope == "file"' "lock_scope defaults to file"
assert_yaml_expr "$template_frontmatter" '.lock_policy == "block_on_conflict"' "lock_policy defaults to block_on_conflict"
assert_yaml_expr "$template_frontmatter" '.phase == "plan"' "phase defaults to plan"
assert_yaml_expr "$template_frontmatter" '.requirement_ids | type == "array"' "requirement_ids is an array"
assert_yaml_expr "$template_frontmatter" '.evidence_commands | type == "array"' "evidence_commands is an array"
assert_yaml_expr "$template_frontmatter" '.evidence_artifacts | type == "array"' "evidence_artifacts is an array"
assert_yaml_expr "$template_frontmatter" '.benchmark_profile == "none"' "benchmark_profile defaults to none"
assert_yaml_expr "$template_frontmatter" '.gate_targets | type == "array"' "gate_targets is an array"
assert_yaml_expr "$template_frontmatter" '.scorecard_artifact == "none"' "scorecard_artifact defaults to none"

mkdir -p "$smoke_root/templates"
cp "$TEMPLATE_FILE" "$smoke_root/templates/TASK_TEMPLATE.md"

task_id="task-template-lock-smoke-$(date +%s)-$$"
TASK_ROOT_DIR="$smoke_root" scripts/taskctl.sh create "$task_id" "Task Template Lock Metadata Smoke" --to pm --from pm --priority 50 >/dev/null

created_task="$smoke_root/inbox/pm/050/${task_id}.md"
if [[ ! -f "$created_task" ]]; then
  echo "task creation smoke test failed: missing task file $created_task" >&2
  exit 1
fi

created_frontmatter="$(mktemp)"
trap 'rm -f "$template_frontmatter" "$created_frontmatter"; rm -rf "$smoke_root"' EXIT

extract_frontmatter "$created_task" "$created_frontmatter"
assert_yaml_expr "$created_frontmatter" '.intended_write_targets == []' "created task persists intended_write_targets"
assert_yaml_expr "$created_frontmatter" '.lock_scope == "file"' "created task persists lock_scope"
assert_yaml_expr "$created_frontmatter" '.lock_policy == "block_on_conflict"' "created task persists lock_policy"
assert_yaml_expr "$created_frontmatter" '.phase == "plan"' "created task persists phase"
assert_yaml_expr "$created_frontmatter" '.requirement_ids == []' "created task persists requirement_ids"
assert_yaml_expr "$created_frontmatter" '.evidence_commands == []' "created task persists evidence_commands"
assert_yaml_expr "$created_frontmatter" '.evidence_artifacts == []' "created task persists evidence_artifacts"
assert_yaml_expr "$created_frontmatter" '.benchmark_profile == "none"' "created task persists benchmark_profile"
assert_yaml_expr "$created_frontmatter" '.gate_targets == []' "created task persists gate_targets"
assert_yaml_expr "$created_frontmatter" '.scorecard_artifact == "none"' "created task persists scorecard_artifact"

echo "task template lock metadata contract checks passed: $TEMPLATE_FILE"
