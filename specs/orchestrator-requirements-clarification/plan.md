# Implementation Plan: Orchestrator Clarification Parity + Locking v1

## Checklist
- [ ] Step 1: Add strict clarification protocol to top-level prompt
- [ ] Step 2: Align coordinator operating instructions with iterative clarification
- [ ] Step 3: Extend task schema for write-target ownership and lock policy
- [ ] Step 4: Add lock lifecycle helpers and validation in taskctl
- [ ] Step 5: Add write-time lock enforcement in worker execution flow
- [ ] Step 6: Add stale-lock reaping and audit reporting
- [ ] Step 7: Add contract and workflow tests for clarification and locking
- [ ] Step 8: Update docs and run full coordination workflow validation

## Step 1: Add strict clarification protocol to top-level prompt
Objective:
Establish deterministic one-question-at-a-time requirement elicitation with explicit phase gates.

Implementation guidance:
- Update `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` to add a dedicated clarification protocol subsection.
- Require exactly one user-facing clarification question per turn.
- Require explicit user confirmation before phase transitions.
- Add completion gate: no open blockers + explicit user confirmation.

Test requirements:
- Prompt contract assertions verify presence of:
  - single-question rule,
  - explicit phase-gate rule,
  - clarification completion gate.

Integration notes:
- Keep existing orchestration loop structure unchanged.
- Ensure response contract remains compatible with current top-level interactions.

Demo description:
Run a simulated ambiguous request and show orchestrator emits exactly one clarification question while staying in clarification phase.

## Step 2: Align coordinator operating instructions with iterative clarification
Objective:
Remove one-pass intake bias and align coordinator guidance with iterative requirement discovery.

Implementation guidance:
- Update `coordination/COORDINATOR_INSTRUCTIONS.md`:
  - replace one-pass intake wording,
  - define iterative Q&A loop,
  - define specialist-feedback-to-user-question behavior.

Test requirements:
- Contract checks ensure no contradictory one-pass wording remains.
- Verify instructions include explicit iterative loop and phase gate terms.

Integration notes:
- Maintain existing delegation and blocker handling semantics.

Demo description:
Show coordinator instructions now direct staged elicitation and specialist-informed follow-up questioning.

## Step 3: Extend task schema for write-target ownership and lock policy
Objective:
Introduce task metadata required by Option C locking.

Implementation guidance:
- Update `coordination/templates/TASK_TEMPLATE.md` frontmatter with:
  - `intended_write_targets: []`
  - `lock_scope: file`
  - `lock_policy: block_on_conflict`
- Preserve backward compatibility for non-writing tasks.

Test requirements:
- Template parse test confirms new fields exist and are valid YAML.
- Task creation smoke test confirms fields persist in generated tasks.

Integration notes:
- Keep existing task lifecycle fields unchanged.

Demo description:
Create a sample delegated task and show metadata fields are present in created task file.

## Step 4: Add lock lifecycle helpers and validation in taskctl
Objective:
Provide lock primitives and task-level validation to prevent untracked write conflicts.

Implementation guidance:
- Add lock helper functions to `scripts/taskctl.sh`:
  - canonicalize target path,
  - resolve lock path by hash,
  - create/read/remove lock payload.
- Add commands:
  - `lock-status <target>`
  - `lock-clean-stale [--ttl <seconds>]`
- Add validation for coding tasks requiring non-empty `intended_write_targets`.

Test requirements:
- Unit-like shell tests for:
  - lock acquire success,
  - lock conflict detection,
  - lock release,
  - stale lock cleanup.
- CLI behavior tests for new commands.

Integration notes:
- Preserve existing command signatures for create/delegate/claim/done/block.
- Ensure Docker `/workspace` safety checks still apply.

Demo description:
Create two synthetic lock attempts on same target and show second attempt returns conflict.

## Step 5: Add write-time lock enforcement in worker execution flow
Objective:
Ensure specialists cannot modify shared files concurrently.

Implementation guidance:
- Update `scripts/agent_worker.sh` to enforce write-time locking policy:
  - before write operation, acquire file lock,
  - on conflict, block task with explicit reason,
  - on completion/failure, release all locks held by task.
- Add heartbeat updates for held locks during long-running execution.

Test requirements:
- Simulated dual-worker scenario confirms conflict routes one task to blocked.
- Validate lock release on both success and failure paths.

Integration notes:
- Keep `taskctl done/block` transitions as the single source of lifecycle truth.

Demo description:
Run two tasks targeting the same file in parallel and show one completes while the other enters blocked with lock conflict reason.

## Step 6: Add stale-lock reaping and audit reporting
Objective:
Prevent deadlocks from orphaned lock files.

Implementation guidance:
- Implement stale detection by heartbeat TTL.
- Restrict reap operations to orchestrator lanes.
- Write audit trail entries to `coordination/reports/` for each reap action.

Test requirements:
- Seed stale lock fixture and verify cleanup command removes it.
- Verify non-stale locks are preserved.
- Verify audit record is created.

Integration notes:
- Ensure stale cleanup does not alter task state directly; only lock state.

Demo description:
Inject old heartbeat lock and run cleanup command to show deterministic reap + audit output.

## Step 7: Add contract and workflow tests for clarification and locking
Objective:
Provide regression protection for both orchestration behavior and concurrency guardrails.

Implementation guidance:
- Add tests covering:
  - prompt contract content,
  - coordinator instruction contract content,
  - task schema metadata presence,
  - lock conflict and stale reap flows,
  - clarification completion gate logic.

Test requirements:
- Test suite runs in container and produces clear pass/fail results.
- Include at least one end-to-end orchestration simulation.

Integration notes:
- Keep tests lightweight and deterministic; avoid requiring external services.

Demo description:
Run test suite and show all contract + lock behavior tests passing.

## Step 8: Update docs and run full coordination workflow validation
Objective:
Ship the behavior change with clear operator guidance and end-to-end proof.

Implementation guidance:
- Update `coordination/README.md` with:
  - clarification loop expectations,
  - lock metadata usage,
  - lock diagnostic/reap commands.
- Update `CHANGELOG.md` with behavior and validation changes.
- Execute full workflow smoke:
  - clarification with specialist feedback,
  - lock conflict handling,
  - blocker routing,
  - completion gating.

Test requirements:
- Capture exact commands and outcomes for smoke validation.
- Verify no regression in existing task claim/transition flows.

Integration notes:
- Keep backward-compatible usage where possible; document any breaking operational assumptions.

Demo description:
Show a complete run from ambiguous request to clarified requirements and delegated tasks with lock-safe execution evidence.
