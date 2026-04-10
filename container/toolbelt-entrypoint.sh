#!/usr/bin/env bash
set -euo pipefail

TOOLBELT_HOST_HOME="${TOOLBELT_HOST_HOME:-}"
TOOLBELT_HOST_UID="${TOOLBELT_HOST_UID:-}"
TOOLBELT_HOST_GID="${TOOLBELT_HOST_GID:-}"
TOOLBELT_DOCKER_SOCK_GID="${TOOLBELT_DOCKER_SOCK_GID:-}"
CODER_HOME="${TOOLBELT_HOST_HOME:-/home/coder}"
CODEX_HOME="${CODEX_HOME:-${CODER_HOME}/.codex}"
AUTH_SRC="${CODEX_AUTH_JSON_SRC:-/run/secrets/codex-auth.json}"
CONFIG_SRC="${CODEX_CONFIG_TOML_SRC:-/run/secrets/codex-config.toml}"
GCLOUD_CONFIG_SRC="${GCLOUD_CONFIG_SRC:-/run/secrets/gcloud-config}"
GWS_CONFIG_SRC="${GWS_CONFIG_SRC:-/run/secrets/gws-config}"
GWS_CREDENTIALS_SRC="${GWS_CREDENTIALS_SRC:-/run/secrets/gws-credentials}"
KUBECONFIG_SRC="${KUBECONFIG_SRC:-/run/secrets/kube-config}"
OPENCODE_CONFIG_SRC="${OPENCODE_CONFIG_SRC:-/run/secrets/opencode-config}"
TOOLBELT_PROVIDER="${TOOLBELT_PROVIDER:-codex}"
CLAUDE_CONFIG_SRC="${CLAUDE_CONFIG_SRC:-/run/secrets/claude-config}"
CLAUDE_JSON_SRC="${CLAUDE_JSON_SRC:-/run/secrets/claude-config.json}"
CLAUDE_CREDENTIALS_SRC="${CLAUDE_CREDENTIALS_SRC:-/run/secrets/claude-credentials.json}"
FORGE_CONFIG_SRC="${FORGE_CONFIG_SRC:-/run/secrets/forge-config}"
TOOLBELT_WITH_FORGE="${TOOLBELT_WITH_FORGE:-}"

warn() {
  printf 'warning: %s\n' "$*" >&2
}

is_numeric_id() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

numeric_gid_for_path() {
  local path="$1"

  if stat -c '%g' "${path}" >/dev/null 2>&1; then
    stat -c '%g' "${path}"
    return 0
  fi

  if stat -f '%g' "${path}" >/dev/null 2>&1; then
    stat -f '%g' "${path}"
    return 0
  fi

  return 1
}

resolved_docker_socket_gid() {
  local socket_gid=""

  [[ -S /var/run/docker.sock ]] || return 1

  socket_gid="$(numeric_gid_for_path /var/run/docker.sock 2>/dev/null || true)"
  if is_numeric_id "${socket_gid}"; then
    printf '%s\n' "${socket_gid}"
    return 0
  fi

  if is_numeric_id "${TOOLBELT_DOCKER_SOCK_GID}"; then
    printf '%s\n' "${TOOLBELT_DOCKER_SOCK_GID}"
    return 0
  fi

  return 1
}

ensure_group_for_gid() {
  local preferred_name="$1"
  local target_gid="$2"
  local existing_group=""

  is_numeric_id "${target_gid}" || return 1

  existing_group="$(getent group "${target_gid}" | cut -d: -f1 | head -n 1 || true)"
  if [[ -n "${existing_group}" ]]; then
    printf '%s\n' "${existing_group}"
    return 0
  fi

  if getent group "${preferred_name}" >/dev/null 2>&1; then
    groupmod -g "${target_gid}" "${preferred_name}" >/dev/null 2>&1 || return 1
  else
    groupadd -g "${target_gid}" "${preferred_name}" >/dev/null 2>&1 || return 1
  fi

  printf '%s\n' "${preferred_name}"
}

