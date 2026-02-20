# Memories

## Patterns

### mem-1771596684-4680
> coordination/README.md now includes the canonical clarification+locking operator workflow and points to scripts/verify_orchestrator_clarification_suite.sh as the full validation entrypoint, with task lifecycle regression smoke retained as supplemental evidence.
<!-- tags: coordination, documentation, testing | created: 2026-02-20 -->

### mem-1771596518-27f8
> Step 7 verification now has a single suite entrypoint (scripts/verify_orchestrator_clarification_suite.sh) plus an end-to-end clarification workflow simulation (scripts/verify_clarification_workflow_contract.sh) that asserts explicit confirmation, open blocker report, and unresolved-assumption gates.
<!-- tags: coordination, orchestrator, testing | created: 2026-02-20 -->

### mem-1771596223-84f8
> Stale lock reaping now requires orchestrator identity (pm/coordinator by default via --actor or TASK_ACTOR_AGENT) and emits per-reap audit files under coordination/reports/<actor>/LOCK-REAP-*.md; enforced by scripts/verify_taskctl_lock_contract.sh.
<!-- tags: coordination, locking, testing | created: 2026-02-20 -->

### mem-1771595063-c9a0
> Taskctl lock lifecycle + coding-task write-target validation are enforced by scripts/verify_taskctl_lock_contract.sh (acquire/conflict/release/stale-clean + create validation smoke).
<!-- tags: coordination, locking, testing | created: 2026-02-20 -->

### mem-1771594472-e83c
> Task template lock metadata contract is enforced by scripts/verify_task_template_lock_metadata_contract.sh, including frontmatter YAML assertions and taskctl create smoke persistence checks.
<!-- tags: coordination, locking, testing | created: 2026-02-20 -->

### mem-1771594259-2d86
> Coordinator instructions contract is enforced by scripts/verify_coordinator_instructions_contract.sh, including iterative-loop/phase-gate clauses and a forbidden one-pass wording check.
<!-- tags: coordination, orchestrator, testing | created: 2026-02-20 -->

### mem-1771594067-f763
> Top-level orchestrator prompt contract is enforced by scripts/verify_top_level_prompt_contract.sh, which asserts one-question clarification, explicit phase gate, and completion gate clauses.
<!-- tags: coordination, orchestrator, testing | created: 2026-02-20 -->

## Decisions

## Fixes

### mem-1771596382-d84a
> failure: cmd=cat >> .ralph/agent/scratchpad.md <<EOF (unquoted heredoc), exit=127, error=backticks in markdown triggered command substitution and shell executed tokens like task.done/taskctl, next=use single-quoted heredoc delimiter when appending markdown with backticks
<!-- tags: tooling, error-handling, shell | created: 2026-02-20 -->

### mem-1771595851-dd6f
> failure: cmd=scripts/verify_agent_worker_lock_contract.sh, exit=1, error=dual-worker smoke using same agent let worker2 execute the same in_progress task and collapse lock heartbeat check, next=use different agents for conflict scenario so each worker claims its own task
<!-- tags: locking, testing, error-handling | created: 2026-02-20 -->

### mem-1771595851-dd6f
> failure: cmd=scripts/agent_worker.sh be --once (conflict path), exit=2, error=acquire_task_write_locks toggled set -e internally and returned 2 before caller captured status, next=avoid set +/-e side effects in helper functions; use if-command status capture to keep caller control
<!-- tags: locking, shell, error-handling | created: 2026-02-20 -->

### mem-1771594972-34c2
> failure: cmd=scripts/verify_taskctl_lock_contract.sh, exit=1, error=lock-status payload assertion expected spaced JSON snippet, next=assert payload fields with jq expressions instead of fixed string formatting
<!-- tags: locking, testing, error-handling | created: 2026-02-20 -->

### mem-1771594140-fa56
> failure: cmd=rg -n "verify_.*contract" scripts, exit=1, error=no matches caused rg non-zero exit, next=append '|| true' when searching optional patterns
<!-- tags: tooling, error-handling | created: 2026-02-20 -->

### mem-1771594031-443e
> failure: cmd=scripts/verify_top_level_prompt_contract.sh, exit=1, error=unescaped backticks in expected string triggered command substitution for clarify/plan, next=quote needle literals with single-quoted strings
<!-- tags: tooling, error-handling | created: 2026-02-20 -->

## Context
