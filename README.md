# Codex Dev Toolbelt

Developer-focused Docker image and selective-mount launcher for Codex-driven software workflows.

This repository now owns the development image and host launcher only. The coordinator/orchestration source of truth lives in the standalone `/workspace/coordinator` repository for this phase. Any future packaged integration is outside the scope of this repo.

## What You Get

Base image: `node:22-trixie` (Debian Trixie)

Installed toolchains and CLIs include:
- Node.js, `npm`, `pnpm` (via Corepack)
- Python 3, `pip3`, `uv`, `poetry`, `pre-commit`
- Go (official tarball install)
- Rust (`rustup`, `cargo`, `rustc`)
- Dev/system tools: `git`, Docker client tooling (`docker`, `docker buildx`, Compose v2 via both `docker compose` and `docker-compose`), `iptables`, `fzf`, `rg`, `fd`, `jq`, `yq`, `cloc`, `sloccount`, `hyperfine`, `wrk`, `ab`, `hey`, `ghz`, `grpcurl`, `httpie`, `xh`, `curlie`, `wget`, `aria2`, `entr`, `ncdu`, `tmux`, `shellcheck`, `shfmt`, and more
- Cloud/Kubernetes CLIs: `gcloud`, `gke-gcloud-auth-plugin`, `kubectl`, `kubectx`, `kubens`
- AI CLIs: `codex`, `claude`, `gemini`, `opencode`, `forge` (ForgeCode), and Cursor Agent as `cursor` (`agent`/`cursor-agent` aliases)
- Workspace CLIs: `ralph`, `openclaw`, `kimaki`, and `@googleworkspace/cli`
- `codex` wrapper and `codex-real`

The `codex` wrapper is preserved as:
- `/usr/local/bin/codex` -> runs `codex-real` with Docker-only guard and `--dangerously-bypass-approvals-and-sandbox`
- `/usr/local/bin/codex-real` -> original binary from npm install

The `claude` wrapper is preserved as:
- `/usr/local/bin/claude` -> runs `claude-real` with Docker-only guard and `--dangerously-skip-permissions`
- `/usr/local/bin/claude-real` -> original binary from npm install

`forge` (ForgeCode) is installed as a direct binary from the upstream release — no wrapper needed since ForgeCode runs unrestricted by default. Provider credentials are passed in via the host's `~/forge/` directory.

`opencode` is also baked into the image as a first-class CLI via the upstream `opencode-ai` package, so you can invoke `opencode` directly inside the container.

`kimaki` is also baked into the image as a first-class CLI. Upstream documents `npx -y kimaki@latest` for first run; inside this image you can invoke `kimaki` directly.

## Prerequisites

On the host machine:
- Docker Engine running
- Access to `/var/run/docker.sock` when you want the container to control the host Docker daemon

The image ships client-side Docker tooling only. It is intended to talk to a mounted host Docker socket, not to run `dockerd` inside the container.

## Quick Start

1. Build the image:

```bash
docker build -t toolbelt:latest .
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
  toolbelt:latest
```

Common variants:
- Omit `/var/run/docker.sock` when you do not need host Docker control.
- Use `-e OPENAI_API_KEY` instead of auth/config mounts for isolated API-key sessions.

3. Verify core tooling:

```bash
command -v node npm pnpm python3 pip3 uv poetry go rustc cargo \
  fzf rg fd jq yq cloc sloccount hyperfine wrk ab hey ghz grpcurl http xh curlie wget aria2c entr ncdu \
  gcloud gke-gcloud-auth-plugin kubectl kubectx kubens docker docker-compose iptables \
  codex codex-real claude claude-real forge gemini opencode cursor agent cursor-agent openclaw kimaki
```

## Selective Mount Workflow

Use `scripts/toolbelt.sh` when you want to mount only selected folders/files instead of an entire project tree.

