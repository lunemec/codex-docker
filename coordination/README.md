# Local Agent Coordination

This folder provides a repo-local task board using Markdown files and one folder per agent to reduce write conflicts.

## Agents
- `coordinator`
- `db`
- `be`
- `fe`
- `review`

## State Folders
- `coordination/inbox/<agent>/`: queued work for an agent
- `coordination/in_progress/<agent>/`: currently active task(s)
- `coordination/done/<agent>/`: completed tasks
- `coordination/blocked/<agent>/`: blocked tasks

## Write Rules (important)
- Coordinator is the only actor that assigns tasks from coordinator inbox to a target agent inbox.
- Each specialist agent edits only files in its own `in_progress/<agent>/`.
- An agent moves its own tasks to `done/<agent>/` or `blocked/<agent>/`.
- Review agent should not edit implementation code; only review notes/tasks.

## Typical Flow
1. You or coordinator creates a task from `coordination/templates/TASK_TEMPLATE.md`.
2. Coordinator assigns task to agent (`db`, `be`, `fe`, or `review`).
3. Agent claims from inbox to in-progress.
4. Agent implements and records result.
5. Agent marks done (or blocked with reason).
6. Coordinator creates follow-up tasks if needed.

## Quick Commands
Use `scripts/taskctl.sh`:

```bash
# create a coordinator inbox task
scripts/taskctl.sh create TASK-0100 "Add health endpoint"

# coordinator assigns to an agent
scripts/taskctl.sh assign TASK-0100 be

# agent claims next task
scripts/taskctl.sh claim be

# mark status transitions
scripts/taskctl.sh done be TASK-0100
scripts/taskctl.sh block be TASK-0100 "Waiting on DB schema"
```

## How to operate in practice
- Tell the coordinator what you want at product level (goal + constraints).
- Coordinator decomposes into DB/BE/FE/review tasks.
- If you already know exact implementation details, you can bypass coordinator and give direct tasks to a specific agent folder.
