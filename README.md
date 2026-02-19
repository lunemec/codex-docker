# Codex Dev Toolbelt

Developer-focused Docker image and local coordination toolkit for Codex-driven software workflows.

This repository provides:
- `Dockerfile.codex-dev`: a reproducible dev image for Python, Node.js, Go, and Rust work.
- `scripts/project_container.sh`: host-side launcher for project containers mounted at `/workspace`.
- `scripts/taskctl.sh`, `scripts/agent_worker.sh`, `scripts/agents_ctl.sh`: local multi-agent orchestration.
- `container/codex-init-workspace.sh` and `container/codex-entrypoint.sh`: container startup bootstrap for coordination assets.

## What You Get

Base image: `node:22-bookworm` (Debian Bookworm)

Installed toolchains and CLIs include:
- Node.js, `npm`, `pnpm` (via Corepack)
- Python 3, `pip3`, `uv`, `poetry`, `pre-commit`
- Go (official tarball install)
- Rust (`rustup`, `cargo`, `rustc`)
- Dev/system tools: `git`, `docker`, `rg`, `fd`, `jq`, `yq`, `tmux`, `shellcheck`, `shfmt`, and more
- `codex` wrapper and `codex-real`

The `codex` wrapper is preserved as:
- `/usr/local/bin/codex` -> runs `codex-real` with Docker-only guard and bypass flags
- `/usr/local/bin/codex-real` -> original binary from npm install

## Prerequisites

On the host machine:
- Docker Engine running
- Access to `/var/run/docker.sock` (optional but useful for Docker-in-Docker workflows)

## Quick Start

1. Build the image:

```bash
docker build -f Dockerfile.codex-dev -t codex-dev:toolbelt .
```

2. Run an interactive container with your current repository, local Codex credentials, and optional host Docker access:

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  -v "$HOME/.codex:/root/.codex" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  codex-dev:toolbelt
```

Command breakdown:
- `--rm`: remove the container when you exit.
- `-it`: keep STDIN open and allocate a TTY for interactive shell use.
- `-v "$PWD":/workspace`: mount your current host directory into the container.
- `-w /workspace`: start the shell in `/workspace`.
- `-v "$HOME/.codex:/root/.codex"`: reuse your host Codex login/config inside the container.
- `-v /var/run/docker.sock:/var/run/docker.sock`: let containerized tools talk to the host Docker daemon.
- `codex-dev:toolbelt`: image name to run.

Common variants:
- Without local Codex login mount (you will authenticate inside the container each time):

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  codex-dev:toolbelt
```

- Without Docker socket mount (container cannot control host Docker):

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  -v "$HOME/.codex:/root/.codex" \
  codex-dev:toolbelt
```

- Without local Codex mount and without Docker socket (fully isolated session):

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  codex-dev:toolbelt
```

3. Verify core tooling:

```bash
command -v node npm pnpm python3 pip3 uv poetry go rustc cargo rg fd jq yq codex codex-real
```

## Recommended Host Workflow (Any Project Path)

Use `scripts/project_container.sh` from this repo to launch a container for any local project:

```bash
scripts/project_container.sh up /path/to/project
```

Common actions:

```bash
# Start or attach
scripts/project_container.sh up /path/to/project

# Start in background
scripts/project_container.sh up /path/to/project --detach

# Attach later
scripts/project_container.sh attach /path/to/project

# Check status
scripts/project_container.sh status /path/to/project

# Stop/remove
scripts/project_container.sh down /path/to/project
```

Useful options:
- `--image IMAGE` (default: `codex-dev:toolbelt`)
- `--name NAME`
- `--shell SHELL` (default: `bash`)
- `--no-docker-sock`
- `--keep` (do not auto-remove container)

Environment overrides:
- `CODEX_DEV_IMAGE`
- `CODEX_DEV_NAME_PREFIX`
- `CODEX_DEV_SHELL`

## Workspace Bootstrap Behavior

Workspace bootstrap is now opt-in.
At container start, entrypoint does not auto-seed `/workspace`.

Use `codex-init-workspace` when you want to seed baseline assets:

```bash
# Seed only missing files
codex-init-workspace --workspace /workspace

# Overwrite with baseline files
codex-init-workspace --workspace /workspace --force
```

This command seeds from `/opt/codex-baseline` into:
- `/workspace/scripts`
- `/workspace/coordination`