align_coder_identity() {
  local primary_group=""
  local existing_uid_user=""

  if ! is_numeric_id "${TOOLBELT_HOST_UID}" || ! is_numeric_id "${TOOLBELT_HOST_GID}"; then
    return 0
  fi

  primary_group="$(ensure_group_for_gid coder "${TOOLBELT_HOST_GID}")" || {
    warn "failed to align coder primary group to host gid ${TOOLBELT_HOST_GID}"
    return 0
  }

  existing_uid_user="$(getent passwd "${TOOLBELT_HOST_UID}" | cut -d: -f1 | head -n 1 || true)"
  if [[ -n "${existing_uid_user}" && "${existing_uid_user}" != "coder" ]]; then
    usermod -o -u "${TOOLBELT_HOST_UID}" coder >/dev/null 2>&1 || {
      warn "failed to align coder uid to host uid ${TOOLBELT_HOST_UID}"
      return 0
    }
  elif [[ "$(id -u coder)" != "${TOOLBELT_HOST_UID}" ]]; then
    usermod -u "${TOOLBELT_HOST_UID}" coder >/dev/null 2>&1 || {
      warn "failed to align coder uid to host uid ${TOOLBELT_HOST_UID}"
      return 0
    }
  fi

  if [[ "$(id -g coder)" != "${TOOLBELT_HOST_GID}" ]]; then
    usermod -g "${primary_group}" coder >/dev/null 2>&1 || {
      warn "failed to align coder gid to host gid ${TOOLBELT_HOST_GID}"
      return 0
    }
  fi
}

configure_docker_socket_access() {
  local socket_group=""
  local socket_gid=""

  socket_gid="$(resolved_docker_socket_gid)" || return 0

  socket_group="$(ensure_group_for_gid toolbelt-docker "${socket_gid}")" || {
    warn "failed to align docker socket group to gid ${socket_gid}"
    return 0
  }

  case " $(id -nG coder) " in
    *" ${socket_group} "*)
      return 0
      ;;
  esac

  usermod -aG "${socket_group}" coder >/dev/null 2>&1 || warn "failed to add coder to docker socket group ${socket_group}"
}

