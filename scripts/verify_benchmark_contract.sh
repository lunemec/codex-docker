#!/usr/bin/env bash
set -euo pipefail

TASKCTL="${1:-scripts/taskctl.sh}"
TEMPLATE_FILE="${2:-coordination/templates/TASK_TEMPLATE.md}"
PROFILE_FILE="${3:-coordination/benchmark_profiles/vault_sync_prompt_v1.json}"

if [[ ! -x "$TASKCTL" ]]; then
  echo "taskctl script not executable: $TASKCTL" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "task template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

if [[ ! -f "$PROFILE_FILE" ]]; then
  echo "benchmark profile file not found: $PROFILE_FILE" >&2
  exit 1
fi

for cmd in jq yq go; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: $cmd" >&2
    exit 1
  fi
done

smoke_root="$(mktemp -d /workspace/.benchmark-contract-smoke.XXXXXX)"
trap 'rm -rf "$smoke_root"' EXIT

mkdir -p "$smoke_root/templates" "$smoke_root/benchmark_profiles"
cp "$TEMPLATE_FILE" "$smoke_root/templates/TASK_TEMPLATE.md"
cp "$PROFILE_FILE" "$smoke_root/benchmark_profiles/vault_sync_prompt_v1.json"

run_taskctl() {
  TASK_ROOT_DIR="$smoke_root" "$TASKCTL" "$@"
}

write_log() {
  local path="$1"
  local body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
}

compute_hash() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    cksum "$path" | awk '{print $1}'
  fi
}

