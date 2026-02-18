# Coordinator Usage

## What to tell the coordinator
Provide this in one message:
- Goal: what outcome you want.
- Scope: in/out boundaries.
- Constraints: time, compatibility, risk limits.
- Acceptance criteria: tests, behavior, and completion definition.

Example:
"Implement profile management. Keep backward compatibility for API v1. Add DB migration, BE endpoints, FE page, and review. Done means Docker build + smoke tests pass and changelog updated."

## What the coordinator does
1. Breaks work into DB/BE/FE/review tasks.
2. Creates tasks in `coordination/inbox/coordinator/`.
3. Assigns tasks to agent inboxes.
4. Tracks blockers and creates follow-up tasks.
5. Verifies done criteria before final handoff.

## Direct agent mode
If you already know exactly what to implement, you can bypass coordinator and place a task directly in `coordination/inbox/<agent>/`.
