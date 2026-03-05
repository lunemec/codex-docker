#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-/root/.codex}"
AUTH_SRC="${CODEX_AUTH_JSON_SRC:-/run/secrets/codex-auth.json}"
CONFIG_SRC="${CODEX_CONFIG_TOML_SRC:-/run/secrets/codex-config.toml}"

copy_secret() {
  local src_path="$1"
  local fallback_name="$2"
  local dst_path="$3"

  if [[ -f "${src_path}" ]]; then
    install -m 600 "${src_path}" "${dst_path}"
    return 0
  fi

  if [[ -d "${src_path}" && -f "${src_path}/${fallback_name}" ]]; then
    install -m 600 "${src_path}/${fallback_name}" "${dst_path}"
    return 0
  fi

  return 1
}

bootstrap_codex_home() {
  mkdir -p "${CODEX_HOME}"
  chmod 700 "${CODEX_HOME}" 2>/dev/null || true

  copy_secret "${AUTH_SRC}" "auth.json" "${CODEX_HOME}/auth.json" || true
  copy_secret "${CONFIG_SRC}" "config.toml" "${CODEX_HOME}/config.toml" || true

  # Optional fallback for API-key auth when auth.json is not mounted.
  if [[ ! -f "${CODEX_HOME}/auth.json" && -n "${OPENAI_API_KEY:-}" ]]; then
    printf '%s\n' "${OPENAI_API_KEY}" | codex login --with-api-key >/dev/null 2>&1 || true
  fi

  # Keep the raw key out of the interactive shell environment after bootstrap.
  unset OPENAI_API_KEY || true
}

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

bootstrap_codex_home
show_motd "$@"

exec "$@"
