# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]
### Added
- Benchmark profile pack for vault-sync prompt scoring and gate evaluation at `coordination/benchmark_profiles/vault_sync_prompt_v1.json`.
- Benchmark helper templates: `coordination/templates/BENCHMARK_REQUIREMENT_CHECKLIST.md`, `BENCHMARK_GATE_CHECKLIST.md`, and `BENCHMARK_SCORE_TABLE.md`.
- New `taskctl` benchmark commands: `benchmark-verify`, `benchmark-score`, and `benchmark-closeout-check`.
- `scripts/verify_benchmark_contract.sh` smoke verifier for benchmark metadata validation, scorecard generation, and closeout gate behavior.
- Global npm install for `@googleworkspace/cli` in the development image.
- Global npm install for `openclaw` in the development image.
- Google Cloud CLI (`gcloud`) and Kubernetes CLIs (`kubectl`, `kubectx`, `kubens`) in the development image.
- Google GKE auth helper (`gke-gcloud-auth-plugin`) in the development image for `kubectl` authentication against GKE.
- Additional AI provider CLIs in the development image: `@anthropic-ai/claude-code` (`claude`), `@google/gemini-cli` (`gemini`), and Cursor Agent (`cursor`/`agent`/`cursor-agent`).
- Additional terminal tooling in the development image: `fzf`, `cloc`, `sloccount`, `hyperfine`, `entr`, `httpie`, and `ncdu`.
- Additional performance/request tooling in the development image: `wrk`, `ab` (`apache2-utils`), `hey`, `ghz`, `grpcurl`, `wget`, and `aria2`.
- Local background specialist worker system with `scripts/agent_worker.sh` and `scripts/agents_ctl.sh`.
- Role prompt files for `db`, `be`, `fe`, and `review` agents in `coordination/roles/`.
- Coordinator documentation for one-chat operation with background task execution.
- Reusable top-level orchestrator startup prompt at `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md`.
- Dynamic skill-agent orchestration support with priority queue folders (`coordination/inbox/<agent>/<NNN>/`).
- Blocker escalation path that auto-creates creator-facing blocker report tasks.
- New default role prompts for `pm`, `designer`, and `architect`.
- Runtime safety guards that require orchestration scripts to execute inside Docker and from `/workspace`.
- Image-baked coordination baseline under `/opt/codex-baseline` with opt-in workspace seeding via `codex-init-workspace`.
- `scripts/agents_ctl.sh once` mode to run per-agent `--once` workers in parallel and wait in a single session.
- `scripts/coordination_repair.sh` helper to backfill missing coordination directories/prompts and re-ensure core agent lanes for older/incomplete workspaces.
- Task template lock metadata contract verifier at `scripts/verify_task_template_lock_metadata_contract.sh`.
- `scripts/verify_taskctl_lock_contract.sh` contract/smoke verifier for lock lifecycle helpers, stale-lock reap audit behavior, and coding-task write-target validation.
- `scripts/verify_agent_worker_lock_contract.sh` contract/smoke verifier for worker lock enforcement (conflict blocking, heartbeat updates, and lock release on success/failure).
- `scripts/verify_clarification_workflow_contract.sh` end-to-end orchestration simulation verifier for blocker routing and clarification completion gate logic.
- `scripts/verify_orchestrator_clarification_suite.sh` single-entry verification suite for all clarification and locking contracts.
- `scripts/verify_agent_worker_reasoning_contract.sh` contract verifier proving per-agent reasoning selection isolation (`coordinator` planner effort vs downstream default effort with no sticky leakage).
- Host-side selective mount launcher `scripts/toolbelt.sh` with opt-in Docker socket support (`--docker`) and path-to-`/workspace/<basename>` mapping.

