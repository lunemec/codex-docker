#!/usr/bin/env bash
set -euo pipefail

INSTRUCTIONS_FILE="${1:-coordination/COORDINATOR_INSTRUCTIONS.md}"

if [[ ! -f "$INSTRUCTIONS_FILE" ]]; then
  echo "coordinator instructions file not found: $INSTRUCTIONS_FILE" >&2
  exit 1
fi

require_line() {
  local needle="$1"
  local description="$2"

  if ! rg -q --fixed-strings -- "$needle" "$INSTRUCTIONS_FILE"; then
    echo "missing coordinator contract clause: $description" >&2
    echo "expected line: $needle" >&2
    exit 1
  fi
}

require_line "Operate in explicit phases with hard gates:" "phase heading"
require_line '1. `clarify`' "phase clarify"
require_line '2. `research`' "phase research"
require_line '3. `plan`' "phase plan"
require_line '4. `execute`' "phase execute"
require_line '5. `review`' "phase review"
require_line '6. `closeout`' "phase closeout"
require_line "Run clarification as an iterative loop; gather requirements in stages." "iterative clarification loop"
require_line "Ask exactly one user-facing clarification question per response." "single-question rule"
require_line 'Do not transition from `clarify` to `research` or `plan` until explicit user confirmation is captured.' "explicit phase-gate rule"
require_line "Clarification completion gate (all required):" "clarification completion gate heading"
require_line "  - explicit user confirmation that requirements are complete" "completion gate: explicit confirmation"
require_line "  - zero open blocker tasks for the active parent task" "completion gate: no open blockers"
require_line "  - no unresolved critical assumptions in parent task notes" "completion gate: no unresolved critical assumptions"
require_line "Maintain a requirement matrix mapping each requirement to:" "requirement matrix heading"
require_line "  - implementation owner task(s)" "matrix owner mapping"
require_line "  - validation command(s)" "matrix command mapping"
require_line "  - evidence artifact(s)" "matrix artifact mapping"
require_line '- For benchmark runs, use requirement statuses `Met | Partial | Missing | Unverifiable`.' "benchmark requirement status set"
require_line "- Benchmark-scored tasks must also declare:" "benchmark metadata heading"
require_line '  - `benchmark_profile`' "benchmark_profile metadata"
require_line '  - `benchmark_workdir`' "benchmark_workdir metadata"
require_line '  - `gate_targets`' "gate_targets metadata"
require_line '  - `scorecard_artifact`' "scorecard_artifact metadata"
require_line "- For \`execute|review|closeout\` tasks under a benchmark-scored parent chain, benchmark metadata must be present unless \`benchmark_opt_out_reason\` is explicitly set." "benchmark parent strict metadata requirement"
require_line "- \`taskctl create/delegate\` inherit benchmark metadata from parent by default; use explicit opt-out only with justification." "benchmark inheritance default"
require_line '- Benchmark evidence must use structured `Command` + `Exit` + `Log` + `Observed` blocks with logs under `/workspace`.' "structured benchmark evidence requirement"
require_line '- Benchmark evidence blocks must include `Log Hash` rows and hash-match the referenced log artifacts.' "benchmark log hash integrity requirement"
require_line "- Reject stub-only integrations or no-op success claims for core requirements; treat these as unresolved requirement rows." "anti-stub/no-op requirement"
require_line "Grep/file inventory is allowed as supporting evidence only, never as sole acceptance proof." "review evidence strictness"
require_line "- Re-run critical commands independently; do not rely only on implementer-transcribed command output." "independent rerun requirement"
require_line '- For benchmark tasks, run `scripts/taskctl.sh benchmark-rerun <agent> <TASK_ID>` and attach resulting rerun summary artifact.' "benchmark-rerun review requirement"
require_line "- Independent rerun evidence for closeout must be review-owned and freshly generated after execute-phase updates." "benchmark rerun ownership/freshness requirement"
require_line "- For benchmark tasks, require at least one negative/regression verification command per high-risk invariant in scope." "benchmark negative-path verification requirement"
require_line '- For benchmark-scored chains, run `scripts/taskctl.sh benchmark-audit-chain <agent> <TASK_ID>` before final closeout.' "benchmark audit chain requirement"
require_line '- For benchmark runs, close only when `taskctl benchmark-closeout-check <agent> <TASK_ID>` passes.' "benchmark closeout check contract"
require_line '- `benchmark-closeout-check` now requires independent rerun evidence to pass when profile closeout requires it.' "closeout rerun gate requirement"
require_line "- Benchmark hard gate: score >= 80 and all gates G1..G6 pass." "benchmark score+gates hard gate"

if rg -qi "one[ -]pass" "$INSTRUCTIONS_FILE"; then
  echo "contradictory one-pass wording detected in $INSTRUCTIONS_FILE" >&2
  exit 1
fi

echo "coordinator instructions contract checks passed: $INSTRUCTIONS_FILE"