inject_result_block() {
  local task_file="$1"
  local artifact_path="$2"
  local benchmark_workdir="$3"
  local logs_root="$4"
  local tmp
  tmp="$(mktemp)"

  local hash_g1_go_version hash_g1_go_build hash_g1_go_test hash_g1_go_test_fresh
  local hash_g2_auth_sync hash_g2_cli_sync hash_g3_archive_pipeline hash_g3_provenance
  local hash_g4_architecture hash_g5_integration hash_g6_fresh_pass
  local hash_red hash_green hash_blue
  hash_g1_go_version="$(compute_hash "$logs_root/g1-go-version.log")"
  hash_g1_go_build="$(compute_hash "$logs_root/g1-go-build.log")"
  hash_g1_go_test="$(compute_hash "$logs_root/g1-go-test.log")"
  hash_g1_go_test_fresh="$(compute_hash "$logs_root/g1-go-test-fresh.log")"
  hash_g2_auth_sync="$(compute_hash "$logs_root/g2-auth-sync.log")"
  hash_g2_cli_sync="$(compute_hash "$logs_root/g2-cli-sync.log")"
  hash_g3_archive_pipeline="$(compute_hash "$logs_root/g3-archive-pipeline.log")"
  hash_g3_provenance="$(compute_hash "$logs_root/g3-provenance.log")"
  hash_g4_architecture="$(compute_hash "$logs_root/g4-architecture.log")"
  hash_g5_integration="$(compute_hash "$logs_root/g5-integration.log")"
  hash_g6_fresh_pass="$(compute_hash "$logs_root/g6-fresh-pass.log")"
  hash_red="$(compute_hash "$logs_root/red.log")"
  hash_green="$(compute_hash "$logs_root/green.log")"
  hash_blue="$(compute_hash "$logs_root/blue.log")"

  cat >"$tmp" <<EOF
---
id: benchmark-closeout-smoke
title: 'Benchmark closeout smoke'
owner_agent: coordinator
creator_agent: pm
parent_task_id: none
status: in_progress
priority: 10
depends_on: []
phase: closeout
requirement_ids: ['REQ-001', 'REQ-002', 'REQ-003', 'REQ-004', 'REQ-005', 'REQ-006', 'REQ-007', 'REQ-008', 'REQ-009']
evidence_commands:
  - go version
  - GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go build ./...
  - GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go test ./...
  - GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go test ./... -count=1
evidence_artifacts: ['$artifact_path']
benchmark_profile: benchmark_profiles/vault_sync_prompt_v1.json
benchmark_workdir: '$benchmark_workdir'
gate_targets: ['G1', 'G2', 'G3', 'G4', 'G5', 'G6']
scorecard_artifact: reports/coordinator/benchmark_scorecard.json
intended_write_targets: []
lock_scope: file
lock_policy: block_on_conflict
created_at: 2026-03-06T00:00:00+0000
updated_at: 2026-03-06T00:00:00+0000
acceptance_criteria:
  - Criterion 1
  - Criterion 2
---

## Prompt
Benchmark closeout.

## Context
Contract smoke.

## Deliverables
Scorecards.

## Validation
benchmark commands.

## Result
Requirement Statuses:
- REQ-001: Met
- REQ-002: Met
- REQ-003: Partial
- REQ-004: Partial
- REQ-005: Met
- REQ-006: Partial
- REQ-007: Met
- REQ-008: Partial
- REQ-009: Met

Acceptance Criteria:
- PASS: Scorecard generated

Gate Statuses:
- G1: pass
- G2: fail
- G3: pass
- G4: pass
- G5: pass
- G6: pass

- Red Command: go test ./integration -run TestAuthSync_Red -count=1
- Red Exit: 1
- Red Log: $logs_root/red.log
- Green Command: go test ./integration -run TestAuthSync_Green -count=1
- Green Exit: 0
- Green Log: $logs_root/green.log
- Blue Command: go test ./integration -run TestAuthSync_Blue -count=1
- Blue Exit: 0
- Blue Log: $logs_root/blue.log

- problem_fit_requirement_coverage: 24
- functional_correctness: 18
- architecture_ddd_quality: 13
- code_quality_maintainability: 8
- test_quality_coverage: 13
- tdd_process_evidence: 8
- cli_ux_config_observability_reliability: 4

Command: go version
Exit: 0
Log: $logs_root/g1-go-version.log
Log Hash: $hash_g1_go_version
Observed: go version pass

Command: GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go build ./...
Exit: 0
Log: $logs_root/g1-go-build.log
Log Hash: $hash_g1_go_build
Observed: build pass

Command: GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go test ./...
Exit: 0
Log: $logs_root/g1-go-test.log
Log Hash: $hash_g1_go_test
Observed: tests pass

Command: GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go test ./... -count=1
Exit: 0
Log: $logs_root/g1-go-test-fresh.log
Log Hash: $hash_g1_go_test_fresh
Observed: tests pass on fresh run

Command: go test ./integration -run TestAuthSync -count=1
Exit: 0
Log: $logs_root/g2-auth-sync.log
Log Hash: $hash_g2_auth_sync
Observed: auth sync integration pass

Command: vaultsync auth sync --check
Exit: 0
Log: $logs_root/g2-cli-sync.log
Log Hash: $hash_g2_cli_sync
Observed: cli auth sync smoke pass

Command: go test ./integration -run TestArchivePipeline -count=1
Exit: 0
Log: $logs_root/g3-archive-pipeline.log
Log Hash: $hash_g3_archive_pipeline
Observed: archive pipeline pass

Command: go test ./internal/archive -count=1
Exit: 0
Log: $logs_root/g3-provenance.log
Log Hash: $hash_g3_provenance
Observed: provenance assertions pass

Command: go test ./internal/architecture -count=1
Exit: 0
Log: $logs_root/g4-architecture.log
Log Hash: $hash_g4_architecture
Observed: architecture guardrails pass

Command: go test ./integration -count=1
Exit: 0
Log: $logs_root/g5-integration.log
Log Hash: $hash_g5_integration
Observed: integration pass

Command: go test ./pkg/smoke -count=1
Exit: 0
Log: $logs_root/g6-fresh-pass.log
Log Hash: $hash_g6_fresh_pass
Observed: fresh smoke pass

Command: go test ./integration -run TestAuthSync_Red -count=1
Exit: 1
Log: $logs_root/red.log
Log Hash: $hash_red
Observed: red test intentionally failing

Command: go test ./integration -run TestAuthSync_Green -count=1
Exit: 0
Log: $logs_root/green.log
Log Hash: $hash_green
Observed: green test passing after implementation

Command: go test ./integration -run TestAuthSync_Blue -count=1
Exit: 0
Log: $logs_root/blue.log
Log Hash: $hash_blue
Observed: blue refactor checks pass
EOF

  mv "$tmp" "$task_file"
}

task_id="benchmark-closeout-smoke"
run_taskctl create "$task_id" "Benchmark closeout smoke" --to coordinator --from pm --priority 10 --phase closeout >/dev/null
run_taskctl claim coordinator >/dev/null

task_file="$smoke_root/in_progress/coordinator/${task_id}.md"
if [[ ! -f "$task_file" ]]; then
  echo "expected in-progress benchmark task not found: $task_file" >&2
  exit 1
