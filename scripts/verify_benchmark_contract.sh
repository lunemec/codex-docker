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

for cmd in jq yq; do
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

inject_result_block() {
  local task_file="$1"
  local artifact_path="$2"
  local tmp
  tmp="$(mktemp)"

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
- REQ-006: Missing
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

- problem_fit_requirement_coverage: 24
- functional_correctness: 18
- architecture_ddd_quality: 13
- code_quality_maintainability: 8
- test_quality_coverage: 13
- tdd_process_evidence: 2
- cli_ux_config_observability_reliability: 4

Command: go version
Exit: 0
Log: /tmp/bench-go-version.log
Observed: go version go1.23.8 linux/arm64

Command: GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go build ./...
Exit: 0
Log: /tmp/bench-go-build.log
Observed: build pass

Command: GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go test ./...
Exit: 0
Log: /tmp/bench-go-test.log
Observed: tests pass

Command: GOCACHE=/tmp/go-build-cache GOMODCACHE=/tmp/go-mod-cache go test ./... -count=1
Exit: 1
Log: /tmp/bench-go-test-fresh.log
Observed: fresh run failure
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

artifact_file="$smoke_root/runtime/benchmark-evidence.txt"
mkdir -p "$(dirname "$artifact_file")"
echo "evidence" >"$artifact_file"

inject_result_block "$task_file" "$artifact_file"

run_taskctl benchmark-verify coordinator "$task_id" >/dev/null
run_taskctl benchmark-score coordinator "$task_id" >/dev/null

scorecard_json="$smoke_root/reports/coordinator/benchmark_scorecard.json"
scorecard_md="$smoke_root/reports/coordinator/benchmark_scorecard.md"
[[ -f "$scorecard_json" ]] || { echo "missing scorecard json: $scorecard_json" >&2; exit 1; }
[[ -f "$scorecard_md" ]] || { echo "missing scorecard markdown: $scorecard_md" >&2; exit 1; }

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
run_taskctl benchmark-score coordinator "$task_id" >/dev/null
run_taskctl benchmark-closeout-check coordinator "$task_id" >/dev/null

echo "benchmark contract checks passed: $TASKCTL"
