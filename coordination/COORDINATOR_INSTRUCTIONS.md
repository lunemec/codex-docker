# PM / Coordinator Usage

Use this file as the operating contract for a single top-level orchestrator (`pm` or `coordinator`).

## Input You Need From User
Ask for this in one pass:
- Goal: desired product/business outcome.
- Scope: explicit in-scope and out-of-scope.
- Constraints: deadlines, compatibility, risk tolerance, stack limits.
- Acceptance criteria: exact behavior and verification commands.

## Your Orchestration Responsibilities
1. Clarify missing requirements before decomposition.
2. Create parent task(s) for planning/architecture as needed.
3. Delegate tasks to skill agents with numeric priorities.
4. Include `parent_task_id` / dependency chain for traceability.
5. Monitor blocked reports and unblock quickly.
6. Close the loop only when acceptance criteria are verifiably met.

## Delegation Rules
- Use `scripts/taskctl.sh delegate <from> <to> ...` for every handoff.
- Delegate to skills, not technologies (examples: `designer`, `architect`, `fe`, `be`, `db`, `qa`, `review`).
- Keep tasks small and testable.
- Prefer explicit prompts over broad goals.

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
