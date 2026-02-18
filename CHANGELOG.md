# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]
### Added
- Local background specialist worker system with `scripts/agent_worker.sh` and `scripts/agents_ctl.sh`.
- Role prompt files for `db`, `be`, `fe`, and `review` agents in `coordination/roles/`.
- Coordinator documentation for one-chat operation with background task execution.

### Changed
- `AGENTS.md` now documents background agent orchestration commands and files.

## [0.1.0] - 2026-02-18
### Added
- Initial Codex development image definition in `Dockerfile.codex-dev`.
- Multi-language toolchain support and common CLI/dev tools for Python, Go, Rust, and Node workflows.
- Login-shell PATH compatibility via `/etc/profile.d/codex-paths.sh`.
- Project-level agent guidance in `AGENTS.md`.

### Verified
- Docker image build succeeds with sanity checks.
- Runtime smoke tests pass for Python, Node, Go, Rust, and Codex wrapper commands.
