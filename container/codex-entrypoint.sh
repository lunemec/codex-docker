#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-/root/.codex}"
AUTH_SRC="${CODEX_AUTH_JSON_SRC:-/run/secrets/codex-auth.json}"
CONFIG_SRC="${CODEX_CONFIG_TOML_SRC:-/run/secrets/codex-config.toml}"
GCLOUD_CONFIG_SRC="${GCLOUD_CONFIG_SRC:-/run/secrets/gcloud-config}"
GWS_CONFIG_SRC="${GWS_CONFIG_SRC:-/run/secrets/gws-config}"
GWS_CREDENTIALS_SRC="${GWS_CREDENTIALS_SRC:-/run/secrets/gws-credentials}"
KUBECONFIG_SRC="${KUBECONFIG_SRC:-/run/secrets/kube-config}"

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

copy_secret_tree() {
  local src_path="$1"
  local dst_path="$2"

  if [[ ! -d "${src_path}" ]]; then
    return 1
  fi

  mkdir -p "${dst_path}"
  chmod 700 "${dst_path}" 2>/dev/null || true

  cp -a "${src_path}/." "${dst_path}/"

  find "${dst_path}" -type d -exec chmod 700 {} + 2>/dev/null || true
  find "${dst_path}" -type f -exec chmod 600 {} + 2>/dev/null || true
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

bootstrap_cloud_tool_homes() {
  local gcloud_home="${CLOUDSDK_CONFIG:-/root/.config/gcloud}"
  local gws_home="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-/root/.config/gws}"
  local kube_home="/root/.kube"

  mkdir -p "$(dirname "${gcloud_home}")"
  copy_secret_tree "${GCLOUD_CONFIG_SRC}" "${gcloud_home}" || true

  mkdir -p "$(dirname "${gws_home}")" "${gws_home}"
  copy_secret_tree "${GWS_CONFIG_SRC}" "${gws_home}" || true
  copy_secret "${GWS_CREDENTIALS_SRC}" "credentials.json" "${gws_home}/credentials.json" || true

  mkdir -p "${kube_home}"
  chmod 700 "${kube_home}" 2>/dev/null || true
  copy_secret "${KUBECONFIG_SRC}" "config" "${kube_home}/config" || true
}

install_gws_wrapper() {
  local existing_gws_path=""
  local real_gws_path="/usr/local/bin/gws-real"
  local wrapper_path="/usr/local/bin/gws"
  local wrapper_src="/opt/codex-baseline/scripts/gws-scope-guard.sh"

  [[ -x "${wrapper_src}" ]] || return 0

  existing_gws_path="$(command -v gws 2>/dev/null || true)"
  if [[ -z "${existing_gws_path}" && ! -x "${real_gws_path}" ]]; then
    return 0
  fi

  if [[ ! -x "${real_gws_path}" ]]; then
    if [[ "${existing_gws_path}" != "${wrapper_path}" ]]; then
      return 0
    fi
    mv "${wrapper_path}" "${real_gws_path}"
  fi

  ln -sf "${wrapper_src}" "${wrapper_path}"
}

describe_script() {
  local script_name="$1"

  case "${script_name}" in
    toolbelt.sh)
      echo "Host-side selective mount launcher (path args -> /workspace/<basename>)."
      ;;
    verify_*.sh)
      echo "Contract/smoke verifier helper."
      ;;
    *)
      echo "Image-baked helper script."
      ;;
  esac
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

  local reset="" bold="" dim="" cyan="" yellow="" green=""
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    reset=$'\033[0m'
    bold=$'\033[1m'
    dim=$'\033[2m'
    cyan=$'\033[36m'
    yellow=$'\033[33m'
    green=$'\033[32m'
  fi

  printf '%b\n' "${bold}${green}Codex Dev Container${reset}"
  printf '%b\n' "${dim}Ready at /workspace${reset}"
  printf '\n'

  printf '%b\n' "${bold}${cyan}Most-used commands${reset}"
  printf '  %b\n' "${yellow}codex${reset}"
  printf '    Launch Codex CLI (Docker-guarded wrapper).\n'
  printf '  %b\n' "${yellow}ralph${reset}"
  printf '    Launch Ralph CLI.\n'
  printf '  %b\n' "${yellow}openclaw${reset}"
  printf '    Launch OpenClaw CLI.\n'
  printf '  %b\n' "${yellow}claude${reset}"
  printf '    Launch Anthropic Claude Code CLI.\n'
  printf '  %b\n' "${yellow}gemini${reset}"
  printf '    Launch Google Gemini CLI.\n'
  printf '  %b\n' "${yellow}cursor${reset}"
  printf '    Launch Cursor Agent CLI (`agent` and `cursor-agent` aliases).\n'
  printf '\n'

  printf '%b\n' "${bold}${cyan}Coordinator${reset}"
  if [[ -f /workspace/coordinator/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md ]]; then
    printf '  %b\n' "${yellow}cd /workspace/coordinator${reset}"
    printf '    External coordinator checkout detected at /workspace/coordinator.\n'
    printf '  %b\n' "${yellow}codex \"\$(cat /workspace/coordinator/coordination/prompts/TOP_LEVEL_AGENT_PROMPT.md)\"${reset}"
    printf '    Launch Codex with the standalone coordinator prompt.\n'
  else
    printf '  %s\n' "No standalone coordinator checkout detected at /workspace/coordinator."
    printf '  %s\n' "Toolbelt does not embed coordinator assets; mount or clone the standalone repository there if you need orchestration flows."
  fi
  printf '\n'

  local path base
  local -a scripts=()
  local -a core_scripts=()
  local -a verify_scripts=()

  shopt -s nullglob
  scripts=(/opt/codex-baseline/scripts/*.sh)
  shopt -u nullglob

  for path in "${scripts[@]}"; do
    base="$(basename "${path}")"
    if [[ "${base}" == verify_*.sh ]]; then
      verify_scripts+=("${path}")
    else
      core_scripts+=("${path}")
    fi
  done

  printf '%b\n' "${bold}${cyan}Image-baked scripts${reset}"
  if (( ${#scripts[@]} == 0 )); then
    printf '  %s\n' "No scripts found under /opt/codex-baseline/scripts."
  else
    for path in "${core_scripts[@]}"; do
      base="$(basename "${path}")"
      printf '  %b\n' "${yellow}${path}${reset}"
      printf '    %s\n' "$(describe_script "${base}")"
    done
    if (( ${#verify_scripts[@]} > 0 )); then
      printf '\n'
      printf '%b\n' "${bold}${cyan}Verification scripts${reset}"
      for path in "${verify_scripts[@]}"; do
        base="$(basename "${path}")"
        printf '  %b\n' "${yellow}${path}${reset}"
        printf '    %s\n' "$(describe_script "${base}")"
      done
    fi
  fi
}

bootstrap_codex_home
bootstrap_cloud_tool_homes
install_gws_wrapper
show_motd "$@"

exec "$@"
