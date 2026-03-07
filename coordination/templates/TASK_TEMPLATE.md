---
id: TASK-0000
title: Replace with task title
owner_agent: pm
creator_agent: pm
parent_task_id: none
status: inbox
priority: 50
depends_on: []
phase: plan
requirement_ids: []
evidence_commands: []
evidence_artifacts: []
benchmark_profile: none
benchmark_workdir: .
gate_targets: []
scorecard_artifact: none
benchmark_opt_out_reason: none
intended_write_targets: []
lock_scope: file
lock_policy: block_on_conflict
created_at: 2026-02-19T00:00:00+0000
updated_at: 2026-02-19T00:00:00+0000
acceptance_criteria:
  - Criterion 1
  - Criterion 2
---

## Prompt
Write the exact instructions for the target skill agent.

## Context
Business or technical background and constraints.
Task-local sidecar overrides embedded execution sections when present: `coordination/task_prompts/<TASK_ID>/{prompt,context,deliverables,validation}/*.md`.

## Deliverables
List concrete files/outputs expected.

## Validation
List exact commands/tests that must pass.

## Result
Agent fills this before moving the task to `done` or `blocked`.
For `phase: execute|review|closeout`, include:
- `Requirement Statuses:` entries in form `- <requirement_id>: Met|Partial|Missing|Unverifiable`.
- `Acceptance Criteria:` with pass/fail status per criterion.
- One or more structured evidence blocks with `Command:` + `Exit:` + `Log:` + `Log Hash:` + `Observed:`.
  - For benchmark tasks, each command in `evidence_commands` must have an exact structured block.
  - Log paths must resolve under `/workspace` and point to existing files.
  - `Log Hash:` must match the referenced log artifact hash.
- For benchmark tasks, include `Gate Statuses:` entries in form `- G1: pass|fail`.
- For strict-phase tasks (`execute|review|closeout`) whose parent chain is benchmark-scored:
  - include benchmark metadata (`benchmark_profile`, `benchmark_workdir`, `gate_targets`, `scorecard_artifact`), or
  - set `benchmark_opt_out_reason` with explicit justification.
- For benchmark tasks targeting `G6`, include RGB credibility rows:
  - `- Red Command: <command>`
  - `- Red Exit: <non-zero>`
  - `- Red Log: <path>`
  - `- Green Command: <command>`
  - `- Green Exit: 0`
  - `- Green Log: <path>`
  - `- Blue Command: <command>`
  - `- Blue Exit: 0`
  - `- Blue Log: <path>`
- For benchmark score tasks, include category lines:
  - `- problem_fit_requirement_coverage: <score>`
  - `- functional_correctness: <score>`
  - `- architecture_ddd_quality: <score>`
  - `- code_quality_maintainability: <score>`
  - `- test_quality_coverage: <score>`
  - `- tdd_process_evidence: <score>`
  - `- cli_ux_config_observability_reliability: <score>`
