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

  if ! rg -q --fixed-strings "$needle" "$PROMPT_FILE"; then
    echo "missing contract clause: $description" >&2
    echo "expected line: $needle" >&2
    exit 1
  fi
}

require_line "Ask exactly one user-facing clarification question per response." "single-question rule"
require_line 'Explicit phase-gate rule: do not transition from `clarify` to `plan` or planning finalization until explicit user confirmation is captured.' "explicit phase-gate rule"
require_line "Clarification completion gate (all required):" "clarification completion gate heading"
require_line "  - explicit user confirmation to end clarification" "completion gate: explicit confirmation"
require_line "  - zero open blocker tasks for the active parent task" "completion gate: no open blockers"

echo "top-level prompt contract checks passed: $PROMPT_FILE"