For interactive shell sessions, container startup prints a short MOTD with quick commands for:
- workspace bootstrap (`codex-init-workspace`)
- coordination workers (`scripts/agents_ctl.sh start`)
- `ralph`
- `codex`

## Multi-Agent Coordination

The coordination board lives under `coordination/` and supports dynamic skill agents with priority queues.

Queue layout:
- `coordination/inbox/<agent>/<NNN>/`
- `coordination/in_progress/<agent>/`
- `coordination/done/<agent>/<NNN>/`
- `coordination/blocked/<agent>/<NNN>/`
- `coordination/roles/<agent>.md`

Priority model:
- Lower numeric priority is more urgent (`000` is highest).

### Core Task Commands

```bash
# Create or refresh agent scaffolding (queues + role file)
scripts/taskctl.sh ensure-agent pm
scripts/taskctl.sh ensure-agent fe --task TASK-1002

# Create a top-level task
scripts/taskctl.sh create TASK-1000 "Plan profile feature" --to pm --from pm --priority 10

# Delegate to another agent
scripts/taskctl.sh delegate pm designer TASK-1001 "Create UX spec" --priority 20 --parent TASK-1000

# Claim / finish / block
scripts/taskctl.sh claim designer
scripts/taskctl.sh done designer TASK-1001 "Delivered UX spec and validation notes"
scripts/taskctl.sh block be TASK-1003 "Waiting on API contract clarification"

# List tasks
scripts/taskctl.sh list
scripts/taskctl.sh list pm
```

Block handling:
- Blocking a task moves it to `blocked`.
- A priority `000` blocker report task is auto-created for `creator_agent`.

### Background Workers

Start workers:

```bash
# Start all discovered role agents except default orchestrators
scripts/agents_ctl.sh start

# Include orchestrators too
scripts/agents_ctl.sh start --all

# Start selected agents with custom poll interval
scripts/agents_ctl.sh start designer architect fe be --interval 20

# Run one-shot workers in parallel and wait (useful where detached jobs do not persist)
scripts/agents_ctl.sh once designer architect fe be
```

Monitor and stop:

```bash
scripts/agents_ctl.sh status
scripts/agents_ctl.sh stop
```

Worker logs and runtime files:
- `coordination/runtime/logs/`
- `coordination/runtime/pids/`

Notes:
- `scripts/agents_ctl.sh status` now cleans stale PID files automatically.
- In environments that reap detached background jobs between separate shell invocations, prefer `scripts/agents_ctl.sh once ...` for deterministic execution.

## Safety Guards

Orchestration scripts enforce:
- Must run inside Docker (`/.dockerenv` must exist)
- Must run from `/workspace` (or subpath)
- Path overrides must resolve under `/workspace`

This applies to:
- `scripts/taskctl.sh`
- `scripts/agent_worker.sh`
- `scripts/agents_ctl.sh`

## Validation Commands (Required After Dockerfile Changes)

Run these after editing `Dockerfile.codex-dev`:

1. Build:

```bash
docker build -f Dockerfile.codex-dev -t codex-dev:toolbelt .
```

2. Check tool presence:

```bash
docker run --rm codex-dev:toolbelt bash -lc 'command -v node npm pnpm python3 pip3 uv poetry go rustc cargo rg fd jq yq codex codex-real'
```

3. Runtime smoke checks:

```bash
docker run --rm codex-dev:toolbelt bash -c 'python3 -m venv /tmp/venv && /tmp/venv/bin/python -V && node -e "console.log(\"ok\")" && printf "package main\nfunc main(){}\n" >/tmp/main.go && go run /tmp/main.go && cargo new /tmp/rtest >/dev/null && cd /tmp/rtest && cargo check >/dev/null'
```

## Repository Layout

```text
.
├── Dockerfile.codex-dev
├── CHANGELOG.md
├── container/
│   ├── codex-entrypoint.sh
│   └── codex-init-workspace.sh
├── coordination/
│   ├── README.md
│   ├── COORDINATOR_INSTRUCTIONS.md
│   ├── templates/
│   ├── examples/
│   └── roles/
└── scripts/
    ├── project_container.sh
    ├── taskctl.sh
    ├── agent_worker.sh
    └── agents_ctl.sh
```

## Additional Docs

- Coordination details: `coordination/README.md`
- Orchestrator operating contract: `coordination/COORDINATOR_INSTRUCTIONS.md`
- Change history: `CHANGELOG.md`
