# Codex Dev Toolbelt

Developer-focused Docker image and local coordination toolkit for Codex-driven software workflows.

This repository provides:
- `Dockerfile.codex-dev`: a reproducible dev image for Python, Node.js, Go, and Rust work.
- `scripts/toolbelt.sh`: host-side launcher for selective mounts into `/workspace/<basename>`.
- `scripts/taskctl.sh`, `scripts/agent_worker.sh`, `scripts/agents_ctl.sh`: local multi-agent orchestration.
- `container/codex-init-workspace.sh` and `container/codex-entrypoint.sh`: container startup bootstrap for coordination assets.

## What You Get

Base image: `node:22-bookworm` (Debian Bookworm)

Installed toolchains and CLIs include:
- Node.js, `npm`, `pnpm` (via Corepack)
- Python 3, `pip3`, `uv`, `poetry`, `pre-commit`
- Go (official tarball install)
- Rust (`rustup`, `cargo`, `rustc`)
- Dev/system tools: `git`, `docker`, `fzf`, `rg`, `fd`, `jq`, `yq`, `cloc`, `sloccount`, `hyperfine`, `wrk`, `ab`, `hey`, `ghz`, `grpcurl`, `httpie`, `wget`, `aria2`, `entr`, `ncdu`, `tmux`, `shellcheck`, `shfmt`, and more
- Cloud/Kubernetes CLIs: `gcloud`, `gke-gcloud-auth-plugin`, `kubectl`, `kubectx`, `kubens`
- AI CLIs: `codex`, `claude`, `gemini`, and Cursor Agent as `cursor` (`agent`/`cursor-agent` aliases)
- Workspace CLIs: `ralph`, `openclaw`, and `@googleworkspace/cli`
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

2. Run an interactive container with your current repository, ephemeral Codex state, mounted auth/config inputs, and optional host Docker access:

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  --tmpfs /root/.codex:rw,nosuid,nodev,size=512m \
  -v "$HOME/.codex/auth.json:/run/secrets/codex-auth.json:ro" \
  -v "$HOME/.codex/config.toml:/run/secrets/codex-config.toml:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  codex-dev:toolbelt
```

Command breakdown:
- `--rm`: remove the container when you exit.
- `-it`: keep STDIN open and allocate a TTY for interactive shell use.
- `-v "$PWD":/workspace`: mount your current host directory into the container.
- `-w /workspace`: start the shell in `/workspace`.
- `--tmpfs /root/.codex:...`: keep Codex runtime state ephemeral.
- `-v "$HOME/.codex/auth.json:/run/secrets/codex-auth.json:ro"`: provide OAuth/API auth material without mounting the full host `~/.codex`.
- `-v "$HOME/.codex/config.toml:/run/secrets/codex-config.toml:ro"`: provide Codex config defaults without mounting full host state.
- `-v /var/run/docker.sock:/var/run/docker.sock`: let containerized tools talk to the host Docker daemon.
- `codex-dev:toolbelt`: image name to run.

Common variants:
- Without Docker socket mount (container cannot control host Docker):

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  --tmpfs /root/.codex:rw,nosuid,nodev,size=512m \
  -v "$HOME/.codex/auth.json:/run/secrets/codex-auth.json:ro" \
  -v "$HOME/.codex/config.toml:/run/secrets/codex-config.toml:ro" \
  codex-dev:toolbelt
```

- With API-key auth and no host Codex mounts:

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  --tmpfs /root/.codex:rw,nosuid,nodev,size=512m \
  -e OPENAI_API_KEY \
  -v /var/run/docker.sock:/var/run/docker.sock \
  codex-dev:toolbelt
```

- Fully isolated session (no Docker socket and no host Codex mounts):

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  --tmpfs /root/.codex:rw,nosuid,nodev,size=512m \
  -e OPENAI_API_KEY \
  codex-dev:toolbelt
```

If single-file mounts are unreliable in your Docker runtime, mount a temporary directory that only contains `auth.json` and `config.toml`, then point `CODEX_AUTH_JSON_SRC` and `CODEX_CONFIG_TOML_SRC` at those files.

3. Verify core tooling:

```bash
command -v node npm pnpm python3 pip3 uv poetry go rustc cargo \
  fzf rg fd jq yq cloc sloccount hyperfine wrk ab hey ghz grpcurl http wget aria2c entr ncdu \
  gcloud gke-gcloud-auth-plugin kubectl kubectx kubens \
  codex codex-real claude gemini cursor agent cursor-agent openclaw
```

## Selective Mount Workflow (Smaller Surface Area)

Use `scripts/toolbelt.sh` when you want to mount only a few folders/files instead of an entire project tree.

```bash
# Mount current directory to /workspace
scripts/toolbelt.sh

# Mount only selected paths under /workspace/<basename>
scripts/toolbelt.sh ./directory1 ./directory2

# Add host Docker access only when needed
scripts/toolbelt.sh -docker ../directory1 ../directory2

# Add hardened gcloud + kube credential mounts when needed
scripts/toolbelt.sh -gcloud -k8s ./directory1 ./directory2

# Run a command instead of an interactive shell
scripts/toolbelt.sh ./directory1 ./directory2 -- bash -lc 'ls -la /workspace'
```