```bash
# Mount current directory to /workspace with Codex credentials
scripts/toolbelt.sh codex

# Mount current directory with Claude credentials (requires ANTHROPIC_API_KEY)
scripts/toolbelt.sh claude

# Mount current directory with ForgeCode credentials (mounts ~/forge/)
scripts/toolbelt.sh forge

# Mount current directory with Claude + ForgeCode side-by-side
scripts/toolbelt.sh claude -forge

# Mount only selected paths under /workspace/<basename>
scripts/toolbelt.sh codex ./directory1 ./directory2

# Add host Docker access only when needed
scripts/toolbelt.sh codex -docker ../directory1 ../directory2

# Add Google Workspace, Kimaki, and Kubernetes state when needed
scripts/toolbelt.sh codex -gws -kimaki -k8s ./directory1 ./directory2

# Require host OpenCode config to be present for this run
scripts/toolbelt.sh codex -opencode ./directory1 ./directory2

# Run a command instead of an interactive shell
scripts/toolbelt.sh claude -k8s ./directory1 -- bash -lc 'ls -la /workspace'
```

Behavior summary:
- A provider subcommand (`codex`, `claude`, or `forge`) is required as the first argument.
- If no positional paths are provided, the current directory is mounted at `/workspace`.
- Each positional path becomes one mount at `/workspace/<basename(path)>`.
- Docker socket is opt-in via `-docker` / `--docker`.
- `codex` provider: `/root/.codex` is mounted as tmpfs (`512m` default); `~/.codex/auth.json` and `~/.codex/config.toml` are mounted read-only when present.
- `claude` provider: `~/.claude/` is mounted read-only to `/run/secrets/claude-config`; `ANTHROPIC_API_KEY` is passed through when set on the host.
- `forge` provider: `~/forge/` is mounted read-only to `/run/secrets/forge-config`; entrypoint hydrates `/home/coder/.forge/`.
- `-forge` / `--forge` (claude provider only): co-mounts ForgeCode config alongside Claude config so both CLIs are available with credentials in the same session.
- `-gcloud` / `--gcloud` mounts host `~/.config/gcloud` read-only to `/run/secrets/gcloud-config`; entrypoint hydrates `/root/.config/gcloud`.
- `-gws` / `--gws` mounts host `~/.config/gws`, exports portable host `gws` credentials when available, and sets `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/run/secrets/gws-credentials/credentials.json` inside the container.
- `-gws` / `--gws` still hydrates `~/.config/gws` for compatibility and uses ADC as fallback when exported credentials are unavailable.
- Host `~/.config/opencode` is passed in automatically when present as read-only runtime input at `/run/secrets/opencode-config`; entrypoint hydrates `/root/.config/opencode` so the same authorized providers are visible inside the container.
- `-opencode` / `--opencode` makes that OpenCode import required and fails fast when `~/.config/opencode` (or `TOOLBELT_OPENCODE_CONFIG_SRC`) is unavailable.
- `-kimaki` / `--kimaki` mounts host `~/.kimaki` read-write to `/root/.kimaki` and implicitly enables the same required OpenCode import.
- OpenCode config hydration is one-way for the session: host config seeds container runtime state, but container-side changes do not write back to the host automatically.
- Current status: direct `gws` support in the container is still experimental/incomplete; the scope-guard flow below improves diagnostics but is not yet treated as a fully validated end-to-end path.
- Direct `gws <service> <resource> <method>` commands launched through `scripts/toolbelt.sh -gws -- ...` now attempt a host-side scope preflight; confirmed scope mismatches fail before `docker run` with a re-auth hint such as `gws auth login -s drive`.
- Shell-wrapped launcher commands such as `-- bash -lc 'gws ...'` intentionally skip host-side scope preflight because the launcher cannot infer the eventual `gws` method safely.
- After rebuilding the image, the container entrypoint also installs an experimental `gws` wrapper that preflights direct in-container `gws <service> <resource> <method>` calls and appends a scope hint if a raw `403 insufficientPermissions` still bubbles up.
- `-k8s` / `--k8s` mounts host `~/.kube/config` read-only to `/run/secrets/kube-config`; entrypoint hydrates `/root/.kube/config`.
- Override credential source paths with `TOOLBELT_CLAUDE_DIR_SRC`, `TOOLBELT_FORGE_DIR_SRC`, `TOOLBELT_GCLOUD_CONFIG_SRC`, `TOOLBELT_GWS_CONFIG_SRC`, `TOOLBELT_OPENCODE_CONFIG_SRC`, `TOOLBELT_KIMAKI_CONFIG_SRC`, and `TOOLBELT_KUBECONFIG_SRC`.

