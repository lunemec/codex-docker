# AGENTS.md

## Project Purpose
This repository defines a Codex-focused developer Docker image (`Dockerfile.codex-dev`) used for coding, review, and general software development workflows.

## Primary File
- `Dockerfile.codex-dev`: single source of truth for the development image.
- `CHANGELOG.md`: record of notable project changes.

## Agent Goals
When working in this repo, prioritize:
1. Keeping the image broadly useful for common Python, Go, Rust, and Node.js workflows.
2. Preserving deterministic, reproducible Docker builds.
3. Verifying changes with real Docker build + runtime smoke checks.

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

## Out of Scope Unless Asked
- Multi-stage optimization or aggressive image-size reduction.
- Non-Debian base image migration.
- CI pipeline or publish automation changes.

## Notes
- Expected base distribution is Debian Bookworm via `node:22-bookworm`.
- `bash -lc` must continue resolving Go/Rust/Python CLI tools via profile path setup.
