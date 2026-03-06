#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

run_check() {
  local label="$1"
  local script_path="$2"

  if [[ ! -x "$script_path" ]]; then
    echo "verification script not executable: $script_path" >&2
    exit 1
  fi

  echo "==> $label"
  "$script_path"
}

run_check "top-level prompt contract" "$SCRIPT_DIR/verify_top_level_prompt_contract.sh"
run_check "coordinator instructions contract" "$SCRIPT_DIR/verify_coordinator_instructions_contract.sh"
run_check "task template lock metadata contract" "$SCRIPT_DIR/verify_task_template_lock_metadata_contract.sh"
run_check "task done verification contract" "$SCRIPT_DIR/verify_task_done_contract.sh"
run_check "benchmark contract" "$SCRIPT_DIR/verify_benchmark_contract.sh"
run_check "taskctl lock contract" "$SCRIPT_DIR/verify_taskctl_lock_contract.sh"
run_check "agent worker lock contract" "$SCRIPT_DIR/verify_agent_worker_lock_contract.sh"
run_check "agent worker reasoning contract" "$SCRIPT_DIR/verify_agent_worker_reasoning_contract.sh"
run_check "clarification workflow contract" "$SCRIPT_DIR/verify_clarification_workflow_contract.sh"

echo "orchestrator clarification suite checks passed"
