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
- Testing: `playwright` (Chromium, via `@playwright/test`)
- Cloud/Kubernetes CLIs: `gcloud`, `gke-gcloud-auth-plugin`, `kubectl`, `kubectx`, `kubens`
- Git platform CLIs: `gh` (GitHub CLI), `glab` (GitLab CLI) — token-based auth, no host config mounting
- AI CLIs: `codex`, `claude`, `gemini`, `opencode`, `forge` (ForgeCode), and Cursor Agent as `cursor` (`agent`/`cursor-agent` aliases)
- Workspace CLIs: `ralph`, `openclaw`, `kimaki`, and `@googleworkspace/cli`
- MCP tools: `context-mode` (context window management for AI agents)
- Runtime: `bun` + `bunx` (latest release)
- Memory: `mempalace` CLI + `mempalace-mcp` wrapper (semantic memory palace, auto-mounted from host when `~/.mempalace` exists)
- Agent frameworks: `archon` CLI (Archon agent framework, skills pre-installed at `~/.claude/skills/archon`)
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
- Access to `/var/run/docker.sock` when you want the container to control the host Docker daemon; `scripts/toolbelt.sh -docker` now aligns the in-container `coder` user to the invoking host UID/GID and the socket group so `docker` works without `sudo`

The image ships client-side Docker tooling only. It is intended to talk to a mounted host Docker socket, not to run `dockerd` inside the container.

## Quick Start

1. Build the image:

```bash
docker build -t toolbelt:latest .
```

2. Run an interactive container with your current repository, mounted auth/config inputs, and optional host Docker access:

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -w /workspace \
  -v "$HOME/.codex:/run/secrets/codex-config:ro" \
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
  codex codex-real claude claude-real forge gemini opencode cursor agent cursor-agent openclaw kimaki \
  gh glab context-mode && npx playwright --version
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

### SSH Keys

The `-ssh` flag mounts project-scoped SSH keys into the container. It is **opt-in** — keys are never mounted automatically.

Discovery: when `-ssh` is passed, the launcher scans each mounted directory for `.toolbelt/ssh/id_ed25519`. The first match wins. If `-ssh` is requested but no key is found, the launcher exits with an error.

```bash
# Project layout:
# ./my-project/.toolbelt/ssh/id_ed25519
# ./my-project/.toolbelt/ssh/id_ed25519.pub

scripts/toolbelt.sh codex -ssh ./my-project
```

The entrypoint installs the key into `/home/coder/.ssh/` and pre-seeds `known_hosts` for GitLab.

### Mempalace

