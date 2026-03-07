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
require_line '  - `benchmark_workdir`' "benchmark_workdir metadata"
require_line 'Benchmark evidence must be structured `Command` + `Exit` + `Log` + `Observed`, with logs under `/workspace`.' "structured benchmark evidence rule"
require_line '- Benchmark evidence blocks must include `Log Hash` rows that match the referenced log artifacts.' "benchmark log hash integrity rule"
require_line "Benchmark metadata inherits from parent tasks by default when using \`taskctl create/delegate\`." "benchmark metadata inheritance rule"
require_line "For benchmark-parent tasks in \`execute|review|closeout\`, do not leave benchmark metadata empty; if you intentionally opt out, set \`benchmark_opt_out_reason\` explicitly." "benchmark parent strict metadata rule"
require_line "Reject stub-only integrations and no-op success claims for core requirements." "anti-stub/no-op rule"
require_line '- For benchmark tasks, run `scripts/taskctl.sh benchmark-rerun <agent> <TASK_ID>` and attach rerun summary evidence.' "benchmark-rerun review rule"
require_line "- Closeout rerun evidence must be review-owned and generated after the latest execute-phase update." "benchmark rerun ownership/freshness rule"
require_line "- For benchmark tasks, include at least one negative/regression command for each high-risk invariant (not only happy-path checks)." "benchmark negative-path review rule"
require_line "Benchmark hard gate: total score must be >= 80 and all G1..G6 gates must pass." "benchmark hard gate"
require_line 'For benchmark-scored runs, closeout requires `scripts/taskctl.sh benchmark-closeout-check <agent> <TASK_ID>` to pass.' "benchmark closeout check command"
require_line "Benchmark closeout requires independent rerun evidence to pass when profile closeout requires it." "closeout rerun requirement"
require_line "- For benchmark-scored chains, run \`scripts/taskctl.sh benchmark-audit-chain <agent> <TASK_ID>\` before final closeout." "benchmark audit chain requirement"

echo "top-level prompt contract checks passed: $PROMPT_FILE"
