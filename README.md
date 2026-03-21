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
- AI CLIs: `codex`, `claude`, `gemini`, and Cursor Agent as `cursor` (`agent`/`cursor-agent` aliases)
- Workspace CLIs: `ralph`, `openclaw`, and `@googleworkspace/cli`
- `codex` wrapper and `codex-real`

The `codex` wrapper is preserved as:
- `/usr/local/bin/codex` -> runs `codex-real` with Docker-only guard and bypass flags
- `/usr/local/bin/codex-real` -> original binary from npm install

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
  codex codex-real claude gemini cursor agent cursor-agent openclaw
```

## Selective Mount Workflow

Use `scripts/toolbelt.sh` when you want to mount only selected folders/files instead of an entire project tree.

```bash
# Mount current directory to /workspace
scripts/toolbelt.sh

# Mount only selected paths under /workspace/<basename>
scripts/toolbelt.sh ./directory1 ./directory2

# Add host Docker access only when needed
scripts/toolbelt.sh -docker ../directory1 ../directory2

# Add Google Workspace and Kubernetes auth when needed
scripts/toolbelt.sh -gws -k8s ./directory1 ./directory2

# Run a command instead of an interactive shell
scripts/toolbelt.sh ./directory1 ./directory2 -- bash -lc 'ls -la /workspace'
```

Behavior summary:
- If no positional paths are provided, the current directory is mounted at `/workspace`.
- Each positional path becomes one mount at `/workspace/<basename(path)>`.
- Docker socket is opt-in via `-docker` / `--docker`.
- `/root/.codex` is mounted as tmpfs (`512m` default).
- `~/.codex/auth.json` and `~/.codex/config.toml` are mounted read-only automatically when present.
- `-gcloud` / `--gcloud` mounts host `~/.config/gcloud` read-only to `/run/secrets/gcloud-config`; entrypoint hydrates `/root/.config/gcloud`.
- `-gws` / `--gws` mounts host `~/.config/gws`, exports portable host `gws` credentials when available, and sets `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/run/secrets/gws-credentials/credentials.json` inside the container.
- `-gws` / `--gws` still hydrates `~/.config/gws` for compatibility and uses ADC as fallback when exported credentials are unavailable.
- Current status: direct `gws` support in the container is still experimental/incomplete; the scope-guard flow below improves diagnostics but is not yet treated as a fully validated end-to-end path.
- Direct `gws <service> <resource> <method>` commands launched through `scripts/toolbelt.sh -gws -- ...` now attempt a host-side scope preflight; confirmed scope mismatches fail before `docker run` with a re-auth hint such as `gws auth login -s drive`.
- Shell-wrapped launcher commands such as `-- bash -lc 'gws ...'` intentionally skip host-side scope preflight because the launcher cannot infer the eventual `gws` method safely.
- After rebuilding the image, the container entrypoint also installs an experimental `gws` wrapper that preflights direct in-container `gws <service> <resource> <method>` calls and appends a scope hint if a raw `403 insufficientPermissions` still bubbles up.
- `-k8s` / `--k8s` mounts host `~/.kube/config` read-only to `/run/secrets/kube-config`; entrypoint hydrates `/root/.kube/config`.
- Override credential source paths with `CODEX_GCLOUD_CONFIG_SRC`, `CODEX_GWS_CONFIG_SRC`, and `CODEX_KUBECONFIG_SRC`.

Troubleshooting:
- `401` or `No credentials provided` means the launcher could not export or hydrate usable credentials.
- A fast launcher failure naming required/granted scopes means the host `gws` login is missing consent for that API.
- A `403 insufficientPermissions` returned from inside the container still means the OAuth grant is under-scoped; re-run `gws auth login -s <service>` on the host and retry.
- Even when the guardrails fire correctly, treat direct in-container `gws` usage as incomplete until it has been proven against a real auth flow in a rebuilt image.

## Coordinator Split

Coordinator assets are no longer baked into the image and are no longer maintained in this repository.

- Canonical coordinator path inside the container: `/workspace/coordinator`
- Current status for this phase: hard cutover is complete; `toolbelt` only references the external coordinator checkout
- `codex-init-workspace` remains installed only as a compatibility redirect and never seeds or repairs coordinator assets
- With `scripts/toolbelt.sh`, a host path whose basename is `coordinator` mounts to `/workspace/coordinator`

If you need the coordinator inside this container, mount or clone the standalone repo so it appears at `/workspace/coordinator`, then run it directly from there.

## Interactive Container Behavior

At startup, the entrypoint still bootstraps auth/config homes and prints a short MOTD. The MOTD only points at the external coordinator checkout when `/workspace/coordinator` is present in the mounted workspace; otherwise it states that coordinator assets are not embedded in the image and tells you to mount or clone the standalone repo there.

## Voice STT

The image includes a built-in Whisper STT runtime for OpenClaw media inbox workflows.

Included by default:
- `ffmpeg`
- Python runtime at `/opt/voice-stt` with `faster-whisper`
- `voice-stt-start`
- `voice-stt-stop`
- `voice-stt-once <audio-file>`

## Image-Baked Scripts

The image still bakes every remaining `scripts/*.sh` file from this repo into `/opt/codex-baseline/scripts/`. After the coordinator extraction, that set is limited to toolbelt-owned helpers such as:
- `scripts/toolbelt.sh`
- `scripts/gws-scope-guard.sh`
- `scripts/verify_gws_scope_guard_contract.sh`
- `scripts/verify_toolbelt_gws_scope_contract.sh`
- `scripts/voice-stt-start.sh`
- `scripts/voice-stt-stop.sh`
- `scripts/voice-stt-once.sh`

## Verification

For coordinator-boundary changes that do not touch `Dockerfile`, run:

```bash
./scripts/verify_toolbelt_coordinator_boundary_contract.sh
```

After image changes, run:

```bash
docker build -t toolbelt:latest .
docker run --rm toolbelt:latest bash -lc 'command -v node npm pnpm python3 pip3 uv poetry go rustc cargo rg fd jq yq http xh curlie codex codex-real docker docker-compose iptables && docker compose version && docker-compose --version && docker buildx version'
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
│   ├── codex-entrypoint.sh
│   └── codex-init-workspace.sh
└── scripts/
    ├── gws-scope-guard.sh
    ├── toolbelt.sh
    ├── verify_gws_scope_guard_contract.sh
    ├── verify_toolbelt_coordinator_boundary_contract.sh
    ├── verify_toolbelt_coordinator_inventory_contract.sh
    ├── verify_toolbelt_gws_scope_contract.sh
    ├── voice-stt-start.sh
    ├── voice-stt-stop.sh
    ├── voice-stt-once.sh
    └── voice_autotranscribe.py
```