Troubleshooting:
- `401` or `No credentials provided` means the launcher could not export or hydrate usable credentials.
- A fast launcher failure naming required/granted scopes means the host `gws` login is missing consent for that API.
- A `403 insufficientPermissions` returned from inside the container still means the OAuth grant is under-scoped; re-run `gws auth login -s <service>` on the host and retry.
- Even when the guardrails fire correctly, treat direct in-container `gws` usage as incomplete until it has been proven against a real auth flow in a rebuilt image.

## Interactive Container Behavior

At startup, the entrypoint bootstraps auth/config homes for the selected provider and prints a short MOTD listing available commands and baked scripts.

## Voice STT

The image includes a built-in Whisper STT runtime for OpenClaw media inbox workflows.

Included by default:
- `ffmpeg`
- Python runtime at `/opt/voice-stt` with `faster-whisper`
- `voice-stt-start`
- `voice-stt-stop`
- `voice-stt-once <audio-file>`

## Image-Baked Scripts

The image bakes every `scripts/*.sh` file from this repo into `/opt/toolbelt/scripts/`. After the coordinator extraction, that set is limited to toolbelt-owned helpers such as:
- `scripts/toolbelt.sh`
- `scripts/gws-scope-guard.sh`
- `scripts/verify_gws_scope_guard_contract.sh`
- `scripts/verify_toolbelt_kimaki_contract.sh`
- `scripts/verify_toolbelt_opencode_contract.sh`
- `scripts/verify_toolbelt_opencode_runtime_contract.sh`
- `scripts/verify_toolbelt_gws_scope_contract.sh`
- `scripts/voice-stt-start.sh`
- `scripts/voice-stt-stop.sh`
- `scripts/voice-stt-once.sh`

## Verification

For contract verification without rebuilding the image:

```bash
./scripts/verify_toolbelt_kimaki_contract.sh
./scripts/verify_toolbelt_opencode_contract.sh
./scripts/verify_toolbelt_opencode_runtime_contract.sh
```

After image changes, run:

```bash
docker build -t toolbelt:latest .
docker run --rm toolbelt:latest bash -lc 'command -v node npm pnpm python3 pip3 uv poetry go rustc cargo rg fd jq yq http xh curlie codex codex-real claude-real forge opencode kimaki docker docker-compose iptables && docker compose version && docker-compose --version && docker buildx version'
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock toolbelt:latest bash -lc 'docker ps >/dev/null && docker compose version >/dev/null && docker-compose --version >/dev/null && docker buildx version >/dev/null'
docker run --rm toolbelt:latest bash -c 'python3 -m venv /tmp/venv && /tmp/venv/bin/python -V && node -e "console.log(\"ok\")" && printf "package main\nfunc main(){}\n" >/tmp/main.go && go run /tmp/main.go && cargo new /tmp/rtest >/dev/null && cd /tmp/rtest && cargo check >/dev/null'
```

## Repository Layout

```text
toolbelt/
├── CHANGELOG.md
├── Dockerfile
├── README.md
├── AGENTS.md
├── container/
│   └── toolbelt-entrypoint.sh
└── scripts/
    ├── gws-scope-guard.sh
    ├── toolbelt.sh
    ├── verify_gws_scope_guard_contract.sh
    ├── verify_toolbelt_gws_scope_contract.sh
    ├── verify_toolbelt_kimaki_contract.sh
    ├── verify_toolbelt_opencode_contract.sh
    ├── verify_toolbelt_opencode_runtime_contract.sh
    ├── voice-stt-start.sh
    ├── voice-stt-stop.sh
    ├── voice-stt-once.sh
    └── voice_autotranscribe.py
```