build_coder_setpriv_group_args() {
  local primary_gid="$1"
  local docker_socket_gid=""
  local gid=""
  local -a supplementary_gids=()
  local -A seen_gids=()

  while IFS= read -r gid; do
    [[ -n "${gid}" && "${gid}" != "${primary_gid}" ]] || continue
    if [[ -z "${seen_gids[${gid}]:-}" ]]; then
      supplementary_gids+=("${gid}")
      seen_gids["${gid}"]=1
    fi
  done < <(id -G coder | tr ' ' '\n')

  docker_socket_gid="$(resolved_docker_socket_gid 2>/dev/null || true)"
  if is_numeric_id "${docker_socket_gid}" && [[ "${docker_socket_gid}" != "${primary_gid}" ]]; then
    if [[ -z "${seen_gids[${docker_socket_gid}]:-}" ]]; then
      supplementary_gids+=("${docker_socket_gid}")
    fi
  fi

  if [[ ${#supplementary_gids[@]} -gt 0 ]]; then
    printf '%s\n' "--groups=$(IFS=,; printf '%s' "${supplementary_gids[*]}")"
  else
    printf '%s\n' "--clear-groups"
  fi
}

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

merge_opencode_runtime_defaults() {
  local default_json="$1"
  local runtime_json="$2"

  [[ -f "${default_json}" ]] || return 0
  [[ -f "${runtime_json}" ]] || return 0

  python3 - "${default_json}" "${runtime_json}" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

default_path = Path(sys.argv[1])
runtime_path = Path(sys.argv[2])


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def load_config(path: Path, label: str):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        warn(f"{label} OpenCode config at {path} is not valid JSON; leaving runtime config unchanged")
        return None

    if not isinstance(data, dict):
        warn(f"{label} OpenCode config at {path} is not a JSON object; leaving runtime config unchanged")
        return None

    return data


default_cfg = load_config(default_path, "default")
runtime_cfg = load_config(runtime_path, "runtime")
if default_cfg is None or runtime_cfg is None:
    sys.exit(0)

changed = False
default_mcp = default_cfg.get("mcp")
if isinstance(default_mcp, dict) and "context-mode" in default_mcp:
    runtime_mcp = runtime_cfg.get("mcp")
    if runtime_mcp is None:
        runtime_cfg["mcp"] = {}
        runtime_mcp = runtime_cfg["mcp"]
        changed = True

    if isinstance(runtime_mcp, dict):
        if "context-mode" not in runtime_mcp:
            runtime_mcp["context-mode"] = default_mcp["context-mode"]
            changed = True
    else:
        warn(f"runtime OpenCode config at {runtime_path} has non-object 'mcp'; skipping default context-mode merge")

plugins = runtime_cfg.get("plugin")
if plugins is None:
    runtime_cfg["plugin"] = ["context-mode"]
    changed = True
elif isinstance(plugins, list):
    if "context-mode" not in plugins:
        plugins.append("context-mode")
        changed = True
else:
    warn(f"runtime OpenCode config at {runtime_path} has non-array 'plugin'; skipping plugin merge")

if not changed:
    sys.exit(0)

runtime_path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_path = tempfile.mkstemp(prefix=f".{runtime_path.name}.", dir=str(runtime_path.parent))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(runtime_cfg, handle, indent=2)
    handle.write("\n")
os.replace(tmp_path, runtime_path)
os.chmod(runtime_path, 0o600)
PY
}

bootstrap_codex_home() {
  mkdir -p "${CODEX_HOME}"
  chmod 700 "${CODEX_HOME}" 2>/dev/null || true

  # Try directory-based copy first (unified pattern), fall back to individual files.
  if [[ -d "/run/secrets/codex-config" ]]; then
    copy_secret_tree "/run/secrets/codex-config" "${CODEX_HOME}" || true
  else
    copy_secret "${AUTH_SRC}" "auth.json" "${CODEX_HOME}/auth.json" || true
    copy_secret "${CONFIG_SRC}" "config.toml" "${CODEX_HOME}/config.toml" || true
  fi

  # Optional fallback for API-key auth when auth.json is not mounted.
  if [[ ! -f "${CODEX_HOME}/auth.json" && -n "${OPENAI_API_KEY:-}" ]]; then
    printf '%s\n' "${OPENAI_API_KEY}" | codex login --with-api-key >/dev/null 2>&1 || true
  fi

  # Keep the raw key out of the interactive shell environment after bootstrap.
  unset OPENAI_API_KEY || true
}

bootstrap_claude_home() {
  local claude_home="${CODER_HOME}/.claude"

  mkdir -p "${claude_home}"
  chmod 700 "${claude_home}" 2>/dev/null || true
  copy_secret_tree "${CLAUDE_CONFIG_SRC}" "${claude_home}" || true

  # Rewrite host home paths in plugin/settings config to container paths.
  # Host paths like /Users/foo/.claude/plugins/... must become /home/coder/.claude/plugins/...
  local f host_home
  for f in "${claude_home}/plugins/installed_plugins.json" "${claude_home}/plugins/known_marketplaces.json" "${claude_home}/settings.json"; do
    [[ -f "$f" ]] || continue
    host_home="$(python3 - "$f" <<'PY'
import json, sys

def find_via_plugin_keys(data):
    """Strategy 1: scan installPath/installLocation keys (plugin JSONs)."""
    for v in (data.get("plugins", {}).values() if "plugins" in data else data.values()):
        obj = v[0] if isinstance(v, list) else v
        if not isinstance(obj, dict):
            continue
        for key in ("installPath", "installLocation"):
            p = obj.get(key, "")
            if "/.claude/" in p:
                return p.split("/.claude/")[0]
    return None

def find_via_recursive_scan(node):
    """Strategy 2: walk all string values for /.claude/ (settings.json etc.)."""
    if isinstance(node, str):
        if "/.claude/" in node:
            # Extract the absolute path prefix, not surrounding text.
            # E.g. "sh /Users/lulu/.claude/foo" -> "/Users/lulu"
            import re
            m = re.search(r'(/\S+?)/\.claude/', node)
            if m:
                return m.group(1)
    elif isinstance(node, dict):
        for v in node.values():
            result = find_via_recursive_scan(v)
            if result is not None:
                return result
    elif isinstance(node, list):
        for item in node:
            result = find_via_recursive_scan(item)
            if result is not None:
                return result
    return None

with open(sys.argv[1]) as fh:
    data = json.load(fh)
home = find_via_plugin_keys(data) or find_via_recursive_scan(data)
if home:
    print(home)
PY
    )" || continue
    [[ -n "${host_home}" && "${host_home}" != "${CODER_HOME}" ]] || continue
    sed -i "s|${host_home}|${CODER_HOME}|g" "$f" 2>/dev/null || true
  done

  # .claude.json is always copied from secrets (not direct-mounted) so we can
  # patch host-specific fields like installMethod without modifying host files.
  copy_secret "${CLAUDE_JSON_SRC}" ".claude.json" "${CODER_HOME}/.claude.json" || true

  # Fix installMethod: host may say "native" but container uses npm.
  if [[ -f "${CODER_HOME}/.claude.json" ]]; then
    sed -i 's/"installMethod":\s*"native"/"installMethod": "npm"/' "${CODER_HOME}/.claude.json" 2>/dev/null || true
  fi

  # Write credentials file for Linux-based credential storage.
  # On macOS the host stores OAuth credentials in Keychain, not on disk.
  # The launcher extracts the full credential blob and mounts it so we can
  # populate the file-based store that Claude Code reads on Linux.
  if [[ -f "${CLAUDE_CREDENTIALS_SRC}" ]]; then
    install -m 600 "${CLAUDE_CREDENTIALS_SRC}" "${claude_home}/.credentials.json"
  fi
}

bootstrap_forge_home() {
  local forge_home="${CODER_HOME}/forge"

  if [[ ! -d "${FORGE_CONFIG_SRC}" ]]; then
    # No forge config mounted; nothing to hydrate.
    return 0
  fi

  copy_secret_tree "${FORGE_CONFIG_SRC}" "${forge_home}" || true

  # Disable auto-updates inside the container to keep the image immutable.
  if [[ -f "${forge_home}/.forge.toml" ]]; then
    sed -i 's/^auto_update\s*=\s*true/auto_update = false/' "${forge_home}/.forge.toml" 2>/dev/null || true
  fi
}

bootstrap_archon_skill() {
  local skill_src="/opt/archon/.claude/skills/archon"
  local skill_dst="${CODER_HOME}/.claude/skills/archon"

  [[ -d "${skill_src}" ]] || return 0

  # Only inject if not already present (host's .claude takes priority if it has its own)
  if [[ -d "${skill_dst}" ]]; then
    return 0
  fi

  mkdir -p "${skill_dst}"
  chmod 700 "${skill_dst}" 2>/dev/null || true
  cp -a "${skill_src}/." "${skill_dst}/"
  find "${skill_dst}" -type d -exec chmod 700 {} + 2>/dev/null || true
  find "${skill_dst}" -type f -exec chmod 600 {} + 2>/dev/null || true
}

bootstrap_cloud_tool_homes() {
  local gcloud_home="${CLOUDSDK_CONFIG:-${CODER_HOME}/.config/gcloud}"
  local gws_home="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-${CODER_HOME}/.config/gws}"
  local kube_home="${CODER_HOME}/.kube"

  mkdir -p "$(dirname "${gcloud_home}")"
  copy_secret_tree "${GCLOUD_CONFIG_SRC}" "${gcloud_home}" || true

  mkdir -p "$(dirname "${gws_home}")" "${gws_home}"
  copy_secret_tree "${GWS_CONFIG_SRC}" "${gws_home}" || true
  copy_secret "${GWS_CREDENTIALS_SRC}" "credentials.json" "${gws_home}/credentials.json" || true

  mkdir -p "${kube_home}"
  chmod 700 "${kube_home}" 2>/dev/null || true
  copy_secret "${KUBECONFIG_SRC}" "config" "${kube_home}/config" || true
}

bootstrap_opencode_home() {
  local opencode_home="${OPENCODE_HOME:-${CODER_HOME}/.config/opencode}"
  local runtime_json="${opencode_home}/opencode.json"
  local default_json=""

  if [[ "${TOOLBELT_WITH_OPENCODE:-}" != "1" && ! -d "${OPENCODE_CONFIG_SRC}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${opencode_home}")" "${opencode_home}"
  chmod 700 "${opencode_home}" 2>/dev/null || true

  if [[ -f "${runtime_json}" ]]; then
    default_json="$(mktemp)"
    install -m 600 "${runtime_json}" "${default_json}"
  fi

  copy_secret_tree "${OPENCODE_CONFIG_SRC}" "${opencode_home}" || true

  if [[ -n "${default_json}" ]]; then
    merge_opencode_runtime_defaults "${default_json}" "${runtime_json}" || warn "failed to merge OpenCode runtime defaults into ${runtime_json}"
    rm -f "${default_json}"
  fi
}

bootstrap_ssh() {
  local ssh_src="/run/secrets/ssh-keys"
  local ssh_home="${CODER_HOME}/.ssh"

  if [[ ! -d "${ssh_src}" ]]; then
    return 0
  fi

  mkdir -p "${ssh_home}"
  chmod 700 "${ssh_home}"

  if [[ -f "${ssh_src}/id_ed25519" ]]; then
    install -m 600 "${ssh_src}/id_ed25519" "${ssh_home}/id_ed25519"
  fi
  if [[ -f "${ssh_src}/id_ed25519.pub" ]]; then
    install -m 644 "${ssh_src}/id_ed25519.pub" "${ssh_home}/id_ed25519.pub"
  fi

  # Pre-seed known_hosts for gitlab.com
  ssh-keyscan -t ed25519,rsa gitlab.com 2>/dev/null >> "${ssh_home}/known_hosts" || true
  chmod 644 "${ssh_home}/known_hosts"

  cat > "${ssh_home}/config" <<'SSHCONF'
Host gitlab.com
  HostName gitlab.com
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
SSHCONF
  chmod 600 "${ssh_home}/config"
}

bootstrap_mempalace() {
  # The mempalace mount uses src=dst path (same as workspace mounts) so it
  # survives the /home/coder → TOOLBELT_HOST_HOME symlink substitution.
  # Check TOOLBELT_HOST_HOME first, fall back to CODER_HOME for manual runs.
  local mempalace_dir="${TOOLBELT_HOST_HOME:-${CODER_HOME}}/.mempalace"
  [[ -d "${mempalace_dir}" ]] || return 0

  # MEMPALACE_PALACE_PATH must point to the palace/ subdirectory (ChromaDB data),
  # not the root ~/.mempalace dir, otherwise mempalace falls back to config.json
  # which contains the hardcoded host path.
  export MEMPALACE_PALACE_PATH="${mempalace_dir}/palace"

  # Inject MCP server config into Claude Code's ~/.claude.json under the
  # user-level mcpServers key. This is the correct location — settings.json
  # does not register MCP servers; claude.json does.
  local claude_json="${CODER_HOME}/.claude.json"
  [[ -f "${claude_json}" ]] || return 0

  python3 - "${claude_json}" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        s = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    s = {}
s.setdefault("mcpServers", {})
s["mcpServers"]["mempalace"] = {
    "type": "stdio",
    "command": "mempalace-mcp"
}
with open(path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PY
}

install_gws_wrapper() {
  local existing_gws_path=""
  local real_gws_path="/usr/local/bin/gws-real"
  local wrapper_path="/usr/local/bin/gws"
  local wrapper_src="/opt/toolbelt/scripts/gws-scope-guard.sh"

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

feature_enabled() {
  local token="$1"
  local feat
  for feat in ${TOOLBELT_FEATURES:-}; do
    [[ "$feat" == "$token" ]] && return 0
  done

  # Fallback: probe well-known mount paths so the MOTD works even
  # when the container is started manually without the launcher.
  case "$token" in
    docker)   [[ -S /var/run/docker.sock ]] ;;
    gcloud)   [[ -d /run/secrets/gcloud-config ]] ;;
    gws)      [[ -d /run/secrets/gws-config ]] ;;
    k8s)      [[ -e /run/secrets/kube-config ]] ;;
    github)   [[ -n "${GH_TOKEN:-}" ]] ;;
    gitlab)   [[ -n "${GLAB_TOKEN:-}" ]] ;;
    ssh)      [[ -d /run/secrets/ssh-keys ]] ;;
    opencode) [[ -d /run/secrets/opencode-config ]] ;;
    kimaki)     mountpoint -q /home/coder/.kimaki 2>/dev/null ;;
    mempalace)  [[ -d "${TOOLBELT_HOST_HOME:-${CODER_HOME}}/.mempalace" ]] ;;
    forge)      [[ "${TOOLBELT_WITH_FORGE:-}" == "1" ]] || [[ -d /run/secrets/forge-config ]] ;;
    *)        return 1 ;;
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

  # --- Header ---
  local workdir="${PWD:-/workspace}"
  printf '%b\n' "${bold}${green}Toolbelt Container${reset}"
  printf '%b\n' "${dim}Ready at ${workdir}${reset}"
  printf '\n'

  # --- Workspace mounts ---
  printf '%b\n' "${bold}${cyan}Workspace mounts${reset}"
  if [[ -n "${TOOLBELT_MOUNTS:-}" ]]; then
    local IFS=':'
    local pair
    for pair in ${TOOLBELT_MOUNTS}; do
      local host_path="${pair%%=*}"
      local cont_path="${pair#*=}"
      printf '  %b -> %b\n' "${yellow}${host_path}${reset}" "${cont_path}"
    done
    unset IFS
  else
    printf '  %s\n' "${workdir} (current directory)"
  fi
  printf '\n'

  # --- Features ---
  printf '%b\n' "${bold}${cyan}Features${reset}"
  local -a feat_names=( docker gcloud gws k8s github gitlab ssh opencode kimaki mempalace forge )
  local -a feat_labels=("Docker" "Google Cloud" "Google Workspace" "Kubernetes" "GitHub CLI" "GitLab CLI" "SSH Keys" "OpenCode" "Kimaki" "Mempalace" "ForgeCode")
  local i label_width=18 col=0 cols=3

  for (( i=0; i<${#feat_names[@]}; i++ )); do
    local tag label
    label="${feat_labels[$i]}"
    if feature_enabled "${feat_names[$i]}"; then
      tag="${green}[x]${reset}"
    else
      tag="${dim}[ ]${reset}"
    fi
    printf '  %b %-*s' "$tag" "$label_width" "$label"
    col=$(( col + 1 ))
    if (( col >= cols )); then
      printf '\n'
      col=0
    fi
  done

  if (( col > 0 )); then
    printf '\n'
  fi
}

case "${TOOLBELT_PROVIDER}" in
  codex)  bootstrap_codex_home ;;
  claude) bootstrap_claude_home ;;
  forge)  bootstrap_forge_home ;;
