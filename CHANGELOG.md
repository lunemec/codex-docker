# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]
### Fixed
- ForgeCode config mounting changed from direct bind-mount at `/home/coder/forge` to read-only secrets mount at `/run/secrets/forge-config:ro` with `copy_secret_tree` hydration into `${CODER_HOME}/forge`. Fixes `rm: cannot remove '/home/coder/forge': Device or resource busy` crash caused by the bind mount blocking the entrypoint's `/home/coder` symlink-replacement logic when `TOOLBELT_HOST_HOME` is set.

### Changed
- `scripts/toolbelt.sh` now requires a provider subcommand (`codex`, `claude`, or `forge`) as the first argument; running bare `toolbelt` without a provider errors with usage help.
- `claude` binary is now wrapped: `/usr/local/bin/claude` invokes `claude-real` with Docker guard and `--dangerously-skip-permissions` (same pattern as the `codex` wrapper). The entrypoint drops to `coder` (UID 1000), so the root restriction no longer applies. The unwrapped binary is available as `claude-real`.
- `scripts/toolbelt.sh` now supports `forge` as a third provider, mounting host `~/forge/` read-only for ForgeCode credentials.
- `scripts/toolbelt.sh` now supports `-forge` / `--forge` flag (claude provider only) to co-mount ForgeCode config alongside Claude config in the same session.
- `container/toolbelt-entrypoint.sh` now includes `bootstrap_forge_home()` to hydrate ForgeCode config from `/run/secrets/forge-config` into the coder user's home.
- Container MOTD now stays compact by focusing on workspace mounts and enabled features, without listing baked helper or verification scripts by default.
- `codex` provider mounts Codex credentials and `/root/.codex` tmpfs as before; `claude` provider mounts `~/.claude/` read-only and passes `ANTHROPIC_API_KEY` into the container.
- `container/toolbelt-entrypoint.sh` now reads `TOOLBELT_PROVIDER` to conditionally bootstrap only the selected provider's home directory.
- Launcher environment overrides renamed from `CODEX_*` to `TOOLBELT_*` (e.g. `CODEX_DEV_IMAGE` → `TOOLBELT_IMAGE`, `CODEX_GCLOUD_CONFIG_SRC` → `TOOLBELT_GCLOUD_CONFIG_SRC`). Codex-tool internals in the entrypoint (`CODEX_HOME`, `CODEX_AUTH_JSON_SRC`, `CODEX_CONFIG_TOML_SRC`, `CODEX_SHOW_MOTD`) are unchanged.
- Renamed `container/codex-entrypoint.sh` → `container/toolbelt-entrypoint.sh` and `/opt/codex-baseline/scripts/` → `/opt/toolbelt/scripts/`.
- Removed deprecated `container/codex-init-workspace.sh` compatibility stub.
- Removed coordinator section from container MOTD; renamed MOTD title to "Toolbelt Container".

- Coordinator source-of-truth has been extracted out of `toolbelt` into the standalone `/workspace/coordinator` repository.
- `toolbelt` now owns only the development image, entrypoint/bootstrap glue, host launcher, and toolbelt-specific helper scripts.
- `codex-init-workspace` is now a deprecated compatibility stub that exits with guidance instead of seeding embedded coordinator assets.
- The container MOTD now points users at `/workspace/coordinator` when that standalone repository is present and otherwise states that coordinator assets are no longer embedded in the image.
- `README.md`, `container/toolbelt-entrypoint.sh`, and `container/codex-init-workspace.sh` now describe the coordinator split as the steady-state boundary for this phase: `toolbelt` only references an external checkout at `/workspace/coordinator`, while `codex-init-workspace` remains redirect-only.
- `scripts/toolbelt.sh` now mounts host OpenCode config only when `-opencode` / `--opencode` is requested, instead of auto-importing it into every session.
- `scripts/toolbelt.sh` now supports `-kimaki` / `--kimaki`, which mounts host Kimaki state from `~/.kimaki` to `/home/coder/.kimaki` by default; `TOOLBELT_KIMAKI_CONFIG_SRC` overrides the host source path.
- `scripts/toolbelt.sh -kimaki/--kimaki` continues to implicitly enable the required OpenCode import so Kimaki sees the same OpenCode config inside the container.
- `container/toolbelt-entrypoint.sh` now hydrates OpenCode runtime state only for sessions that explicitly import OpenCode config, while still preserving the baked `context-mode` defaults.

### Removed
- Embedded coordinator baseline files from the `toolbelt` Docker build context.
- Coordinator quickstart/bootstrap documentation from `toolbelt` README and AGENTS guidance.