[Mempalace](https://github.com/milla-jovovich/mempalace) is a semantic memory palace backed by ChromaDB and a knowledge graph. When `~/.mempalace` exists on the host it is **auto-detected and mounted read-write** into the container at the same absolute path (so the database is shared with the host and persists across container restarts).

The ChromaDB ONNX model cache (`~/.cache/chroma`) is also mounted so the 80 MB model is downloaded once and reused.

On container startup `bootstrap_mempalace` registers the MCP server in `~/.claude.json` so Claude Code can use mempalace tools immediately:

```
mempalace_search, mempalace_add_drawer, mempalace_kg_query, mempalace_diary_write, …
```

**Host setup** — install a wrapper so the shared `~/.claude.json` entry works on the host too:

```bash
sudo tee /usr/local/bin/mempalace-mcp <<'EOF'
#!/usr/bin/env bash
exec python3.11 -m mempalace.mcp_server --palace "${HOME}/.mempalace/palace" "$@"
EOF
sudo chmod +x /usr/local/bin/mempalace-mcp
```

Replace `python3.11` with whichever Python has mempalace installed (`pip show mempalace` to check). Install the GitHub version for MCP support:

```bash
pip install "git+https://github.com/milla-jovovich/mempalace.git"
```

No flags are needed — mempalace is enabled automatically when `~/.mempalace` is present.

### GitHub and GitLab CLI Access

The `-github` and `-gitlab` flags provide token-based authentication for `gh` and `glab` inside the container. No host config directories are mounted — only the token is passed as an environment variable, keeping agent access scoped to exactly the permissions you grant.

Token resolution order (highest priority first):

1. **Inline flag value**: `-github "ghp_xxx"` / `-gitlab "glpat-xxx"`
2. **Environment variable**: `GITHUB_TOKEN` (or `GH_TOKEN`) / `GITLAB_TOKEN` (or `GLAB_TOKEN`)
3. **Project `.toolbelt.env` file**: auto-discovered in the mounted project directory

```bash
# Inline tokens
scripts/toolbelt.sh codex -github "ghp_xxx" -gitlab "glpat-xxx" ./my-project

# Environment variables (works well with direnv)
GITHUB_TOKEN=ghp_xxx GITLAB_TOKEN=glpat-xxx scripts/toolbelt.sh codex -github -gitlab ./my-project

# Per-project .toolbelt.env file (add to .gitignore!)
# ./my-project/.toolbelt.env:
#   GITHUB_TOKEN=ghp_xxx
#   GITLAB_TOKEN=glpat-xxx
scripts/toolbelt.sh codex -github -gitlab ./my-project
```

The `.toolbelt.env` file uses simple `KEY=VALUE` format (one per line, `#` comments supported). Only `GITHUB_TOKEN` and `GITLAB_TOKEN` keys are read. Add `.toolbelt.env` to your `.gitignore` to avoid committing tokens.

**Generating a limited-scope GitLab token:**

1. Go to GitLab > Settings > Access Tokens (`https://gitlab.com/-/user_settings/personal_access_tokens`)
2. Create a token named e.g. `toolbelt-agent` with an expiration date
3. Select minimal scopes: `read_api` for read-only access, add `read_repository` for clone/fetch, or `api` for full access
4. Copy the `glpat-...` value

**Generating a limited-scope GitHub token:**

1. Go to GitHub > Settings > Developer settings > Fine-grained tokens (`https://github.com/settings/tokens?type=beta`)
2. Create a token named e.g. `toolbelt-agent` with an expiration date
3. Scope it to specific repositories and select only the permissions agents need (e.g. Issues: read, Pull requests: read)
4. Copy the `github_pat_...` or `ghp_...` value

Behavior summary:
- A provider subcommand (`codex`, `claude`, or `forge`) is required as the first argument.
- If no positional paths are provided, the current directory is mounted at `/workspace`.
- Each positional path becomes one mount at `/workspace/<basename(path)>`.
- Docker socket is opt-in via `-docker` / `--docker`, and the launcher/entrypoint now align `coder` to the invoking host UID/GID plus the mounted socket group so `docker` works without `sudo` in the container, including macOS runtimes where the host-reported socket GID differs from the in-container bind mount.
- `codex` provider: `~/.codex/` is mounted read-only to `/run/secrets/codex-config`; entrypoint hydrates `$CODER_HOME/.codex/`.
- `claude` provider: `~/.claude/` is mounted read-only to `/run/secrets/claude-config`; `ANTHROPIC_API_KEY` is passed through when set on the host.
- `forge` provider: `~/forge/` is mounted read-only to `/run/secrets/forge-config`; entrypoint hydrates `/home/coder/.forge/`.
- Writable direct host mounts such as workspace paths and `-kimaki` now inherit the invoking host UID/GID via the entrypoint so routine writes do not require `sudo`.
- `-forge` / `--forge` (claude provider only): co-mounts ForgeCode config alongside Claude config so both CLIs are available with credentials in the same session.
- `-gcloud` / `--gcloud` mounts host `~/.config/gcloud` read-only to `/run/secrets/gcloud-config`; entrypoint hydrates `/root/.config/gcloud`.
- `-gws` / `--gws` mounts host `~/.config/gws`, exports portable host `gws` credentials when available, and sets `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` to the writable hydrated copy inside the container.
- `-gws` / `--gws` still hydrates `~/.config/gws` for compatibility and uses ADC as fallback when exported credentials are unavailable.
- `-opencode` / `--opencode` mounts host `~/.config/opencode` as read-only runtime input at `/run/secrets/opencode-config`; entrypoint hydrates `/root/.config/opencode` so the same authorized providers are visible inside the container.
- `-opencode` / `--opencode` fails fast when `~/.config/opencode` (or `TOOLBELT_OPENCODE_CONFIG_SRC`) is unavailable.
- `-kimaki` / `--kimaki` mounts host `~/.kimaki` read-write to `/home/coder/.kimaki` and implicitly enables the required OpenCode import.
- OpenCode config hydration is one-way for the session: when imported, host config seeds container runtime state, but container-side changes do not write back to the host automatically.
- Current status: direct `gws` support in the container is still experimental/incomplete; the scope-guard flow below improves diagnostics but is not yet treated as a fully validated end-to-end path.
- Direct `gws <service> <resource> <method>` commands launched through `scripts/toolbelt.sh -gws -- ...` now attempt a host-side scope preflight; confirmed scope mismatches fail before `docker run` with a re-auth hint such as `gws auth login -s drive`.
- Shell-wrapped launcher commands such as `-- bash -lc 'gws ...'` intentionally skip host-side scope preflight because the launcher cannot infer the eventual `gws` method safely.
- After rebuilding the image, the container entrypoint also installs an experimental `gws` wrapper that preflights direct in-container `gws <service> <resource> <method>` calls and appends a scope hint if a raw `403 insufficientPermissions` still bubbles up.
- `-k8s` / `--k8s` mounts host `~/.kube/config` read-only to `/run/secrets/kube-config`; entrypoint hydrates `/root/.kube/config`.
- `-github` / `--github` and `-gitlab` / `--gitlab` pass `GITHUB_TOKEN` / `GITLAB_TOKEN` into the container as environment variables **only when the flag is explicitly passed**. No host config directories are mounted. Tokens are resolved from inline flag values, host env vars, or a `.toolbelt.env` file in the project directory.
- `-ssh` / `--ssh` (opt-in) scans mounted directories for `.toolbelt/ssh/id_ed25519` and mounts it read-only; fails fast if the flag is passed but no key is found.
- Mempalace is auto-enabled (no flag needed) when `~/.mempalace` exists on the host; the database is mounted read-write and the ONNX model cache is mounted to avoid re-downloading the 80 MB model.
- Override credential source paths with `TOOLBELT_CLAUDE_DIR_SRC`, `TOOLBELT_FORGE_DIR_SRC`, `TOOLBELT_GCLOUD_CONFIG_SRC`, `TOOLBELT_GWS_CONFIG_SRC`, `TOOLBELT_OPENCODE_CONFIG_SRC`, `TOOLBELT_KIMAKI_CONFIG_SRC`, and `TOOLBELT_KUBECONFIG_SRC`.

Troubleshooting:
- `401` or `No credentials provided` means the launcher could not export or hydrate usable credentials.
- A fast launcher failure naming required/granted scopes means the host `gws` login is missing consent for that API.
- A `403 insufficientPermissions` returned from inside the container still means the OAuth grant is under-scoped; re-run `gws auth login -s <service>` on the host and retry.
- Even when the guardrails fire correctly, treat direct in-container `gws` usage as incomplete until it has been proven against a real auth flow in a rebuilt image.

## Interactive Container Behavior

At startup, the entrypoint bootstraps auth/config homes for the selected provider and prints a short MOTD with workspace mounts and enabled session features.

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
- `scripts/verify_toolbelt_claude_contract.sh`
- `scripts/verify_toolbelt_docker_contract.sh`
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
./scripts/verify_toolbelt_claude_contract.sh
./scripts/verify_toolbelt_docker_contract.sh
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
    ├── verify_toolbelt_claude_contract.sh
    ├── verify_toolbelt_docker_contract.sh
    ├── verify_toolbelt_gws_scope_contract.sh
    ├── verify_toolbelt_kimaki_contract.sh
    ├── verify_toolbelt_opencode_contract.sh
    ├── verify_toolbelt_opencode_runtime_contract.sh
    ├── voice-stt-start.sh
    ├── voice-stt-stop.sh
    ├── voice-stt-once.sh
    └── voice_autotranscribe.py
```
