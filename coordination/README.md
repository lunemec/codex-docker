# Local Agent Coordination

This board implements a skill-based multi-agent pipeline.

You can talk to one orchestrator agent (typically `pm`), and it can delegate to any number of skill agents (`researcher`, `planner`, `designer`, `architect`, `fe`, `be`, etc.) by creating tasks for their queues.

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

## Phase Contract
Top-level orchestrator behavior (`pm` or `coordinator`) follows strict phases:
- `clarify -> research -> plan -> execute -> review -> closeout`
- Do not skip a phase gate.

Clarification remains iterative and strict:
- Ask exactly one user-facing clarification question per turn.
- Use specialist outputs to either refine requirements or generate the next single clarification question.
- Do not switch from `clarify` to `research`/`plan` without explicit user confirmation.
- Keep clarification open while blocker report tasks (`BLK-*`) are unresolved.
- Keep clarification open while unresolved critical assumptions remain.

## Commands
Use `scripts/taskctl.sh`:

Top-level prompt bootstrap:
- Prompt file: `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md`
- Launch Codex with the prompt:
  - `codex "$(cat /workspace/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md)"`

Safety guard:
- Orchestration scripts must run inside Docker and from `/workspace`.
- `TASK_ROOT_DIR`, `AGENT_ROOT_DIR`, `AGENT_TASKCTL`, and `AGENT_WORKER_SCRIPT` are restricted to paths under `/workspace`.

Host launcher (recommended for cross-project use):
- Use `scripts/toolbelt.sh <path> [<path> ...]` to run with only selected folders/files mounted into `/workspace/<basename>`.
- Add `--docker` only when host Docker daemon access is needed.

Image baseline bootstrap:
- The toolbelt image now carries a canonical coordination baseline under `/opt/codex-baseline`.
- On container start, `codex-entrypoint` prints a MOTD with quick-start commands (bootstrap is opt-in).
- Existing project files are not overwritten unless `codex-init-workspace --force` is used.
- `--force` refreshes only baseline-managed paths: `/workspace/scripts/**` and `/workspace/coordination/{README.md,COORDINATOR_INSTRUCTIONS.md,prompts/**,roles/**,templates/**,benchmark_profiles/**,examples/**}`.
- Dynamic runtime/task state is preserved even with `--force`: `/workspace/coordination/{inbox,in_progress,done,blocked,reports,runtime,task_prompts}/**`.
- You can also run bootstrap manually: `codex-init-workspace --workspace /workspace` (or `--force` for safe baseline refresh).

```bash
# create/scaffold an agent lane + role file
scripts/taskctl.sh ensure-agent pm
scripts/taskctl.sh ensure-agent researcher
scripts/taskctl.sh ensure-agent planner
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
scripts/taskctl.sh delegate designer fe TASK-1002 "Implement settings screen" --priority 30 --parent TASK-1001 --write-target src/ui/settings-screen.tsx
scripts/taskctl.sh delegate architect be TASK-1003 "Implement profile API" --priority 30 --parent TASK-1000 --write-target src/api/profile.go

# claim + transition
scripts/taskctl.sh claim fe
scripts/taskctl.sh verify-done fe TASK-1002
scripts/taskctl.sh benchmark-init coordinator TASK-2000
scripts/taskctl.sh benchmark-verify coordinator TASK-2000
scripts/taskctl.sh benchmark-rerun coordinator TASK-2000
scripts/taskctl.sh benchmark-score coordinator TASK-2000
scripts/taskctl.sh benchmark-audit-chain coordinator TASK-2000
scripts/taskctl.sh benchmark-closeout-check coordinator TASK-2000
scripts/taskctl.sh done fe TASK-1002 "UI delivered and tested"
scripts/taskctl.sh block be TASK-1003 "Waiting on auth contract"

# inspect
scripts/taskctl.sh list
scripts/taskctl.sh list pm
```

### Write-Target Metadata
- Tasks owned by resolved coding-owner lanes must declare one or more `--write-target <path>` values on `create`/`delegate`.
- Coding-owner auto-target lanes resolve with precedence: CLI `--coding-owner-lanes <agents>` > `TASK_CODING_OWNER_LANES` > default `fe,be,db` (comma or space separated values are accepted).
- For resolved coding-owner lanes, `taskctl` automatically appends each task's own in-progress file path to `intended_write_targets` so workers can always write `## Result` evidence.
- When `taskctl assign` reassigns a queued task to a resolved coding owner, it prunes any historical coding-owner self task-file targets and keeps exactly the new owner-lane self target.
- Declared targets are written to task frontmatter as:
  - `intended_write_targets`
  - `lock_scope: file`
  - `lock_policy: block_on_conflict`
- Non-coding tasks may leave `intended_write_targets` empty.

### Benchmark Metadata and Commands
- Benchmark-scored tasks should declare:
  - `benchmark_profile` (default profile: `coordination/benchmark_profiles/vault_sync_prompt_v1.json`)
  - `benchmark_workdir` (workspace directory where independent rerun commands execute)
  - `gate_targets` (for example `['G1', 'G2', 'G3', 'G4', 'G5', 'G6']`)
  - `scorecard_artifact` (for example `coordination/reports/coordinator/benchmark_scorecard.json`)
