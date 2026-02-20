# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]
### Added
- Local background specialist worker system with `scripts/agent_worker.sh` and `scripts/agents_ctl.sh`.
- Role prompt files for `db`, `be`, `fe`, and `review` agents in `coordination/roles/`.
- Coordinator documentation for one-chat operation with background task execution.
- Reusable top-level orchestrator startup prompt at `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md`.
- Dynamic skill-agent orchestration support with priority queue folders (`coordination/inbox/<agent>/<NNN>/`).
- Blocker escalation path that auto-creates creator-facing blocker report tasks.
- New default role prompts for `pm`, `designer`, and `architect`.
- Runtime safety guards that require orchestration scripts to execute inside Docker and from `/workspace`.
- Host-side per-project container launcher `scripts/project_container.sh` for mounting arbitrary project paths to `/workspace`.
- Image-baked coordination baseline under `/opt/codex-baseline` with opt-in workspace seeding via `codex-init-workspace`.
- `scripts/agents_ctl.sh once` mode to run per-agent `--once` workers in parallel and wait in a single session.
- `scripts/coordination_repair.sh` helper to backfill missing coordination directories/prompts and re-ensure core agent lanes for older/incomplete workspaces.

### Changed
- `AGENTS.md` now documents background agent orchestration commands and files.
- `scripts/taskctl.sh` now supports dynamic agents, numeric priorities, layered delegation, and creator/owner task metadata.
- `scripts/taskctl.sh ensure-agent coordinator` now auto-creates `coordination/reports/coordinator/HANDOVER.md` when missing and regenerates coordinator role prompts with explicit handover continuity/resume/update instructions.
- `scripts/agent_worker.sh` now validates dynamic role files and integrates with the updated task lifecycle.
- `scripts/agent_worker.sh` now applies per-agent reasoning effort: planner roles (`pm`, `coordinator`, `architect` by default) run with `xhigh`, while other agents default to runtime-supported `none`.
- `scripts/agent_worker.sh` now normalizes `AGENT_*_REASONING_EFFORT=default` and legacy `null` inputs to `none` to avoid config parse failures.
- `scripts/agent_worker.sh` now guards task transitions so one-shot workers do not fail when a task already self-transitioned out of `in_progress` (for example when an agent calls `taskctl done` directly).
- `README.md` and `AGENTS.md` now document the planner/orchestrator reasoning policy and corresponding worker environment overrides.
- Startup MOTD now includes quick commands for workspace repair via `scripts/coordination_repair.sh` and a one-command Codex launch that preloads the top-level orchestrator prompt.
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` now enforces a PM-style plan loop (deep clarification, specialist delegation cycles, aggregation, blocker-first handling, and explicit next-step checkpoints).
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` now requires TDD red-green-blue workflow evidence for software specialist tasks unless explicitly waived by the user.
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` now requires top-level delegation to define clear per-task success gates where applicable, with mandatory explicit gates for software tasks.
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` now enforces strict orchestrator-only boundaries, adds anti-drift self-checks, and defines a reset/handover protocol when top-level sessions start implementing directly.
- `scripts/agents_ctl.sh` now discovers agents from role files instead of a hardcoded list.
- Coordination docs, examples, and task templates now describe multi-layer PM-driven delegation.
- Orchestration script path overrides (`TASK_ROOT_DIR`, `AGENT_ROOT_DIR`, `AGENT_TASKCTL`, `AGENT_WORKER_SCRIPT`) are now constrained to `/workspace`.
- Container startup now prints an interactive MOTD with quick commands for workspace bootstrap, coordination workers, `ralph`, and `codex`.
- `Dockerfile.codex-dev` now bakes all `scripts/*.sh` into `/opt/codex-baseline/scripts`, and startup MOTD now lists all image-baked script paths so they are discoverable even before `/workspace/scripts` is seeded.
- `/usr/local/bin/codex-entrypoint` no longer auto-bootstraps `/workspace`; coordination/scripts seeding now happens only when `codex-init-workspace` is run explicitly.
- `scripts/agents_ctl.sh status` now cleans stale/invalid pid files automatically and validates pid ownership against the expected worker+agent command.

## [0.1.0] - 2026-02-18
### Added
- Initial Codex development image definition in `Dockerfile.codex-dev`.
- Multi-language toolchain support and common CLI/dev tools for Python, Go, Rust, and Node workflows.
- Login-shell PATH compatibility via `/etc/profile.d/codex-paths.sh`.
- Project-level agent guidance in `AGENTS.md`.

### Verified
- Docker image build succeeds with sanity checks.
- Runtime smoke tests pass for Python, Node, Go, Rust, and Codex wrapper commands.
