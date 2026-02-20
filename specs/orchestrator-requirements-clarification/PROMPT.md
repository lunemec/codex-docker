# Objective
Implement the approved orchestration upgrade so the top-level agent clarifies requirements with ralph-plan-like rigor and continuously generates specialist tasks, while preventing cross-agent file-write race conditions using Option C locking.

# Scope Reference
Use this spec package as the source of truth:
- `specs/orchestrator-requirements-clarification/requirements.md`
- `specs/orchestrator-requirements-clarification/research/`
- `specs/orchestrator-requirements-clarification/design.md`
- `specs/orchestrator-requirements-clarification/plan.md`

# Key Requirements
1. Enforce strict one-question-at-a-time clarification behavior in top-level orchestrator prompts.
2. Require explicit user confirmation before phase transitions.
3. Keep specialist delegation continuous during clarification.
4. Feed specialist outputs back into new user clarification questions and requirement refinements.
5. End clarification only when user explicitly confirms completion and no open blocker tasks remain.
6. Implement Option C locking v1:
- task-level `intended_write_targets` declarations,
- mandatory per-file lock acquisition at write time,
- conflict -> block task + blocker report,
- stale-lock reaping with audit trail.
7. Preserve existing task lifecycle and coordination flow semantics unless explicitly changed by the approved design.

# Acceptance Criteria (Given-When-Then)
1. Clarification loop
- Given an ambiguous user request
- When orchestration begins
- Then the top-level agent asks exactly one clarification question per turn.

2. Phase gate
- Given clarification is active
- When user has not explicitly confirmed completion
- Then orchestrator does not transition to final planning/design closure.

3. Continuous delegation
- Given unresolved technical uncertainty during clarification
- When the orchestrator identifies investigation need
- Then it creates/delegates specialist tasks without waiting for clarification to fully end.

4. Specialist feedback integration
- Given specialist results introduce constraints/options
- When orchestrator processes results
- Then it updates requirement artifacts or asks one targeted follow-up question to the user.

5. Clarification completion condition
- Given the user says requirements are complete
- When blocker tasks remain open
- Then clarification does not finalize.

6. Lock conflict prevention
- Given two tasks target the same file
- When the second task attempts write-time lock acquisition
- Then acquisition fails and task is moved to blocked with lock conflict reason.

7. Lock cleanup and stale handling
- Given a task completes or fails
- When lock lifecycle ends
- Then held locks are released; stale locks are reaped by policy with audit evidence.

# Delivery Expectations
1. Implement incrementally following `specs/orchestrator-requirements-clarification/plan.md` step order.
2. Add/adjust tests to verify prompt contracts, locking behavior, and workflow semantics.
3. Update docs/changelog to reflect behavior and operational changes.
4. Provide validation evidence (commands and outcomes) for key acceptance criteria.
