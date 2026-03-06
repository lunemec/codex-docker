#!/usr/bin/env bash
set -euo pipefail

PROMPT_FILE="${1:-coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md}"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

require_line() {
  local needle="$1"
  local description="$2"

  if ! rg -q --fixed-strings -- "$needle" "$PROMPT_FILE"; then
    echo "missing contract clause: $description" >&2
    echo "expected line: $needle" >&2
    exit 1
  fi
}

require_line "Ask exactly one user-facing clarification question per response." "single-question rule"
require_line "Execution model (strict phases):" "phase model heading"
require_line '- `clarify -> research -> plan -> execute -> review -> closeout`' "phase sequence"
require_line 'Explicit phase-gate rule: do not transition from `clarify` to `research` or `plan` until explicit user confirmation is captured.' "explicit phase-gate rule"
require_line "Clarification completion gate (all required):" "clarification completion gate heading"
require_line "  - explicit user confirmation to end clarification" "completion gate: explicit confirmation"
require_line "  - zero open blocker tasks for the active parent task" "completion gate: no open blockers"
require_line "  - no unresolved critical assumptions in parent task notes" "completion gate: no unresolved critical assumptions"
require_line "Required artifact: finalized requirement matrix with each requirement mapped to:" "requirement matrix contract"
require_line "Do not accept scaffold-only milestones as requirement closure." "anti-scaffold closure rule"
require_line '- requirement matrix has no `missing`, `partial`, or `unverified` core rows' "review gate matrix rule"
require_line "Re-run critical verification commands independently of implementation-lane outputs." "independent command rerun requirement"
require_line "Benchmark hard gate: total score must be >= 80 and all G1..G6 gates must pass." "benchmark hard gate"
require_line 'For benchmark-scored runs, closeout requires `scripts/taskctl.sh benchmark-closeout-check <agent> <TASK_ID>` to pass.' "benchmark closeout check command"

echo "top-level prompt contract checks passed: $PROMPT_FILE"
