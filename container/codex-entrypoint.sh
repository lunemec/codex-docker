#!/usr/bin/env bash
set -euo pipefail

show_motd() {
  [[ "${CODEX_SHOW_MOTD:-1}" == "1" ]] || return 0
  [[ -t 1 ]] || return 0

  # Only show MOTD for interactive shell-style sessions.
  if [[ $# -gt 0 ]]; then
    case "$(basename "$1")" in
      bash|sh|zsh|fish) ;;
      *)
        return 0
        ;;
    esac
  fi

  cat <<'MOTD'
Codex dev container ready.

Quick commands:
  codex-init-workspace --workspace /workspace
    Seed /workspace/scripts and /workspace/coordination from the image baseline.

  scripts/coordination_repair.sh
    Backfill missing coordination folders/prompts and ensure core agent lanes.

  scripts/agents_ctl.sh start
    Start background coordination workers after bootstrap.

  ralph
    Launch Ralph CLI.

  codex
    Launch Codex CLI (Docker-guarded wrapper).

  codex "$(cat /workspace/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md)"
    Launch Codex preloaded with the top-level pm/coordinator prompt.
MOTD
}

show_motd "$@"

exec "$@"
