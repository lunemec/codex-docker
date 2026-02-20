# Research 03: Locking Model v1 (Option C)

## Objective
Operationalize Option C for preventing race conditions when multiple specialists might modify the same files.

## Selected Model
Hybrid (Option C):
1. Per-task ownership declaration (planned write targets) in task metadata.
2. Mandatory per-file lock acquisition immediately before write operations.
3. Lock failure routes to blocker flow instead of best-effort retries.

## Lock Lifecycle
```mermaid
stateDiagram-v2
  [*] --> Planned: Task created with intended_write_targets
  Planned --> Claimed: Agent claims task
  Claimed --> Locking: Before first write
  Locking --> Writing: lock acquired
  Locking --> Blocked: lock unavailable/expired conflict
  Writing --> Writing: acquire/release per additional file
  Writing --> Complete: task done
  Writing --> Failed: execution error
  Complete --> Released: release all held locks
  Failed --> Released: release all held locks
  Released --> [*]
  Blocked --> [*]
```

## Data Contract Proposal (v1)
Task frontmatter additions:
- `intended_write_targets`: YAML list of workspace-relative file paths or globs.
- `lock_scope`: `file` (default for v1).
- `lock_policy`: `block_on_conflict` (default).

Lock storage:
- Directory: `coordination/locks/files/`
- One lock file per canonical target path hash.
- Lock payload fields:
  - task_id
  - owner_agent
  - canonical_target
  - acquired_at
  - heartbeat_at

## Integration Points
1. `coordination/templates/TASK_TEMPLATE.md`
- add fields for intended targets and lock defaults.

2. `scripts/taskctl.sh`
- validate `intended_write_targets` exists for code-writing specialist tasks.
- optionally provide helper command(s):
  - `lock-status <path>`
  - `lock-clean-stale`

3. `scripts/agent_worker.sh`
- add pre-write hook policy in worker prompt:
  - acquire lock before modifying each target,
  - release on completion/failure,
  - block task when lock cannot be acquired.
- support heartbeat update for long-running tasks.

## Conflict Handling
```mermaid
flowchart TD
  A[Agent wants to write file X] --> B{Lock for X exists?}
  B -- No --> C[Create lock with task_id/agent/timestamp]
  C --> D[Write file X]
  D --> E[Release lock]
  B -- Yes --> F{Same task_id and owner?}
  F -- Yes --> D
  F -- No --> G[Fail lock acquire]
  G --> H[taskctl block with reason: lock conflict]
  H --> I[Auto blocker report to creator]
```

## Stale Lock Policy (v1)
1. Locks include `heartbeat_at`.
2. Worker updates heartbeat periodically while task is active.
3. A lock is stale if heartbeat exceeds configurable TTL.
4. Only orchestrator/coordinator lane may reap stale locks.
5. Reap action must be logged to `coordination/reports/` for auditability.

## Tradeoff Summary
1. Stronger than declaration-only ownership because it blocks real collisions at write time.
2. Lower operational overhead than lock-everything from task start.
3. Requires explicit task metadata discipline and worker/runtime hook updates.

## Sources
- `specs/orchestrator-requirements-clarification/requirements.md:17`
- `specs/orchestrator-requirements-clarification/requirements.md:25`
- `coordination/templates/TASK_TEMPLATE.md:1`
- `scripts/taskctl.sh:659`
- `scripts/taskctl.sh:801`
- `scripts/agent_worker.sh:217`
- `coordination/README.md:25`