### Changed
- `coordination/templates/TASK_TEMPLATE.md` now includes benchmark metadata defaults (`benchmark_profile`, `gate_targets`, `scorecard_artifact`) and stricter Result evidence guidance (`Requirement Statuses`, `Command` + `Exit` + `Log`, gate and category score sections for benchmark tasks).
- `scripts/taskctl.sh verify-done` now enforces stricter strict-phase evidence (`requirement_ids`, per-requirement status rows, and `Log:` entries) and triggers benchmark evidence checks when a benchmark profile is configured.
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` and `coordination/COORDINATOR_INSTRUCTIONS.md` now enforce benchmark-first release rules, including conservative evidence handling, independent critical command reruns in review, and hard closeout gate (`score >= 80` + all gates pass).
- `scripts/verify_top_level_prompt_contract.sh` and `scripts/verify_coordinator_instructions_contract.sh` now assert benchmark closeout and independent rerun clauses.
- `scripts/verify_orchestrator_clarification_suite.sh` now includes benchmark contract validation.
- `coordination/README.md` and top-level `README.md` now document benchmark task metadata and benchmark scoring/closeout commands.
- `AGENTS.md` now documents background agent orchestration commands and files.
- `AGENTS.md` now enforces a fixed runtime image tag (`codex-dev:toolbelt`) and requires `README.md` updates for project changes.
- `scripts/taskctl.sh` now supports dynamic agents, numeric priorities, layered delegation, and creator/owner task metadata.
- `scripts/taskctl.sh ensure-agent coordinator` now auto-creates `coordination/reports/coordinator/HANDOVER.md` when missing and regenerates coordinator role prompts with explicit handover continuity/resume/update instructions.
- `scripts/agent_worker.sh` now validates dynamic role files and integrates with the updated task lifecycle.
- `scripts/agent_worker.sh` now applies per-agent reasoning effort: planner roles (`pm`, `coordinator`, `architect` by default) run with `xhigh`, while other agents default to runtime-supported `none`.
- `scripts/agent_worker.sh` now normalizes `AGENT_*_REASONING_EFFORT=default` and legacy `null` inputs to `none` to avoid config parse failures.
- `scripts/agent_worker.sh` now guards task transitions so one-shot workers do not fail when a task already self-transitioned out of `in_progress` (for example when an agent calls `taskctl done` directly).
- `README.md` and `AGENTS.md` now document the planner/orchestrator reasoning policy and corresponding worker environment overrides.
- `README.md` now documents selective mount workflows with `scripts/toolbelt.sh`, including examples and zsh/bash alias usage.
- `scripts/toolbelt.sh` now mounts the current working directory to `/workspace` when no positional mount paths are provided.
- `scripts/toolbelt.sh` now exposes unified short-word and long flag aliases across options (`-docker`/`--docker`, `-image`/`--image`, `-workdir`/`--workdir`, `-shell`/`--shell`, `-tmpfs-size`/`--tmpfs-size`, `-keep`/`--keep`), while keeping compatibility aliases such as `-w`.
- `scripts/toolbelt.sh` gcloud/k8s mount validation errors now reference both accepted aliases (`-gcloud`/`--gcloud`, `-k8s`/`--k8s`) for clearer guidance.
- Startup MOTD now presents grouped/colorized sections with most-used commands first (`codex`, `ralph`, `openclaw`, `claude`, `gemini`, `cursor` with `agent`/`cursor-agent` aliases, `codex-init-workspace`), plus a dynamic absolute-path listing of all image-baked scripts under `/opt/codex-baseline/scripts/`.
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
- `/usr/local/bin/codex-entrypoint` now bootstraps `/root/.codex` from minimal mounted secret paths (`/run/secrets/codex-auth.json`, `/run/secrets/codex-config.toml`) with optional API-key fallback, enabling ephemeral Codex home usage without mounting host `~/.codex`.
- `/usr/local/bin/codex-entrypoint` now also bootstraps gcloud and kube runtime state from mounted secret sources (`/run/secrets/gcloud-config`, `/run/secrets/kube-config`) into `/root/.config/gcloud` and `/root/.kube/config`.
- `scripts/agents_ctl.sh status` now cleans stale/invalid pid files automatically and validates pid ownership against the expected worker+agent command.
- `coordination/templates/TASK_TEMPLATE.md` now includes `intended_write_targets`, `lock_scope`, and `lock_policy` lock metadata defaults for write-conflict-safe task orchestration.
- `scripts/taskctl.sh` now includes lock lifecycle helpers (`lock-acquire`, `lock-heartbeat`, `lock-release`, `lock-release-task`), lock diagnostics (`lock-status`), stale lock cleanup (`lock-clean-stale --ttl [--actor <agent>]`) gated to orchestrator lanes, per-reap audit reports under `coordination/reports/<actor>/`, and coding-task validation that enforces non-empty `intended_write_targets` for FE/BE/DB owners.
- `scripts/agent_worker.sh` now enforces declared write-target locks during execution, blocks on lock conflicts with explicit reasons, maintains lock heartbeats, and releases held locks on both success and failure paths.
- `scripts/verify_top_level_prompt_contract.sh` and `scripts/verify_coordinator_instructions_contract.sh` now assert the full clarification completion gate, including the unresolved critical assumptions clause.
- `coordination/README.md` now documents the strict clarification loop contract, coding-task write-target metadata requirements, lock command usage, stale-lock reaper constraints, and the single-entry full workflow validation command.
- `README.md` container run guidance now defaults to `--tmpfs /root/.codex` plus minimal read-only auth/config file mounts and removes full host `~/.codex` mount recommendations.

### Verified
- `scripts/verify_benchmark_contract.sh` passes, covering profile-driven benchmark evidence validation, scorecard generation, and strict closeout gate checks.
- `scripts/verify_orchestrator_clarification_suite.sh` passes, covering clarification gating, specialist blocker routing, task lock lifecycle/conflict handling, worker heartbeat/release behavior, per-agent reasoning isolation, and template metadata persistence.

## [0.1.0] - 2026-02-18
### Added
- Initial Codex development image definition in `Dockerfile.codex-dev`.
- Multi-language toolchain support and common CLI/dev tools for Python, Go, Rust, and Node workflows.
- Login-shell PATH compatibility via `/etc/profile.d/codex-paths.sh`.
- Project-level agent guidance in `AGENTS.md`.

### Verified
- Docker image build succeeds with sanity checks.
- Runtime smoke tests pass for Python, Node, Go, Rust, and Codex wrapper commands.
