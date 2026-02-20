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

  if ! rg -q --fixed-strings "$needle" "$INSTRUCTIONS_FILE"; then
    echo "missing coordinator contract clause: $description" >&2
    echo "expected line: $needle" >&2
    exit 1
  fi
}

require_line "Run clarification as an iterative loop; gather requirements in stages." "iterative clarification loop"
require_line "Ask exactly one user-facing clarification question per response." "single-question rule"
require_line 'Do not transition from `clarify` to `plan` until explicit user confirmation is captured.' "explicit phase-gate rule"
require_line "Each specialist result must produce exactly one of:" "specialist-feedback loop heading"
require_line "  - the next single user clarification question informed by specialist evidence" "specialist feedback to user question"

if rg -qi "one[ -]pass" "$INSTRUCTIONS_FILE"; then
  echo "contradictory one-pass wording detected in $INSTRUCTIONS_FILE" >&2
  exit 1
fi

echo "coordinator instructions contract checks passed: $INSTRUCTIONS_FILE"