esac
# When -forge flag is used with another provider, also bootstrap forge.
if [[ -n "${TOOLBELT_WITH_FORGE}" && "${TOOLBELT_PROVIDER}" != "forge" ]]; then
  bootstrap_forge_home
fi
bootstrap_archon_skill
bootstrap_cloud_tool_homes
bootstrap_ssh
bootstrap_mempalace

# Point GWS/gcloud credential env vars at the writable hydrated copies
# instead of the read-only /run/secrets/ mounts so token refresh can write.
if [[ "${TOOLBELT_GWS_CREDENTIALS_AVAILABLE:-}" == "1" ]]; then
  local_gws_creds="${CODER_HOME}/.config/gws/credentials.json"
  if [[ -f "${local_gws_creds}" ]]; then
    export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="${local_gws_creds}"
  fi
fi
if [[ "${TOOLBELT_GWS_ADC_AVAILABLE:-}" == "1" ]]; then
  local_adc="${CODER_HOME}/.config/gcloud/application_default_credentials.json"
  if [[ -f "${local_adc}" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS="${local_adc}"
  fi
fi

bootstrap_opencode_home
install_gws_wrapper
align_coder_identity
configure_docker_socket_access
show_motd "$@"

# When TOOLBELT_HOST_HOME is set, use it as HOME so that both ~/... and
# /Users/<user>/... paths resolve correctly inside the container.
# Symlink /home/coder → host home so tools referencing /home/coder still work.
if [[ -n "${TOOLBELT_HOST_HOME}" && "${TOOLBELT_HOST_HOME}" != "/home/coder" ]]; then
  mkdir -p "${TOOLBELT_HOST_HOME}"
  # Preserve any bind-mounts under /home/coder (e.g. ~/forge) by moving
  # non-mount contents to the host home instead of deleting them.
  if [[ -d /home/coder && ! -L /home/coder ]]; then
    # Copy skeleton files (dotfiles etc.) but never overwrite existing content
    # or descend into mount points.
    find /home/coder -maxdepth 1 -mindepth 1 ! -mount -exec mv -n {} "${TOOLBELT_HOST_HOME}/" \; 2>/dev/null || true
    # Now safe to replace with a symlink — only bind-mount stubs remain.
    rm -d /home/coder 2>/dev/null || rm -rf /home/coder 2>/dev/null || true
  fi
  ln -sfn "${TOOLBELT_HOST_HOME}" /home/coder
  usermod -d "${TOOLBELT_HOST_HOME}" coder 2>/dev/null || true
fi

# Hand ownership of coder's home to coder (covers bootstrap-created files).
CODER_UID="$(id -u coder)"
CODER_GID="$(id -g coder)"
CODER_GROUP_ARGS="$(build_coder_setpriv_group_args "${CODER_GID}")"
chown -R "${CODER_UID}:${CODER_GID}" "${CODER_HOME}" 2>/dev/null || true

# Drop from root to coder for the actual workload.
exec setpriv --reuid="${CODER_UID}" --regid="${CODER_GID}" ${CODER_GROUP_ARGS} \
  env -u TOOLBELT_MOUNTS -u TOOLBELT_FEATURES -u TOOLBELT_HOST_UID -u TOOLBELT_HOST_GID -u TOOLBELT_DOCKER_SOCK_GID \
  HOME="${CODER_HOME}" "$@"