- `taskctl create/delegate` inherit benchmark metadata from parent tasks by default.
- For `execute|review|closeout` tasks in a benchmark parent chain, either keep benchmark metadata populated or set `benchmark_opt_out_reason` explicitly.
- `scripts/taskctl.sh benchmark-init <agent> <TASK_ID>` backfills benchmark metadata defaults and scaffolds a strict Result template with command/log/hash placeholders.
- `scripts/taskctl.sh benchmark-verify <agent> <TASK_ID>` validates benchmark evidence structure.
- `scripts/taskctl.sh benchmark-rerun <agent> <TASK_ID>` re-runs profile-required critical commands and writes a rerun summary artifact.
- `scripts/taskctl.sh benchmark-score <agent> <TASK_ID>` computes weighted score and writes:
  - JSON scorecard at `scorecard_artifact` (or default)
  - Markdown companion scorecard (`.md`)
- `scripts/taskctl.sh benchmark-audit-chain <agent> <TASK_ID>` validates parent/child benchmark evidence integrity across strict phases.
- `scripts/taskctl.sh benchmark-closeout-check <agent> <TASK_ID>` enforces benchmark release gate.
- Benchmark hard gate defaults:
  - total score `>= 80`
  - all targeted gates marked `pass`
  - independent rerun summary must pass when profile closeout requires rerun
  - independent rerun is review-owned and must be fresh relative to execute-phase updates

### Task-Local Prompt Sidecars
- `taskctl create` and `taskctl delegate` auto-bootstrap:
  - `coordination/task_prompts/<TASK_ID>/prompt/000.md`
  - `coordination/task_prompts/<TASK_ID>/context/000.md`
  - `coordination/task_prompts/<TASK_ID>/deliverables/000.md`
  - `coordination/task_prompts/<TASK_ID>/validation/000.md`
- Worker runtime prompt assembly is strict task-local and deterministic:
  1. `Prompt`
  2. `Context`
  3. `Deliverables`
  4. `Validation`
- Per-section precedence:
  1. Sidecar `*.md` fragments in lexicographic filename order (non-hidden markdown only).
  2. Embedded task markdown section with matching heading.
  3. Sentinel line: `MISSING SECTION: <SectionName>`.
- Runtime prompt assembly excludes `coordination/roles/*.md`; role files are not merged into worker execution prompts.
- Legacy tasks with no sidecar still execute via embedded section fallback.

### Lock Commands
Use lock commands for diagnostics, manual recovery, or explicit lock lifecycle control:

```bash
# lock lifecycle primitives
scripts/taskctl.sh lock-acquire TASK-1002 fe src/ui/settings-screen.tsx
scripts/taskctl.sh lock-heartbeat TASK-1002 fe src/ui/settings-screen.tsx
scripts/taskctl.sh lock-release TASK-1002 fe src/ui/settings-screen.tsx
scripts/taskctl.sh lock-release-task TASK-1002 fe

# inspect lock holder/payload
scripts/taskctl.sh lock-status src/ui/settings-screen.tsx

# stale lock reaping (orchestrator-only actor lanes by default: pm/coordinator)
scripts/taskctl.sh lock-clean-stale --ttl 900 --actor coordinator
```

`lock-clean-stale` is denied for non-orchestrator lanes unless `TASK_LOCK_REAPER_AGENTS` is configured to allow them. Successful stale reaps emit audit reports under `coordination/reports/<actor>/LOCK-REAP-*.md`.

## Background Workers
Run workers using `scripts/agents_ctl.sh`:

```bash
# start all role agents except default orchestrators (pm/coordinator)
scripts/agents_ctl.sh start

# include all roles (including pm/coordinator if present)
scripts/agents_ctl.sh start --all

# start only selected agents
scripts/agents_ctl.sh start designer architect fe be --interval 20

# run one-shot workers in parallel and wait for completion
scripts/agents_ctl.sh once designer architect fe be

# inspect and stop
scripts/agents_ctl.sh status
scripts/agents_ctl.sh stop
```

Worker behavior:
- Polls and claims from `inbox/<agent>/<priority>/`.
- Assembles execution prompt from task-local canonical sections (`Prompt`, `Context`, `Deliverables`, `Validation`) with sidecar-first fallback behavior.
- Applies reasoning policy by agent role: `pm`/`coordinator`/`planner`/`researcher`/`architect`/`be`/`review` default to `xhigh`; other agents default to `medium` reasoning effort (`default`/`null` aliases normalize to `none`).
- On successful worker execution, `taskctl verify-done` must pass before task transition to `done`.
- On failure, moves task to `blocked` and triggers blocker report to creator.
- `status` auto-cleans stale PID files from dead workers.
- For terminals that do not preserve detached background jobs across calls, use `agents_ctl.sh once` instead of `start`.

## Full Workflow Validation
Run the single-entry suite to validate clarification and lock behavior end-to-end:

```bash
scripts/verify_orchestrator_clarification_suite.sh
```

Coverage includes:
- top-level prompt contract (single-question clarification + phase/completion gates),
- coordinator instructions contract (iterative clarification loop + phase gates),
- task template metadata persistence,
- task done-verification contract,
- benchmark contract (profile metadata enforcement, scorecard generation, closeout gate),
- taskctl lock lifecycle and stale-reap audit behavior,
- worker lock conflict/heartbeat/release behavior,
- clarification workflow simulation for blocker routing and completion gating.

## Suggested Operating Pattern
1. Start with `pm` (or `coordinator`) and iterate one clarification question at a time.
2. Delegate discovery to `researcher`, then produce decision-complete breakdowns via `planner`/`architect`.
3. Ensure coding tasks include `--write-target` metadata so workers can enforce lock safety.
4. Populate `requirement_ids`, `evidence_commands`, and `evidence_artifacts` for execute/review tasks.
5. Resolve blocker report tasks before declaring clarification complete.
6. Finalize closeout only when requirement matrix rows are fully verified.
7. For benchmark runs, run `benchmark-audit-chain` and close only after `benchmark-closeout-check` passes.
