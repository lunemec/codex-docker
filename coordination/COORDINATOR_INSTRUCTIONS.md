# PM / Coordinator Usage

Use this file as the operating contract for a single top-level orchestrator (`pm` or `coordinator`).

## Phase Contract (strict)
Operate in explicit phases with hard gates:
1. `clarify`
2. `research`
3. `plan`
4. `execute`
5. `review`
6. `closeout`

Do not skip a phase gate.

## Clarification Operating Contract
- Run clarification as an iterative loop; gather requirements in stages.
- Ask exactly one user-facing clarification question per response.
- Ask the highest-risk unresolved question first.
- After each user answer, update requirement notes before asking the next question.
- If the user answer is partial or ambiguous, remain in `clarify` and ask one next question.
- Do not transition from `clarify` to `research` or `plan` until explicit user confirmation is captured.
- Clarification completion gate (all required):
  - explicit user confirmation that requirements are complete
  - zero open blocker tasks for the active parent task
  - no unresolved critical assumptions in parent task notes

## Research Contract
- Delegate discovery-only tasks when uncertainty blocks implementation precision.
- Research outputs must capture source evidence and explicit implications.
- Exit gate:
  - unknowns resolved or explicitly deferred
  - evidence linked to requirement notes

## Plan Contract
- Build a decision-complete implementation plan before coding tasks.
- Maintain a requirement matrix mapping each requirement to:
  - implementation owner task(s)
  - validation command(s)
  - evidence artifact(s)
- For benchmark runs, use requirement statuses `Met | Partial | Missing | Unverifiable`.
- Exit gate: no unresolved high-impact design decisions.

## Execute Contract
- Delegate implementation through `scripts/taskctl.sh delegate`.
- Software/review tasks must declare:
  - `phase: execute|review`
  - `requirement_ids`
  - `evidence_commands`
  - `evidence_artifacts`
- Benchmark-scored tasks must also declare:
  - `benchmark_profile`
  - `benchmark_workdir`
  - `gate_targets`
  - `scorecard_artifact`
- For `execute|review|closeout` tasks under a benchmark-scored parent chain, benchmark metadata must be present unless `benchmark_opt_out_reason` is explicitly set.
- `taskctl create/delegate` inherit benchmark metadata from parent by default; use explicit opt-out only with justification.
- For benchmark runs, enforce full-team risk coverage:
  - `researcher` owns API/runtime constraints and best-variant deltas.
  - `architect` owns boundary invariants (provider/token/state isolation).
  - implementation lanes own failing-first regression tests for those invariants.
  - `review` owns independent adversarial reruns.
- Benchmark evidence must use structured `Command` + `Exit` + `Log` + `Observed` blocks with logs under `/workspace`.
- Benchmark evidence blocks must include `Log Hash` rows and hash-match the referenced log artifacts.
- For G6-targeted tasks, require explicit RGB credibility rows (`Red/Green/Blue Command|Exit|Log`).
- Reject stub-only integrations or no-op success claims for core requirements; treat these as unresolved requirement rows.
- Do not accept scaffold-only or placeholder outcomes.

## Review Contract
- Independent review must validate behavior against the requirement matrix.
- Grep/file inventory is allowed as supporting evidence only, never as sole acceptance proof.
- Re-run critical commands independently; do not rely only on implementer-transcribed command output.
- For benchmark tasks, run `scripts/taskctl.sh benchmark-rerun <agent> <TASK_ID>` and attach resulting rerun summary artifact.
- Independent rerun evidence for closeout must be review-owned and freshly generated after execute-phase updates.
- For benchmark tasks, require at least one negative/regression verification command per high-risk invariant in scope.
- Exit gate:
  - no unresolved P0/P1 findings
  - no core requirement row marked missing/partial/unverified

## Closeout Contract
- Close the loop only when acceptance criteria are verifiably met across the requirement matrix.
- For benchmark-scored chains, run `scripts/taskctl.sh benchmark-audit-chain <agent> <TASK_ID>` before final closeout.
- For benchmark runs, close only when `taskctl benchmark-closeout-check <agent> <TASK_ID>` passes.
- `benchmark-closeout-check` now requires independent rerun evidence to pass when profile closeout requires it.
- Benchmark hard gate: score >= 80 and all gates G1..G6 pass.
- Final output must summarize shipped behavior, executed validations, and residual risks.

## Delegation Rules
- Use `scripts/taskctl.sh delegate <from> <to> ...` for every handoff.
- Delegate to skills, not technologies (examples: `researcher`, `planner`, `architect`, `fe`, `be`, `db`, `review`).
- Keep tasks small and testable.
- Prefer explicit prompts over broad goals.
- Delegations to resolved coding-owner lanes still require explicit `--write-target`; coding-owner auto-target lanes resolve via CLI `--coding-owner-lanes` > `TASK_CODING_OWNER_LANES` > default `fe,be,db`.
- For resolved coding-owner lanes, `taskctl` auto-includes each task's in-progress task file as an additional enforced target.
- If a queued task is reassigned with `taskctl assign` to a resolved coding owner, stale coding-owner self task-file targets are pruned and the new owner-lane self target is preserved as the only coding-owner self target.
- `create`/`delegate` auto-bootstrap task-local sidecars at `coordination/task_prompts/<TASK_ID>/{prompt,context,deliverables,validation}/000.md`; fill these when providing strict runtime instructions.
- Worker runtime prompts are assembled only from task-local sections (`Prompt`, `Context`, `Deliverables`, `Validation`) and never merge `coordination/roles/*.md`.

## Blocker Handling
- When a child task is blocked, a priority-`000` blocker report is queued to the creator agent.
- Treat blocker reports as interrupt-level work.
- Resolve by clarifying requirements, re-ordering dependencies, or re-scoping.
- Create follow-up tasks and continue pipeline execution.

## One-Chat Operation
- User talks to `pm` only.
- `pm` gathers detail and delegates to the right skill folders.
- Specialists can further delegate to sub-specialists.
- Pipeline can have arbitrary depth as long as creator/owner chain is maintained.

## Baseline Repair Safety
- `scripts/coordination_repair.sh` performs a safe baseline refresh by invoking `codex-init-workspace --force`.
- Safe refresh scope: `/workspace/scripts/**` and `/workspace/coordination/{README.md,COORDINATOR_INSTRUCTIONS.md,prompts/**,roles/**,templates/**,benchmark_profiles/**,examples/**}`.
- Preserved scope: `/workspace/coordination/{inbox,in_progress,done,blocked,reports,runtime,task_prompts}/**`.
- This ensures active queues, history, runtime state, and task-local prompt sidecars are never clobbered during repair.
