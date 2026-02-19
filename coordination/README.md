# Local Agent Coordination

This board implements a skill-based multi-agent pipeline.

You can talk to one orchestrator agent (typically `pm`), and it can delegate to any number of skill agents (`designer`, `architect`, `fe`, `be`, etc.) by creating tasks for their queues.

## Core Model
- Any agent name is allowed (dynamic skill agents).
- Each task records both:
  - `owner_agent`: who executes it now.
  - `creator_agent`: who delegated it and should receive blocker feedback.
- Every agent can delegate downstream tasks, enabling multi-layer pipelines.

## Queue Layout
- `coordination/inbox/<agent>/<NNN>/`: queued tasks by numeric priority.
- `coordination/in_progress/<agent>/`: currently claimed task(s).
- `coordination/done/<agent>/<NNN>/`: completed tasks.
- `coordination/blocked/<agent>/<NNN>/`: blocked tasks removed from execution queue.
- `coordination/roles/<agent>.md`: skill/job description prompt for each agent.

Priority behavior:
- Lower numbers are higher priority (`000` highest).
- Claiming always takes the lexicographically first task path, which means highest priority first.

## Blocker Reporting
When an agent blocks a task:
1. Task is moved from `in_progress` to `blocked`.
2. A blocker report task is automatically created for `creator_agent` at priority `000`.
3. Creator/orchestrator can resolve ambiguity and issue follow-up tasks.

This gives every sub-agent a stop-and-escalate path.

## Commands
Use `scripts/taskctl.sh`:

Safety guard:
- Orchestration scripts must run inside Docker and from `/workspace`.
- `TASK_ROOT_DIR`, `AGENT_ROOT_DIR`, `AGENT_TASKCTL`, and `AGENT_WORKER_SCRIPT` are restricted to paths under `/workspace`.

Host launcher (recommended for cross-project use):
- Use `scripts/project_container.sh up /path/to/project` to run any project inside a container with that project mounted to `/workspace`.
- This preserves the `/workspace` safety contract while letting you switch projects without copying scripts.

Image baseline bootstrap:
- The toolbelt image now carries a canonical coordination baseline under `/opt/codex-baseline`.
- On container start, `codex-entrypoint` runs `codex-init-workspace` to seed missing files into `/workspace/scripts` and `/workspace/coordination`.
- Existing project files are not overwritten unless `codex-init-workspace --force` is used.
- You can also run bootstrap manually: `codex-init-workspace --workspace /workspace` (or `--force` to refresh).

```bash
# create/scaffold an agent lane + role file
scripts/taskctl.sh ensure-agent pm
scripts/taskctl.sh ensure-agent designer
scripts/taskctl.sh ensure-agent architect
scripts/taskctl.sh ensure-agent fe
scripts/taskctl.sh ensure-agent be

# refresh role guidance for a specific task context if current prompt is unfit
scripts/taskctl.sh ensure-agent fe --task TASK-1002

# create a task (defaults: --to pm --from pm --priority 50)
scripts/taskctl.sh create TASK-1000 "Plan profile feature" --to pm --from pm --priority 10

# delegate to another skill agent
scripts/taskctl.sh delegate pm designer TASK-1001 "Create UX spec" --priority 20 --parent TASK-1000
scripts/taskctl.sh delegate designer fe TASK-1002 "Implement settings screen" --priority 30 --parent TASK-1001
scripts/taskctl.sh delegate architect be TASK-1003 "Implement profile API" --priority 30 --parent TASK-1000

# claim + transition
scripts/taskctl.sh claim fe
scripts/taskctl.sh done fe TASK-1002 "UI delivered and tested"
scripts/taskctl.sh block be TASK-1003 "Waiting on auth contract"

# inspect
scripts/taskctl.sh list
scripts/taskctl.sh list pm
```

## Background Workers
Run workers using `scripts/agents_ctl.sh`:

```bash
# start all role agents except default orchestrators (pm/coordinator)
scripts/agents_ctl.sh start

# include all roles (including pm/coordinator if present)
scripts/agents_ctl.sh start --all

# start only selected agents
scripts/agents_ctl.sh start designer architect fe be --interval 20

# inspect and stop
scripts/agents_ctl.sh status
scripts/agents_ctl.sh stop
```

Worker behavior:
- Polls and claims from `inbox/<agent>/<priority>/`.
- Executes with `coordination/roles/<agent>.md` + task prompt.
- Runs `ensure-agent --task` before execution to refresh role guidance when task context changes.
- On success, moves task to `done`.
- On failure, moves task to `blocked` and triggers blocker report to creator.

## Suggested Operating Pattern
1. Give requirements to `pm` in one conversation.
2. `pm` decomposes and delegates to skill agents.
3. Specialists may delegate further to lower-layer specialists.
4. Blockers automatically route back to the task creator.
5. Orchestrator resolves blockers and continues delegation until acceptance criteria are met.
