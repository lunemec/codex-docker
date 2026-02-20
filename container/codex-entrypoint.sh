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

Image-baked scripts (available even when /workspace is a fresh mount):
  /opt/codex-baseline/scripts/taskctl.sh
    Task lifecycle helper (create/delegate/claim/done/block/ensure-agent).

  /opt/codex-baseline/scripts/agent_worker.sh
    Specialist polling worker script (typically launched via agents_ctl).

  /opt/codex-baseline/scripts/agents_ctl.sh
    Start/stop/status/once controller for specialist workers.

  /opt/codex-baseline/scripts/coordination_repair.sh
    Backfill missing coordination folders/prompts and ensure core agent lanes.

  /opt/codex-baseline/scripts/project_container.sh
    Project container launcher script (primarily for host-side use).

Common post-bootstrap workspace commands:
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
