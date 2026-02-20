# AGENTS.md

## Project Purpose
This repository defines a Codex-focused developer Docker image (`Dockerfile.codex-dev`) used for coding, review, and general software development workflows.

## Primary File
- `Dockerfile.codex-dev`: single source of truth for the development image.
- `CHANGELOG.md`: record of notable project changes.
- `coordination/`: local multi-agent task orchestration board.
- `scripts/taskctl.sh`: helper CLI for local task transitions.
- `scripts/agent_worker.sh`: polling worker loop for specialist execution.
- `scripts/agents_ctl.sh`: start/stop/status for background specialist workers.
- `scripts/project_container.sh`: host-side launcher for per-project Docker workspaces mounted at `/workspace`.
- `container/codex-init-workspace.sh`: image bootstrap script that seeds baseline coordination files into `/workspace`.
- `container/codex-entrypoint.sh`: image entrypoint that prints startup MOTD with quick commands.

## Agent Goals
When working in this repo, prioritize:
1. Keeping the image broadly useful for common Python, Go, Rust, and Node.js workflows.
2. Preserving deterministic, reproducible Docker builds.
3. Verifying changes with real Docker build + runtime smoke checks.
4. Using the local coordination workflow for multi-agent execution.

## Required Validation After Dockerfile Changes
After any edit to `Dockerfile.codex-dev`, run:
1. `docker build -f Dockerfile.codex-dev -t codex-dev:toolbelt .`
2. `docker run --rm codex-dev:toolbelt bash -lc 'command -v node npm pnpm python3 pip3 uv poetry go rustc cargo rg fd jq yq codex codex-real'`
3. `docker run --rm codex-dev:toolbelt bash -c 'python3 -m venv /tmp/venv && /tmp/venv/bin/python -V && node -e "console.log(\"ok\")" && printf "package main\nfunc main(){}\n" >/tmp/main.go && go run /tmp/main.go && cargo new /tmp/rtest >/dev/null && cd /tmp/rtest && cargo check >/dev/null'`

## Change Guidelines
- Keep the Codex wrapper behavior intact (`/usr/local/bin/codex` invoking `codex-real` with Docker guard).
- Prefer official toolchain installs for Go/Rust unless explicitly directed otherwise.
- Use `--no-install-recommends` for apt installs.
- Clean apt lists to reduce layer size.
- Keep PATH behavior working in both non-login and login shells.
- Update `CHANGELOG.md` whenever behavior, tooling, or verification expectations change.

## Local Multi-Agent Workflow
- Create/initialize skill agents with `scripts/taskctl.sh ensure-agent <agent>`.
- For task-aware prompt tuning, run `scripts/taskctl.sh ensure-agent <agent> --task <TASK_ID|TASK_FILE>` (auto-refreshes unfit role prompts).
- Create tasks using `scripts/taskctl.sh create <TASK_ID> <TITLE> --to <owner> --from <creator> --priority <N>`.
- Delegate downstream work using `scripts/taskctl.sh delegate <from> <to> <TASK_ID> <TITLE> --priority <N> --parent <TASK_ID>`.
- Agents claim tasks with `scripts/taskctl.sh claim <agent>` from `coordination/inbox/<agent>/<NNN>/`.
- Agents only edit task files in `coordination/in_progress/<agent>/` during execution.
- Finish with `scripts/taskctl.sh done <agent> <TASK_ID>` or `scripts/taskctl.sh block <agent> <TASK_ID> \"reason\"`.
- Blocking automatically moves the task to `coordination/blocked/<agent>/<NNN>/` and creates a priority `000` blocker report task for the creator agent.
- Run continuous background workers with `scripts/agents_ctl.sh start` and monitor with `scripts/agents_ctl.sh status`.
- For execution environments that reap detached jobs between terminal calls, use one-shot parallel workers with `scripts/agents_ctl.sh once`.
- Worker reasoning defaults: `pm`/`coordinator`/`architect` run with `xhigh`; other agents run with model-default reasoning. Customize with `AGENT_XHIGH_AGENTS`, `AGENT_PLANNER_REASONING_EFFORT`, and `AGENT_DEFAULT_REASONING_EFFORT` (supports `default` alias).
- Use `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md` for a reusable top-level orchestrator startup prompt; launch with `codex "$(cat /workspace/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md)"`.
- Coordination scripts enforce Docker-only execution and require `/workspace`-scoped paths for roots/worker/taskctl scripts.

## Out of Scope Unless Asked
- Multi-stage optimization or aggressive image-size reduction.
- Non-Debian base image migration.
- CI pipeline or publish automation changes.

## Notes
- Expected base distribution is Debian Bookworm via `node:22-bookworm`.
- `bash -lc` must continue resolving Go/Rust/Python CLI tools via profile path setup.
