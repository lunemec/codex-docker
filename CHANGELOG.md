# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]
### Added
- Local background specialist worker system with `scripts/agent_worker.sh` and `scripts/agents_ctl.sh`.
- Role prompt files for `db`, `be`, `fe`, and `review` agents in `coordination/roles/`.
- Coordinator documentation for one-chat operation with background task execution.
- Dynamic skill-agent orchestration support with priority queue folders (`coordination/inbox/<agent>/<NNN>/`).
- Blocker escalation path that auto-creates creator-facing blocker report tasks.
- New default role prompts for `pm`, `designer`, and `architect`.
- Runtime safety guards that require orchestration scripts to execute inside Docker and from `/workspace`.
- Host-side per-project container launcher `scripts/project_container.sh` for mounting arbitrary project paths to `/workspace`.
- Image-baked coordination baseline under `/opt/codex-baseline` with startup workspace seeding via `codex-init-workspace`.

### Changed
- `AGENTS.md` now documents background agent orchestration commands and files.
- `scripts/taskctl.sh` now supports dynamic agents, numeric priorities, layered delegation, and creator/owner task metadata.
- `scripts/agent_worker.sh` now validates dynamic role files and integrates with the updated task lifecycle.
- `scripts/agents_ctl.sh` now discovers agents from role files instead of a hardcoded list.
- Coordination docs, examples, and task templates now describe multi-layer PM-driven delegation.
- Orchestration script path overrides (`TASK_ROOT_DIR`, `AGENT_ROOT_DIR`, `AGENT_TASKCTL`, `AGENT_WORKER_SCRIPT`) are now constrained to `/workspace`.
- Container startup now runs `/usr/local/bin/codex-entrypoint`, which bootstraps missing coordination files in `/workspace` before executing the command.

## [0.1.0] - 2026-02-18
### Added
- Initial Codex development image definition in `Dockerfile.codex-dev`.
- Multi-language toolchain support and common CLI/dev tools for Python, Go, Rust, and Node workflows.
- Login-shell PATH compatibility via `/etc/profile.d/codex-paths.sh`.
- Project-level agent guidance in `AGENTS.md`.

### Verified
- Docker image build succeeds with sanity checks.
- Runtime smoke tests pass for Python, Node, Go, Rust, and Codex wrapper commands.