Behavior summary:
- If no positional paths are provided, the current directory is mounted at `/workspace`.
- Each positional path becomes one mount at `/workspace/<basename(path)>`.
- Docker socket is opt-in via `-docker` / `--docker`.
- `/root/.codex` is mounted as tmpfs (`512m` default).
- `~/.codex/auth.json` and `~/.codex/config.toml` are mounted read-only automatically when present.
- `-gcloud` / `--gcloud` mounts host `~/.config/gcloud` read-only to `/run/secrets/gcloud-config`; entrypoint hydrates `/root/.config/gcloud` inside container runtime state.
- `-k8s` / `--k8s` mounts host `~/.kube/config` read-only to `/run/secrets/kube-config`; entrypoint hydrates `/root/.kube/config`.
- Path basenames must be unique per run (to avoid destination collisions).
- Missing requested credential sources fail fast with a clear error.
- Override credential source paths with `CODEX_GCLOUD_CONFIG_SRC` and `CODEX_KUBECONFIG_SRC`.

Useful options:
- `-docker` / `--docker`
- `-gcloud` / `--gcloud`
- `-k8s` / `--k8s`
- `-image` / `--image IMAGE`
- `-workdir` / `--workdir DIR` (`-w DIR` also supported)
- `-shell` / `--shell SHELL`
- `-tmpfs-size` / `--tmpfs-size SIZE`
- `-keep` / `--keep`

Optional shell aliases:

`~/.zshrc`:

```bash
alias toolbelt='/absolute/path/to/this/repo/scripts/toolbelt.sh'
```

`~/.bashrc`:

```bash
alias toolbelt='/absolute/path/to/this/repo/scripts/toolbelt.sh'
```

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

If older runs left partial coordination state (missing prompts/folders), run:

```bash
scripts/coordination_repair.sh
```

For interactive shell sessions, container startup prints a short MOTD with quick commands for:
- most-used CLIs first (`codex`, `ralph`, `openclaw`, `claude`, `gemini`, `cursor` with `agent`/`cursor-agent` aliases, `codex-init-workspace`)
- workspace bootstrap (`codex-init-workspace`)
- coordination repair (`scripts/coordination_repair.sh`)
- coordination workers (`scripts/agents_ctl.sh start`)
- top-level orchestrator launch command
- grouped, colorized sections with image-baked script listings by absolute path (`/opt/codex-baseline/scripts/*.sh`)

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

Top-level orchestrator prompt:
- Prompt file: `coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md`
- Auto-launch Codex with it:
  - `codex "$(cat /workspace/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md)"`

### Core Task Commands

```bash
# Create or refresh agent scaffolding (queues + role file)
scripts/taskctl.sh ensure-agent pm
scripts/taskctl.sh ensure-agent researcher
scripts/taskctl.sh ensure-agent planner
scripts/taskctl.sh ensure-agent fe --task TASK-1002

# Create a top-level task
scripts/taskctl.sh create TASK-1000 "Plan profile feature" --to pm --from pm --priority 10

# Delegate to another agent
scripts/taskctl.sh delegate pm designer TASK-1001 "Create UX spec" --priority 20 --parent TASK-1000

# Claim / finish / block
scripts/taskctl.sh claim designer
scripts/taskctl.sh verify-done designer TASK-1001
scripts/taskctl.sh benchmark-init coordinator TASK-2000
scripts/taskctl.sh benchmark-verify coordinator TASK-2000
scripts/taskctl.sh benchmark-rerun coordinator TASK-2000
scripts/taskctl.sh benchmark-score coordinator TASK-2000
scripts/taskctl.sh benchmark-audit-chain coordinator TASK-2000
scripts/taskctl.sh benchmark-closeout-check coordinator TASK-2000
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
- Worker reasoning policy defaults to `xhigh` for strict-delivery lanes (`pm`, `coordinator`, `planner`, `researcher`, `architect`, `be`, `review`) and `medium` for others; override with `AGENT_XHIGH_AGENTS`, `AGENT_PLANNER_REASONING_EFFORT`, and `AGENT_DEFAULT_REASONING_EFFORT` if needed (`default`/`null` aliases normalize to `none`).
- Worker success does not auto-close tasks; `taskctl verify-done` must pass before transition to `done`.
- Benchmark tasks now require structured evidence blocks (`Command`/`Exit`/`Log`/`Log Hash`/`Observed`) and independent rerun evidence for strict closeout.
- `benchmark-closeout-check` now enforces review-owned reruns and rerun freshness after execute-phase updates.
- Benchmark metadata now inherits from parent tasks by default on `create`/`delegate`; strict benchmark-parent execution/review/closeout tasks require benchmark metadata or explicit `benchmark_opt_out_reason`.

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

4. GKE auth plugin presence:

```bash
docker run --rm codex-dev:toolbelt bash -lc 'command -v gke-gcloud-auth-plugin && gke-gcloud-auth-plugin --version'
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
    ├── toolbelt.sh
    ├── taskctl.sh
    ├── agent_worker.sh
    └── agents_ctl.sh
```

## Additional Docs

- Coordination details: `coordination/README.md`
- Orchestrator operating contract: `coordination/COORDINATOR_INSTRUCTIONS.md`
- Change history: `CHANGELOG.md`
