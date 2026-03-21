# AGENTS.md

## Project Purpose
This repository owns the `toolbelt` development image and its host-side launcher workflow.

The standalone coordinator has been extracted out of this repo. Do not reintroduce coordinator source-of-truth files here unless the user explicitly asks for a new integration design.

## Primary Files
- `Dockerfile`: single source of truth for the development image.
- `README.md`: user-facing usage and scope.
- `CHANGELOG.md`: notable behavior changes.
- `scripts/toolbelt.sh`: host-side launcher for selective mounts into `/workspace/<basename>`.
- `scripts/gws-scope-guard.sh`: experimental in-container `gws` scope diagnosis wrapper.
- `scripts/verify_gws_scope_guard_contract.sh` and `scripts/verify_toolbelt_gws_scope_contract.sh`: GWS scope guard contract verifiers.
- `container/codex-entrypoint.sh`: interactive MOTD and runtime bootstrap.
- `container/codex-init-workspace.sh`: deprecated compatibility stub; no longer seeds coordinator assets.
- `scripts/voice-stt-*.sh` and `scripts/voice_autotranscribe.py`: voice STT helpers baked into the image.

## Agent Goals
1. Keep the image broadly useful for common Python, Node.js, Go, and Rust workflows.
2. Preserve deterministic, reproducible Docker builds.
3. Keep Docker access client-only via a mounted host socket.
4. Keep the repo honest about the coordinator split: the image no longer ships coordinator assets.

## Required Validation After Dockerfile Changes
After any edit to `Dockerfile`, run:
1. `docker build -t toolbelt:latest .`
2. `docker run --rm toolbelt:latest bash -lc 'command -v node npm pnpm python3 pip3 uv poetry go rustc cargo rg fd jq yq http xh curlie codex codex-real docker docker-compose iptables && docker compose version && docker-compose --version && docker buildx version'`
3. `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock toolbelt:latest bash -lc 'docker ps >/dev/null && docker compose version >/dev/null && docker-compose --version >/dev/null && docker buildx version >/dev/null'`
4. `docker run --rm toolbelt:latest bash -c 'python3 -m venv /tmp/venv && /tmp/venv/bin/python -V && node -e "console.log(\"ok\")" && printf "package main\nfunc main(){}\n" >/tmp/main.go && go run /tmp/main.go && cargo new /tmp/rtest >/dev/null && cd /tmp/rtest && cargo check >/dev/null'`

## Change Guidelines
- Keep the Codex wrapper behavior intact (`/usr/local/bin/codex` invoking `codex-real` with Docker guard).
- Always tag the runtime image as `toolbelt:latest` unless the user explicitly requests otherwise.
- Prefer official toolchain installs for Go and Rust unless directed otherwise.
- Use `--no-install-recommends` for apt installs and clean apt lists after installs.
- Keep PATH behavior working in both non-login and login shells.
- Keep all remaining `scripts/*.sh` baked into `/opt/codex-baseline/scripts/` via wildcard copy.
- Keep startup MOTD listings aligned with the scripts actually baked into the image.
- Update `README.md` and `CHANGELOG.md` whenever behavior or scope changes.

## Out of Scope Unless Asked
- Rebuilding coordinator integration before the standalone coordinator repository is published and versioned.
- Multi-stage image optimization.
- Non-Debian base image migration.
- CI or publish automation changes.