fi

run_taskctl benchmark-init coordinator "$task_id" >/dev/null
if ! grep -Fq "Log Hash: pending" "$task_file"; then
  echo "benchmark-init did not scaffold Log Hash placeholder rows" >&2
  exit 1
fi

workdir="$smoke_root/workdir"
mkdir -p "$workdir"
cat >"$workdir/go.mod" <<'EOF'
module smokebench

go 1.23
EOF
cat >"$workdir/main.go" <<'EOF'
package main

func main() {}
EOF
cat >"$workdir/main_test.go" <<'EOF'
package main

import "testing"

func TestSmoke(t *testing.T) {}
EOF

artifact_file="$smoke_root/runtime/benchmark-evidence.txt"
mkdir -p "$(dirname "$artifact_file")"
echo "evidence" >"$artifact_file"

logs_root="$smoke_root/runtime/logs"
write_log "$logs_root/g1-go-version.log" "go version go1.23.8 linux/arm64"
write_log "$logs_root/g1-go-build.log" "build pass"
write_log "$logs_root/g1-go-test.log" "tests pass"
write_log "$logs_root/g1-go-test-fresh.log" "tests pass fresh"
write_log "$logs_root/g2-auth-sync.log" "integration auth sync pass"
write_log "$logs_root/g2-cli-sync.log" "vaultsync auth sync pass"
write_log "$logs_root/g3-archive-pipeline.log" "archive pipeline pass"
write_log "$logs_root/g3-provenance.log" "provenance pass"
write_log "$logs_root/g4-architecture.log" "architecture pass"
write_log "$logs_root/g5-integration.log" "integration pass"
write_log "$logs_root/g6-fresh-pass.log" "fresh pass"
write_log "$logs_root/red.log" "red fail"
write_log "$logs_root/green.log" "green pass"
write_log "$logs_root/blue.log" "blue pass"

inject_result_block "$task_file" "$artifact_file" "$workdir" "$logs_root"

run_taskctl benchmark-verify coordinator "$task_id" >/dev/null
run_taskctl benchmark-rerun coordinator "$task_id" >/dev/null
run_taskctl benchmark-score coordinator "$task_id" >/dev/null

scorecard_json="$smoke_root/reports/coordinator/benchmark_scorecard.json"
scorecard_md="$smoke_root/reports/coordinator/benchmark_scorecard.md"
rerun_summary="$smoke_root/reports/coordinator/benchmark_reruns/${task_id}.json"
review_rerun_summary="$smoke_root/reports/review/benchmark_reruns/${task_id}.json"
[[ -f "$scorecard_json" ]] || { echo "missing scorecard json: $scorecard_json" >&2; exit 1; }
[[ -f "$scorecard_md" ]] || { echo "missing scorecard markdown: $scorecard_md" >&2; exit 1; }
[[ -f "$rerun_summary" ]] || { echo "missing rerun summary: $rerun_summary" >&2; exit 1; }

set +e
closeout_fail_output="$(run_taskctl benchmark-closeout-check coordinator "$task_id" 2>&1)"
closeout_fail_rc=$?
set -e

if [[ "$closeout_fail_rc" -eq 0 ]]; then
  echo "expected benchmark closeout check failure when gate status includes fail" >&2
  exit 1
fi

if ! printf '%s' "$closeout_fail_output" | grep -Fq "benchmark-closeout-check failed"; then
  echo "unexpected benchmark-closeout-check failure output" >&2
  echo "$closeout_fail_output" >&2
  exit 1
fi

sed -i "s/^- G2: fail$/- G2: pass/" "$task_file"

run_taskctl benchmark-verify coordinator "$task_id" >/dev/null
run_taskctl benchmark-rerun coordinator "$task_id" >/dev/null
run_taskctl benchmark-score coordinator "$task_id" >/dev/null
run_taskctl benchmark-closeout-check coordinator "$task_id" >/dev/null

[[ -f "$review_rerun_summary" ]] || { echo "missing review rerun summary: $review_rerun_summary" >&2; exit 1; }
if [[ "$(jq -r '.agent' "$review_rerun_summary")" != "review" ]]; then
  echo "expected closeout rerun summary owner to be review: $review_rerun_summary" >&2
  exit 1
fi
if [[ "$(jq -r '[.commands[]? | select((.log_hash // "") == "")] | length' "$review_rerun_summary")" != "0" ]]; then
  echo "expected rerun summary commands to include log_hash values: $review_rerun_summary" >&2
  exit 1