### Added
- ForgeCode (`forge`) binary installed in the development image from upstream GitHub releases (pinned version via `FORGE_VERSION` build arg).
- Global npm install for `opencode-ai` in the development image.
- Global npm install for `kimaki` in the development image.
- `scripts/verify_toolbelt_kimaki_contract.sh` launcher contract verifier for `-kimaki` default mounting, env override handling, and missing-directory failures.
- `scripts/verify_toolbelt_opencode_contract.sh` launcher contract verifier for automatic OpenCode import, env override handling, missing-directory failures, and `-kimaki` implication.
- `scripts/verify_toolbelt_opencode_runtime_contract.sh` entrypoint contract verifier for OpenCode runtime hydration, provider file copy-through, invalid JSON warnings, and default `context-mode` preservation.
- `scripts/verify_toolbelt_coordinator_boundary_contract.sh` contract verifier for steady-state coordinator boundary messaging, launcher mount semantics, entrypoint external-checkout detection, and `codex-init-workspace` redirect behavior.
- Experimental/incomplete `scripts/gws-scope-guard.sh` image-baked `gws` wrapper that preflights Workspace API scopes for direct in-container `gws` calls and adds a targeted hint when `403 insufficientPermissions` still reaches the user.
- `scripts/verify_gws_scope_guard_contract.sh` contract verifier for the experimental in-container `gws` scope guard, including mismatch blocking and fallback 403 hinting.
- `scripts/verify_toolbelt_gws_scope_contract.sh` contract verifier for experimental direct-`gws` scope preflight behavior, mismatch blocking, and best-effort warning fallback when schema lookup fails.
- New `taskctl` benchmark command: `benchmark-audit-chain`, which validates benchmark evidence integrity across parent/child strict-phase tasks.
- New `taskctl` benchmark command: `benchmark-init`, which backfills benchmark metadata defaults and scaffolds strict Result templates (requirements, gates, scores, command blocks, and `Log Hash` placeholders).
- New `taskctl create/delegate` benchmark options: `--benchmark-profile`, `--benchmark-workdir`, `--gate-target`, `--scorecard-artifact`, `--benchmark-opt-out-reason`, and `--no-benchmark-inherit`.
- New `taskctl` benchmark command: `benchmark-rerun`, which independently re-executes profile-required critical commands and writes rerun summaries under `coordination/reports/<agent>/benchmark_reruns/`.
- Benchmark profile schema extensions for strict evidence checks: `gate_required_command_patterns`, `gate_required_artifact_patterns`, and `credibility_checks.G6` (RGB credibility requirements).
- Benchmark profile pack for vault-sync prompt scoring and gate evaluation at `coordination/benchmark_profiles/vault_sync_prompt_v1.json`.
- Benchmark helper templates: `coordination/templates/BENCHMARK_REQUIREMENT_CHECKLIST.md`, `BENCHMARK_GATE_CHECKLIST.md`, and `BENCHMARK_SCORE_TABLE.md`.
- New `taskctl` benchmark commands: `benchmark-verify`, `benchmark-score`, and `benchmark-closeout-check`.
- `scripts/verify_benchmark_contract.sh` smoke verifier for benchmark metadata validation, scorecard generation, and closeout gate behavior.
- Global npm install for `@googleworkspace/cli` in the development image.
- Global npm install for `openclaw` in the development image.
- Google Cloud CLI (`gcloud`) and Kubernetes CLIs (`kubectl`, `kubectx`, `kubens`) in the development image.
- Google GKE auth helper (`gke-gcloud-auth-plugin`) in the development image for `kubectl` authentication against GKE.
- Additional AI provider CLIs in the development image: `@anthropic-ai/claude-code` (`claude`), `@google/gemini-cli` (`gemini`), and Cursor Agent (`cursor`/`agent`/`cursor-agent`).
- Additional terminal tooling in the development image: `fzf`, `cloc`, `sloccount`, `hyperfine`, `entr`, `httpie`, `xh`, `curlie`, and `ncdu`.
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
- `scripts/toolbelt.sh -gws/--gws` now exports portable host `gws` credentials with `gws auth export --unmasked`, mounts them read-only, and `/usr/local/bin/codex-entrypoint` hydrates them into in-container `~/.config/gws/credentials.json` without modifying host files; host ADC from `~/.config/gcloud/application_default_credentials.json` remains the fallback when export is unavailable.
- `scripts/toolbelt.sh -gws/--gws` now fails fast with actionable guidance when neither portable `gws` credentials nor ADC are available, instead of deferring to an in-container `401 Access denied. No credentials provided` failure.
- `scripts/toolbelt.sh -gws/--gws` now attempts OAuth scope preflight for direct `gws <service> <resource> <method>` commands before `docker run`; confirmed mismatches fail fast with required/granted scope details and a host re-auth hint, while lookup failures degrade to a warning and still launch the container. This path is not yet fully validated end-to-end inside the container.
- `/usr/local/bin/codex-entrypoint` now installs the experimental image-baked `gws` wrapper so interactive in-container `gws` calls can surface the same scope diagnosis as one-shot launcher commands after the image is rebuilt.
- `README.md` now documents that `gws auth status` inside the container should reflect hydrated plaintext/runtime credentials, and that `403 insufficientPermissions` indicates missing OAuth scopes in the host `gws` login rather than a failed mount.
- The development image file is now `Dockerfile` instead of `Dockerfile.codex-dev`, and image build docs/scripts now default to `docker build -t toolbelt:latest .`.
- The development image now uses `node:22-trixie` and Debian Trixie packages for Docker client tooling (`docker`, `docker buildx`, Compose v2 via `docker compose` and `docker-compose`) instead of Bookworm `docker.io` plus a manually downloaded Compose plugin wrapper.
- `scripts/taskctl.sh benchmark-audit-chain` now enforces requirement-aware chain coverage, requiring execute/review evidence ownership per benchmark requirement.
- `scripts/taskctl.sh benchmark-verify` now requires `Log Hash` fields for structured command evidence and validates hash integrity against referenced logs.
- `scripts/taskctl.sh benchmark-rerun` now emits integrity metadata (`task_file_hash`, `profile_hash`, per-command `log_hash`, and required-command hash) in rerun summaries.
- `scripts/taskctl.sh benchmark-closeout-check` now enforces review-owned independent reruns, rerun freshness relative to execute-phase updates, rerun-summary integrity checks, and closeout requirement consistency against child execute/review outcomes.
- `scripts/taskctl.sh create/delegate` now inherit benchmark metadata from benchmark-configured parents by default and enforce explicit metadata (or explicit opt-out reason) for `execute|review|closeout` tasks in benchmark parent chains.
- `scripts/taskctl.sh verify-done` now enforces benchmark ancestry requirements for strict phases, runs `benchmark-closeout-check` automatically for benchmark closeout tasks, and validates queue path/status consistency.
- `scripts/taskctl.sh` benchmark command resolution now rejects task files whose frontmatter status disagrees with queue location.
- `scripts/taskctl.sh benchmark-verify` now validates structured command evidence blocks (`Command` + `Exit` + `Log` + `Observed`) for benchmark tasks, enforces workspace-scoped log artifacts, evaluates pattern-based gate evidence, and applies explicit RGB credibility checks for G6.
- `scripts/taskctl.sh verify-done` now requires structured evidence blocks for declared `evidence_commands`, including workspace-scoped existing log files and non-empty observed summaries.
- `scripts/taskctl.sh benchmark-closeout-check` now enforces independent rerun evidence when required by benchmark profile closeout settings.
- `coordination/templates/TASK_TEMPLATE.md` now includes `benchmark_workdir` metadata and explicit RGB evidence key format guidance for benchmark tasks.
- `coordination/templates/TASK_TEMPLATE.md` now includes `benchmark_opt_out_reason` and benchmark-parent strict-phase guidance.
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` and `coordination/COORDINATOR_INSTRUCTIONS.md` now require `benchmark_workdir`, structured benchmark evidence blocks, anti-stub/no-op enforcement, and benchmark rerun execution during review.
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md`, `coordination/COORDINATOR_INSTRUCTIONS.md`, and role contracts now require full-team benchmark risk coverage (research/architectural invariants/negative-path review) and benchmark chain audit before closeout.
- `scripts/verify_top_level_prompt_contract.sh` and `scripts/verify_coordinator_instructions_contract.sh` now assert benchmark rerun and structured-evidence clauses.
- `coordination/README.md` and `README.md` now document `benchmark-rerun`, `benchmark_workdir`, and strict closeout rerun requirements.
- `coordination/templates/TASK_TEMPLATE.md` now includes benchmark metadata defaults (`benchmark_profile`, `gate_targets`, `scorecard_artifact`) and stricter Result evidence guidance (`Requirement Statuses`, `Command` + `Exit` + `Log`, gate and category score sections for benchmark tasks).
- `scripts/taskctl.sh verify-done` now enforces stricter strict-phase evidence (`requirement_ids`, per-requirement status rows, and `Log:` entries) and triggers benchmark evidence checks when a benchmark profile is configured.
- `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` and `coordination/COORDINATOR_INSTRUCTIONS.md` now enforce benchmark-first release rules, including conservative evidence handling, independent critical command reruns in review, and hard closeout gate (`score >= 80` + all gates pass).
- `scripts/verify_top_level_prompt_contract.sh` and `scripts/verify_coordinator_instructions_contract.sh` now assert benchmark closeout and independent rerun clauses.
- `scripts/verify_orchestrator_clarification_suite.sh` now includes benchmark contract validation.
- `coordination/README.md` and top-level `README.md` now document benchmark task metadata and benchmark scoring/closeout commands.
- `AGENTS.md` now documents background agent orchestration commands and files.
- `AGENTS.md` now enforces a fixed runtime image tag (`toolbelt:latest`) and requires `README.md` updates for project changes.
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
- `scripts/toolbelt.sh` now supports `-gws`/`--gws` to mount host Google Workspace CLI config from `~/.config/gws`, and `/usr/local/bin/codex-entrypoint` now hydrates it into the container's `gws` config directory.
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
- Debian Trixie `docker-cli`, `docker-buildx`, `docker-compose`, and `iptables` validate inside the image, and host-socket smoke succeeds with `docker ps`, `docker compose version`, and `docker buildx version`.
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
