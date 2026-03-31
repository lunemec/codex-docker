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
- `container/toolbelt-entrypoint.sh`: interactive MOTD and runtime bootstrap.
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
- Claude Code is not wrapped (root restriction prevents `--dangerously-skip-permissions`).
- Always tag the runtime image as `toolbelt:latest` unless the user explicitly requests otherwise.
- Prefer official toolchain installs for Go and Rust unless directed otherwise.
- Use `--no-install-recommends` for apt installs and clean apt lists after installs.
- Keep PATH behavior working in both non-login and login shells.
- Keep all remaining `scripts/*.sh` baked into `/opt/toolbelt/scripts/` via wildcard copy.
- Keep startup MOTD listings aligned with the scripts actually baked into the image.
- Update `README.md` and `CHANGELOG.md` whenever behavior or scope changes.

## Out of Scope Unless Asked
- Rebuilding coordinator integration before the standalone coordinator repository is published and versioned.
- Multi-stage image optimization.
- Non-Debian base image migration.
- CI or publish automation changes.

# context-mode — MANDATORY routing rules

You have context-mode MCP tools available. These rules are NOT optional — they protect your context window from flooding. A single unrouted command can dump 56 KB into context and waste the entire session.

## BLOCKED commands — do NOT attempt these

### curl / wget — BLOCKED
Any shell command containing `curl` or `wget` will be intercepted and blocked by the context-mode plugin. Do NOT retry.
Instead use:
- `context-mode_ctx_fetch_and_index(url, source)` to fetch and index web pages
- `context-mode_ctx_execute(language: "javascript", code: "const r = await fetch(...)")` to run HTTP calls in sandbox

### Inline HTTP — BLOCKED
Any shell command containing `fetch('http`, `requests.get(`, `requests.post(`, `http.get(`, or `http.request(` will be intercepted and blocked. Do NOT retry with shell.
Instead use:
- `context-mode_ctx_execute(language, code)` to run HTTP calls in sandbox — only stdout enters context

### Direct web fetching — BLOCKED
Do NOT use any direct URL fetching tool. Use the sandbox equivalent.
Instead use:
- `context-mode_ctx_fetch_and_index(url, source)` then `context-mode_ctx_search(queries)` to query the indexed content

## REDIRECTED tools — use sandbox equivalents

### Shell (>20 lines output)
Shell is ONLY for: `git`, `mkdir`, `rm`, `mv`, `cd`, `ls`, `npm install`, `pip install`, and other short-output commands.
For everything else, use:
- `context-mode_ctx_batch_execute(commands, queries)` — run multiple commands + search in ONE call
- `context-mode_ctx_execute(language: "shell", code: "...")` — run in sandbox, only stdout enters context

### File reading (for analysis)
If you are reading a file to **edit** it → reading is correct (edit needs content in context).
If you are reading to **analyze, explore, or summarize** → use `context-mode_ctx_execute_file(path, language, code)` instead. Only your printed summary enters context.

### grep / search (large results)
Search results can flood context. Use `context-mode_ctx_execute(language: "shell", code: "grep ...")` to run searches in sandbox. Only your printed summary enters context.

## Tool selection hierarchy

1. **GATHER**: `context-mode_ctx_batch_execute(commands, queries)` — Primary tool. Runs all commands, auto-indexes output, returns search results. ONE call replaces 30+ individual calls.
2. **FOLLOW-UP**: `context-mode_ctx_search(queries: ["q1", "q2", ...])` — Query indexed content. Pass ALL questions as array in ONE call.
3. **PROCESSING**: `context-mode_ctx_execute(language, code)` | `context-mode_ctx_execute_file(path, language, code)` — Sandbox execution. Only stdout enters context.
4. **WEB**: `context-mode_ctx_fetch_and_index(url, source)` then `context-mode_ctx_search(queries)` — Fetch, chunk, index, query. Raw HTML never enters context.
5. **INDEX**: `context-mode_ctx_index(content, source)` — Store content in FTS5 knowledge base for later search.

## Output constraints

- Keep responses under 500 words.
- Write artifacts (code, configs, PRDs) to FILES — never return them as inline text. Return only: file path + 1-line description.
- When indexing content, use descriptive source labels so others can `search(source: "label")` later.

## ctx commands

| Command | Action |
|---------|--------|
| `ctx stats` | Call the `stats` MCP tool and display the full output verbatim |
| `ctx doctor` | Call the `doctor` MCP tool, run the returned shell command, display as checklist |
| `ctx upgrade` | Call the `upgrade` MCP tool, run the returned shell command, display as checklist |