fi

parent_task_id="benchmark-parent-inherit-smoke"
run_taskctl create "$parent_task_id" "Benchmark parent inherit smoke" --to coordinator --from pm --priority 10 --phase closeout \
  --benchmark-profile benchmark_profiles/vault_sync_prompt_v1.json \
  --benchmark-workdir "$workdir" \
  --gate-target G1 --gate-target G2 --gate-target G3 --gate-target G4 --gate-target G5 --gate-target G6 \
  --scorecard-artifact reports/coordinator/benchmark-parent-inherit-smoke.json >/dev/null

child_task_id="benchmark-child-inherit-smoke"
run_taskctl create "$child_task_id" "Benchmark child inherit smoke" --to be --from coordinator --priority 20 --phase execute --parent "$parent_task_id" --write-target coordination/in_progress/be/"$child_task_id".md >/dev/null
child_task_file="$smoke_root/inbox/be/020/${child_task_id}.md"
[[ -f "$child_task_file" ]] || { echo "missing child task file: $child_task_file" >&2; exit 1; }

child_frontmatter="$(mktemp)"
awk '
  BEGIN { section = 0 }
  /^---$/ { section++; next }
  section == 1 { print }
  section >= 2 { exit }
' "$child_task_file" >"$child_frontmatter"

child_profile="$(yq -r '.benchmark_profile // ""' "$child_frontmatter")"
child_gates_len="$(yq -r '.gate_targets | length' "$child_frontmatter")"
if [[ -z "$child_profile" || "$child_profile" == "none" ]]; then
  echo "expected inherited benchmark_profile for child task, got: ${child_profile:-<empty>}" >&2
  rm -f "$child_frontmatter"
  exit 1
fi
if [[ "$child_gates_len" -eq 0 ]]; then
  echo "expected inherited/non-empty gate_targets for child task" >&2
  rm -f "$child_frontmatter"
  exit 1
fi
rm -f "$child_frontmatter"

set +e
no_inherit_fail_output="$(run_taskctl create benchmark-child-inherit-fail "Benchmark child inherit fail" --to be --from coordinator --priority 20 --phase execute --parent "$parent_task_id" --write-target coordination/in_progress/be/benchmark-child-inherit-fail.md --no-benchmark-inherit 2>&1)"
no_inherit_fail_rc=$?
set -e
if [[ "$no_inherit_fail_rc" -eq 0 ]]; then
  echo "expected create failure for strict benchmark-parent child without metadata/opt-out" >&2
  exit 1
fi
if ! printf '%s' "$no_inherit_fail_output" | grep -Fq "benchmark metadata required"; then
  echo "unexpected failure output for --no-benchmark-inherit strict child" >&2
  echo "$no_inherit_fail_output" >&2
  exit 1
fi

opt_out_task_id="benchmark-child-optout-smoke"
run_taskctl create "$opt_out_task_id" "Benchmark child opt-out smoke" --to be --from coordinator --priority 20 --phase execute --parent "$parent_task_id" --write-target coordination/in_progress/be/"$opt_out_task_id".md --no-benchmark-inherit --benchmark-opt-out-reason "non-benchmark operational task" >/dev/null
opt_out_task_file="$smoke_root/inbox/be/020/${opt_out_task_id}.md"
[[ -f "$opt_out_task_file" ]] || { echo "missing opt-out task file: $opt_out_task_file" >&2; exit 1; }
opt_out_frontmatter="$(mktemp)"
awk '
  BEGIN { section = 0 }
  /^---$/ { section++; next }
  section == 1 { print }
  section >= 2 { exit }
' "$opt_out_task_file" >"$opt_out_frontmatter"
if [[ "$(yq -r '.benchmark_profile // ""' "$opt_out_frontmatter")" != "none" ]]; then
  rm -f "$opt_out_frontmatter"
  echo "expected benchmark_profile=none for explicit opt-out child task" >&2
  exit 1
fi
if [[ "$(yq -r '.benchmark_opt_out_reason // ""' "$opt_out_frontmatter")" == "none" ]]; then
  rm -f "$opt_out_frontmatter"
  echo "expected benchmark_opt_out_reason to be set for explicit opt-out child task" >&2
  exit 1
fi
rm -f "$opt_out_frontmatter"

echo "benchmark contract checks passed: $TASKCTL"
