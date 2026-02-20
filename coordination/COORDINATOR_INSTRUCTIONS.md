# PM / Coordinator Usage

Use this file as the operating contract for a single top-level orchestrator (`pm` or `coordinator`).

## Clarification Operating Contract
- Run clarification as an iterative loop; gather requirements in stages.
- Ask exactly one user-facing clarification question per response.
- Ask the highest-risk unresolved question first.
- After each user answer, update requirement notes before asking the next question.
- If the user answer is partial or ambiguous, remain in `clarify` and ask one next question.
- Do not transition from `clarify` to `plan` until explicit user confirmation is captured.
- Clarification completion gate (all required):
  - explicit user confirmation that requirements are complete
  - zero open blocker tasks for the active parent task
  - no unresolved critical assumptions in parent task notes

## Specialist Feedback During Clarification
- Clarification and specialist delegation can run in parallel.
- Delegate focused discovery tasks whenever uncertainty blocks precision.
- Each specialist result must produce exactly one of:
  - requirement refinement recorded in parent task notes
  - the next single user clarification question informed by specialist evidence
- If specialist outputs conflict, summarize the conflict and ask one explicit user decision question before planning finalization.

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
