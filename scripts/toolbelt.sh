#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IMAGE="${TOOLBELT_IMAGE:-toolbelt:latest}"
DEFAULT_SHELL="${TOOLBELT_SHELL:-bash}"
DEFAULT_WORKDIR="/workspace"
DEFAULT_TMPFS_SIZE="${TOOLBELT_TMPFS_SIZE:-512m}"
GWS_CREDENTIALS_MOUNT="/run/secrets/gws-credentials"
GWS_CREDENTIALS_DEST="${GWS_CREDENTIALS_MOUNT}/credentials.json"
GWS_ADC_MOUNT="/run/secrets/gws-adc"
GWS_ADC_DEST="${GWS_ADC_MOUNT}/application_default_credentials.json"
OPENCODE_CONFIG_MOUNT="/run/secrets/opencode-config"

PROVIDER=""
IMAGE="$DEFAULT_IMAGE"
WORKDIR="$DEFAULT_WORKDIR"
SHELL_CMD="$DEFAULT_SHELL"
WITH_DOCKER_SOCK=0
WITH_GCLOUD=0
WITH_GWS=0
WITH_OPENCODE=0
WITH_KIMAKI=0
WITH_K8S=0
WITH_GITHUB=0
WITH_GITLAB=0
AUTO_REMOVE=1
TMPFS_SIZE="$DEFAULT_TMPFS_SIZE"
MOUNTS=()
MOUNT_PWD_TO_WORKSPACE=0
CMD=()
AUTH_SRC="${TOOLBELT_CODEX_AUTH_SRC:-$HOME/.codex/auth.json}"
CONFIG_SRC="${TOOLBELT_CODEX_CONFIG_SRC:-$HOME/.codex/config.toml}"
CLAUDE_DIR_SRC="${TOOLBELT_CLAUDE_DIR_SRC:-$HOME/.claude}"
CLAUDE_JSON_SRC="${TOOLBELT_CLAUDE_JSON_SRC:-$HOME/.claude.json}"
ANTHROPIC_API_KEY_VALUE="${ANTHROPIC_API_KEY:-}"
GCLOUD_SRC="${TOOLBELT_GCLOUD_CONFIG_SRC:-$HOME/.config/gcloud}"
GWS_SRC="${TOOLBELT_GWS_CONFIG_SRC:-$HOME/.config/gws}"
OPENCODE_CONFIG_SRC="${TOOLBELT_OPENCODE_CONFIG_SRC:-$HOME/.config/opencode}"
KIMAKI_SRC="${TOOLBELT_KIMAKI_CONFIG_SRC:-$HOME/.kimaki}"
KUBECONFIG_SRC="${TOOLBELT_KUBECONFIG_SRC:-$HOME/.kube/config}"
GITHUB_CONFIG_SRC="${TOOLBELT_GITHUB_CONFIG_SRC:-$HOME/.config/gh}"
GITLAB_CONFIG_SRC="${TOOLBELT_GITLAB_CONFIG_SRC:-$HOME/.config/glab-cli}"
GWS_RUNTIME_DIR=""
GWS_EXPORTED_CREDENTIALS=""
GWS_ADC_SOURCE=""
GWS_EXPORT_ERROR=""

usage() {
  cat <<'USAGE'
Usage:
  toolbelt <provider> [options] [directory1 directory2 ...] [-- CMD...]

Description:
  Run toolbelt:latest with selective mounts.
  A provider subcommand (codex or claude) is required.
  If no directories are provided, the current directory is mounted to /workspace.
  Each provided directory/path is mounted to /workspace/<basename(path)>.

Providers:
  codex                 Mount Codex credentials (~/.codex/auth.json, config.toml)
  claude                Mount Claude config (~/.claude/) and pass ANTHROPIC_API_KEY

Options:
  -docker, --docker   Mount /var/run/docker.sock
  -gcloud, --gcloud   Mount host gcloud config into /run/secrets/gcloud-config (read-only)
  -gws, --gws         Export portable gws auth into container runtime config, mount gws config, and use ADC fallback when needed
  -opencode, --opencode
                     Require host OpenCode config and mount it into /run/secrets/opencode-config (read-only)
  -kimaki, --kimaki   Mount host Kimaki data dir into /home/coder/.kimaki (read-write)
  -k8s, --k8s         Mount host kubeconfig into /run/secrets/kube-config (read-only)
  -github, --github   Mount host GitHub CLI config (~/.config/gh) into container (read-only)
  -gitlab, --gitlab   Mount host GitLab CLI config (~/.config/glab-cli) into container (read-only)
  -image, --image IMAGE
                     Container image (default: toolbelt:latest)
  -workdir, --workdir, -w DIR
                     Container working directory (default: /workspace)
  -shell, --shell SHELL
                     Default interactive shell when no CMD is provided (default: bash)
  -tmpfs-size, --tmpfs-size SIZE
                     /home/coder/.codex tmpfs size (default: 512m)
  -keep, --keep       Keep container after exit (omit --rm)
  -h, -help, --help   Show this help

Environment overrides:
  TOOLBELT_IMAGE
  TOOLBELT_SHELL
  TOOLBELT_TMPFS_SIZE
  TOOLBELT_CODEX_AUTH_SRC
  TOOLBELT_CODEX_CONFIG_SRC
  TOOLBELT_CLAUDE_DIR_SRC
  TOOLBELT_CLAUDE_JSON_SRC
  TOOLBELT_GCLOUD_CONFIG_SRC
  TOOLBELT_GWS_CONFIG_SRC
  TOOLBELT_OPENCODE_CONFIG_SRC
  TOOLBELT_KIMAKI_CONFIG_SRC
  TOOLBELT_KUBECONFIG_SRC
  TOOLBELT_GITHUB_CONFIG_SRC
  TOOLBELT_GITLAB_CONFIG_SRC
  ANTHROPIC_API_KEY

Examples:
  toolbelt codex
  toolbelt claude
  toolbelt codex -docker -gcloud -gws -kimaki -k8s ./directory1 ./directory2
  toolbelt claude -k8s ./directory1 -- bash -lc 'ls -la /workspace'
USAGE
}

abs_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    if realpath -m / >/dev/null 2>&1; then
      realpath -m "$path"
    else
      realpath "$path"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
  else
    (
      cd "$(dirname "$path")" >/dev/null 2>&1 || exit 1
      printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")"
    )
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || {
    echo "docker command not found" >&2
    exit 1
  }

  docker info >/dev/null 2>&1 || {
    echo "cannot connect to Docker daemon" >&2
    exit 1
  }
}

extract_claude_oauth_token() {
  local raw
  raw="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" || return 1
  python3 - "$raw" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
    oauth = data.get("claudeAiOauth", {})
    token = oauth.get("accessToken", "")
    if token:
        print(token)
    else:
        sys.exit(1)
except (json.JSONDecodeError, KeyError):
    sys.exit(1)
PY
}

cleanup_runtime_artifacts() {
  if [[ -n "${GWS_RUNTIME_DIR}" && -d "${GWS_RUNTIME_DIR}" ]]; then
    rm -rf "${GWS_RUNTIME_DIR}"
  fi
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

python3_available() {
  command -v python3 >/dev/null 2>&1
}

gws_scope_preflight_target() {
  local cmd_base

  if [[ "$WITH_GWS" -ne 1 || -z "${GWS_EXPORTED_CREDENTIALS}" ]]; then
    return 1
  fi

  if [[ ${#CMD[@]} -lt 4 ]]; then
    return 1
  fi

  cmd_base="$(basename "${CMD[0]}")"
  if [[ "${cmd_base}" != "gws" ]]; then
    return 1
  fi

  case "${CMD[1]}" in
    auth|help|schema|version)
      return 1
      ;;
  esac

  printf '%s\n' "${CMD[1]}.${CMD[2]}.${CMD[3]}"
}

read_json_string_field() {
  local json_path="$1"
  local field_name="$2"

  python3 - "$json_path" "$field_name" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)

value = data.get(sys.argv[2], "")
if isinstance(value, str):
    print(value)
PY
}

read_json_scope_field() {
  local json_path="$1"
  local field_name="$2"

  python3 - "$json_path" "$field_name" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)

value = data.get(sys.argv[2], "")
if isinstance(value, str):
    for item in value.split():
        if item:
            print(item)
elif isinstance(value, list):
    for item in value:
        if isinstance(item, str) and item:
            print(item)
PY
}

extract_gws_schema_scopes() {
  local schema_ref="$1"
  local schema_json

  schema_json="$(gws schema "${schema_ref}" 2>/dev/null)" || return 1

  python3 - "${schema_json}" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)

scopes = data.get("scopes")
if not isinstance(scopes, list):
    sys.exit(1)

for item in scopes:
    if isinstance(item, str) and item:
        print(item)
PY
}

extract_tokeninfo_scopes() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)

scope_field = data.get("scope", "")
if not isinstance(scope_field, str) or not scope_field.strip():
    sys.exit(1)

for item in scope_field.split():
    if item:
        print(item)
PY
}

extract_access_token() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)

token = data.get("access_token", "")
if not isinstance(token, str) or not token:
    sys.exit(1)

print(token)
PY
}

extract_gws_granted_scopes() {
  local credentials_path="$1"
  local access_token=""
  local client_id=""
  local client_secret=""
  local refresh_token=""
  local token_response=""
  local token_uri=""
  local tokeninfo_response=""
  local tokeninfo_url="${TOOLBELT_GWS_TOKENINFO_URL:-https://oauth2.googleapis.com/tokeninfo}"
  local field_name
  local -a GWS_SCOPE_LINES=()

  for field_name in granted_scopes scopes scope; do
    if mapfile -t GWS_SCOPE_LINES < <(read_json_scope_field "${credentials_path}" "${field_name}"); then
      if [[ ${#GWS_SCOPE_LINES[@]} -gt 0 ]]; then
        printf '%s\n' "${GWS_SCOPE_LINES[@]}"
        return 0
      fi
    fi
  done

  access_token="$(read_json_string_field "${credentials_path}" "access_token")" || return 1
  if [[ -z "${access_token}" ]]; then
    refresh_token="$(read_json_string_field "${credentials_path}" "refresh_token")" || return 1
    client_id="$(read_json_string_field "${credentials_path}" "client_id")" || return 1
    client_secret="$(read_json_string_field "${credentials_path}" "client_secret")" || return 1
    token_uri="$(read_json_string_field "${credentials_path}" "token_uri")" || return 1
    if [[ -z "${token_uri}" ]]; then
      token_uri="https://oauth2.googleapis.com/token"
    fi

    if [[ -z "${refresh_token}" || -z "${client_id}" || -z "${client_secret}" ]]; then
      return 1
    fi

    token_response="$(curl -fsS --max-time 15 \
      --request POST \
      --data-urlencode "client_id=${client_id}" \
      --data-urlencode "client_secret=${client_secret}" \
      --data-urlencode "refresh_token=${refresh_token}" \
      --data-urlencode "grant_type=refresh_token" \
      "${token_uri}")" || return 1

    access_token="$(extract_access_token "${token_response}")" || return 1
  fi

  tokeninfo_response="$(curl -fsS --max-time 15 -G \
    --data-urlencode "access_token=${access_token}" \
    "${tokeninfo_url}")" || return 1

  extract_tokeninfo_scopes "${tokeninfo_response}"
}

scopes_overlap() {
  local granted_scope required_scope

  for required_scope in "${REQUIRED_GWS_SCOPES[@]}"; do
    for granted_scope in "${GRANTED_GWS_SCOPES[@]}"; do
      if [[ "${granted_scope}" == "${required_scope}" ]]; then
        return 0
      fi
    done
  done

  return 1
}

preflight_gws_scope_requirements() {
  local granted_scopes_output=""
  local required_scopes_output=""
  local schema_ref service_name

  schema_ref="$(gws_scope_preflight_target)" || return 0
  service_name="${CMD[1]}"

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; skipping gws scope preflight for ${schema_ref}"
    return 0
  fi

  if ! python3_available; then
    warn "python3 not found; skipping gws scope preflight for ${schema_ref}"
    return 0
  fi

  if ! required_scopes_output="$(extract_gws_schema_scopes "${schema_ref}")"; then
    warn "unable to resolve required scopes for ${schema_ref}; continuing without gws scope preflight"
    return 0
  fi
  if [[ -n "${required_scopes_output}" ]]; then
    mapfile -t REQUIRED_GWS_SCOPES <<<"${required_scopes_output}"
  else
    REQUIRED_GWS_SCOPES=()
  fi

  if [[ ${#REQUIRED_GWS_SCOPES[@]} -eq 0 ]]; then
    warn "no required scopes reported for ${schema_ref}; continuing without gws scope preflight"
    return 0
  fi

  if ! granted_scopes_output="$(extract_gws_granted_scopes "${GWS_EXPORTED_CREDENTIALS}")"; then
    warn "unable to inspect granted scopes for exported gws credentials; continuing without gws scope preflight"
    return 0
  fi
  if [[ -n "${granted_scopes_output}" ]]; then
    mapfile -t GRANTED_GWS_SCOPES <<<"${granted_scopes_output}"
  else
    GRANTED_GWS_SCOPES=()
  fi

  if [[ ${#GRANTED_GWS_SCOPES[@]} -eq 0 ]]; then
    warn "exported gws credentials did not report any granted scopes; continuing without gws scope preflight"
    return 0
  fi

  if scopes_overlap; then
    return 0
  fi

  {
    printf 'requested direct gws command requires one of these OAuth scopes for %s:\n' "${schema_ref}"
    printf '  - %s\n' "${REQUIRED_GWS_SCOPES[@]}"
    printf 'but the exported host gws credentials currently grant:\n'
    printf '  - %s\n' "${GRANTED_GWS_SCOPES[@]}"
    printf "re-run 'gws auth login -s %s' on the host, then retry the toolbelt command\n" "${service_name}"
  } >&2
  exit 1
}

prepare_gws_runtime_inputs() {
  local adc_dir export_dir export_log gcloud_abs_source gws_abs_source runtime_base

  GWS_EXPORTED_CREDENTIALS=""
  GWS_ADC_SOURCE=""
  GWS_EXPORT_ERROR=""

  if [[ "$WITH_GWS" -ne 1 ]]; then
    return 0
  fi

  gws_abs_source="$(abs_path "$GWS_SRC")"
  if [[ ! -d "$gws_abs_source" ]]; then
    echo "requested -gws/--gws but Google Workspace CLI config directory is not available: $GWS_SRC" >&2
    exit 1
  fi

  runtime_base="$(dirname "${gws_abs_source}")"
  if [[ ! -w "${runtime_base}" ]]; then
    runtime_base="${gws_abs_source}"
  fi
  if [[ ! -w "${runtime_base}" ]]; then
    runtime_base="$(pwd)"
  fi

  GWS_RUNTIME_DIR="$(mktemp -d "${runtime_base}/.toolbelt-gws.XXXXXX")"

  if [[ -e "$GCLOUD_SRC" ]]; then
    gcloud_abs_source="$(abs_path "$GCLOUD_SRC")"
    if [[ -d "$gcloud_abs_source" && -f "${gcloud_abs_source}/application_default_credentials.json" ]]; then
      adc_dir="${GWS_RUNTIME_DIR}/gws-adc"
      mkdir -p "${adc_dir}"
      GWS_ADC_SOURCE="${adc_dir}/application_default_credentials.json"
      install -m 600 "${gcloud_abs_source}/application_default_credentials.json" "${GWS_ADC_SOURCE}"
    fi
  fi

  if command -v gws >/dev/null 2>&1; then
    export_dir="${GWS_RUNTIME_DIR}/gws-credentials"
    mkdir -p "${export_dir}"
    GWS_EXPORTED_CREDENTIALS="${export_dir}/credentials.json"
    export_log="${GWS_RUNTIME_DIR}/gws-auth-export.stderr"

    if gws auth export --unmasked >"${GWS_EXPORTED_CREDENTIALS}" 2>"${export_log}" && [[ -s "${GWS_EXPORTED_CREDENTIALS}" ]]; then
      chmod 600 "${GWS_EXPORTED_CREDENTIALS}" 2>/dev/null || true
    else
      if [[ -s "${export_log}" ]]; then
        GWS_EXPORT_ERROR="$(tr '\n' ' ' <"${export_log}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
      else
        GWS_EXPORT_ERROR="gws auth export failed"
      fi
      rm -f "${GWS_EXPORTED_CREDENTIALS}"
      GWS_EXPORTED_CREDENTIALS=""
    fi
  else
    GWS_EXPORT_ERROR="host gws command not found"
  fi

  if [[ -z "${GWS_EXPORTED_CREDENTIALS}" && -z "${GWS_ADC_SOURCE}" ]]; then
    echo "requested -gws/--gws but no portable Google Workspace credentials are available" >&2
    echo "gws auth login stores keyring-backed state on the host; mounting ${GWS_SRC} alone is not enough inside the container" >&2
    echo "try 'gws auth login' on the host so 'gws auth export --unmasked' succeeds, or run 'gcloud auth application-default login' to provide ADC" >&2
    if [[ -n "${GWS_EXPORT_ERROR}" ]]; then
      echo "gws export status: ${GWS_EXPORT_ERROR}" >&2
    fi
    exit 1
  fi
}

parse_args() {
  # Provider subcommand is required as the first positional argument.
  case "${1:-}" in
    codex)  PROVIDER="codex"; shift ;;
    claude) PROVIDER="claude"; shift ;;
    -h|-help|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: provider subcommand required (codex or claude)" >&2
      usage
      exit 1
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -docker|--docker)
        WITH_DOCKER_SOCK=1
        shift
        ;;
      -gcloud|--gcloud)
        WITH_GCLOUD=1
        shift
        ;;
      -gws|--gws)
        WITH_GWS=1
        shift
        ;;
      -opencode|--opencode)
        WITH_OPENCODE=1
        shift
        ;;
      -kimaki|--kimaki)
        WITH_OPENCODE=1
        WITH_KIMAKI=1
        shift
        ;;
      -k8s|--k8s)
        WITH_K8S=1
        shift
        ;;
      -github|--github)
        WITH_GITHUB=1
        shift
        ;;
      -gitlab|--gitlab)
        WITH_GITLAB=1
        shift
        ;;
      -image|--image)
        IMAGE="$2"
        shift 2
        ;;
      -workdir|--workdir|-w)
        WORKDIR="$2"
        shift 2
        ;;
      -shell|--shell)
        SHELL_CMD="$2"
        shift 2
        ;;
      -tmpfs-size|--tmpfs-size)
        TMPFS_SIZE="$2"
        shift 2
        ;;
      -keep|--keep)
        AUTO_REMOVE=0
        shift
        ;;
      --)
        shift
        CMD=("$@")
        break
        ;;
      -h|-help|--help)
        usage
        exit 0
        ;;
      -*)
        echo "unknown option: $1" >&2
        usage
        exit 1
        ;;
      *)
        MOUNTS+=("$1")
        shift
        ;;
    esac
  done
}

build_mount_args() {
  local source abs_source dest_name dest_path
  local gcloud_abs_source gws_abs_source opencode_abs_source kimaki_abs_source kubeconfig_abs_source runtime_secret_dir
  local idx=0
  local -A seen_dest=()
  local -a args=()

  for source in "${MOUNTS[@]}"; do
    abs_source="$(abs_path "$source")"
    if [[ ! -e "$abs_source" ]]; then
      echo "mount path not found: $source" >&2
      exit 1
    fi

    # Mount at the same absolute path as on the host so path references
    # (configs, error messages, git hooks) remain valid inside the container.
    dest_path="${abs_source}"

    if [[ -n "${seen_dest[$dest_path]:-}" ]]; then
      echo "mount destination collision at ${dest_path}: $source and ${seen_dest[$dest_path]}" >&2
      echo "use paths with unique basenames" >&2
      exit 1
    fi
    seen_dest["$dest_path"]="$source"

    args+=( -v "${abs_source}:${dest_path}" )
    idx=$((idx + 1))
  done

  if [[ "$PROVIDER" == "codex" ]]; then
    if [[ -f "$AUTH_SRC" ]]; then
      args+=( -v "${AUTH_SRC}:/run/secrets/codex-auth.json:ro" )
    fi
    if [[ -f "$CONFIG_SRC" ]]; then
      args+=( -v "${CONFIG_SRC}:/run/secrets/codex-config.toml:ro" )
    fi
  elif [[ "$PROVIDER" == "claude" ]]; then
    local claude_abs_source claude_json_abs_source
    claude_abs_source="$(abs_path "$CLAUDE_DIR_SRC")"
    if [[ -d "$claude_abs_source" ]]; then
      args+=( -v "${claude_abs_source}:${HOME}/.claude" )
    fi
    claude_json_abs_source="$(abs_path "$CLAUDE_JSON_SRC")"
    if [[ -f "$claude_json_abs_source" ]]; then
      args+=( -v "${claude_json_abs_source}:/run/secrets/claude-config.json:ro" )
    fi
  fi

  if [[ "$WITH_DOCKER_SOCK" -eq 1 ]]; then
    if [[ ! -S /var/run/docker.sock ]]; then
      echo "requested -docker/--docker but /var/run/docker.sock is not available" >&2
      exit 1
    fi
    args+=( -v /var/run/docker.sock:/var/run/docker.sock )
  fi

  if [[ "$WITH_GCLOUD" -eq 1 ]]; then
    gcloud_abs_source="$(abs_path "$GCLOUD_SRC")"
    if [[ ! -d "$gcloud_abs_source" ]]; then
      echo "requested -gcloud/--gcloud but gcloud config directory is not available: $GCLOUD_SRC" >&2
      exit 1
    fi
    args+=( -v "${gcloud_abs_source}:/run/secrets/gcloud-config:ro" )
  fi

  if [[ "$WITH_GWS" -eq 1 ]]; then
    gws_abs_source="$(abs_path "$GWS_SRC")"
    args+=( -v "${gws_abs_source}:/run/secrets/gws-config:ro" )
    if [[ -n "${GWS_EXPORTED_CREDENTIALS}" ]]; then
      runtime_secret_dir="$(dirname "${GWS_EXPORTED_CREDENTIALS}")"
      args+=( -v "${runtime_secret_dir}:${GWS_CREDENTIALS_MOUNT}:ro" )
    fi
    if [[ -n "${GWS_ADC_SOURCE}" ]]; then
      runtime_secret_dir="$(dirname "${GWS_ADC_SOURCE}")"
      args+=( -v "${runtime_secret_dir}:${GWS_ADC_MOUNT}:ro" )
    fi
  fi

  opencode_abs_source="$(abs_path "$OPENCODE_CONFIG_SRC")"
  if [[ -d "$opencode_abs_source" ]]; then
    args+=( -v "${opencode_abs_source}:${OPENCODE_CONFIG_MOUNT}:ro" )
  elif [[ "$WITH_OPENCODE" -eq 1 ]]; then
    if [[ "$WITH_KIMAKI" -eq 1 ]]; then
      echo "requested -opencode/--opencode (implicitly via -kimaki/--kimaki) but OpenCode config directory is not available: $OPENCODE_CONFIG_SRC" >&2
    else
      echo "requested -opencode/--opencode but OpenCode config directory is not available: $OPENCODE_CONFIG_SRC" >&2
    fi
    exit 1
  fi

  if [[ "$WITH_KIMAKI" -eq 1 ]]; then
    kimaki_abs_source="$(abs_path "$KIMAKI_SRC")"
    if [[ ! -d "$kimaki_abs_source" ]]; then
      echo "requested -kimaki/--kimaki but Kimaki data directory is not available: $KIMAKI_SRC" >&2
      exit 1
    fi
    args+=( -v "${kimaki_abs_source}:/home/coder/.kimaki" )
  fi

  if [[ "$WITH_K8S" -eq 1 ]]; then
    kubeconfig_abs_source="$(abs_path "$KUBECONFIG_SRC")"
    if [[ ! -f "$kubeconfig_abs_source" ]]; then
      echo "requested -k8s/--k8s but kubeconfig file is not available: $KUBECONFIG_SRC" >&2
      exit 1
    fi
    args+=( -v "${kubeconfig_abs_source}:/run/secrets/kube-config:ro" )
  fi

  if [[ "$WITH_GITHUB" -eq 1 ]]; then
    local github_abs_source
    github_abs_source="$(abs_path "$GITHUB_CONFIG_SRC")"
    if [[ ! -d "$github_abs_source" ]]; then
      echo "requested -github/--github but GitHub CLI config directory is not available: $GITHUB_CONFIG_SRC" >&2
      exit 1
    fi
    args+=( -v "${github_abs_source}:/run/secrets/gh-config:ro" )
  fi

  if [[ "$WITH_GITLAB" -eq 1 ]]; then
    local gitlab_abs_source
    gitlab_abs_source="$(abs_path "$GITLAB_CONFIG_SRC")"
    if [[ ! -d "$gitlab_abs_source" ]]; then
      echo "requested -gitlab/--gitlab but GitLab CLI config directory is not available: $GITLAB_CONFIG_SRC" >&2
      exit 1
    fi
    args+=( -v "${gitlab_abs_source}:/run/secrets/glab-config:ro" )
  fi

  printf '%s\n' "${args[@]}"
}

build_env_args() {
  local -a args=()

  args+=( -e "TOOLBELT_PROVIDER=${PROVIDER}" )
  args+=( -e "TOOLBELT_HOST_HOME=${HOME}" )

  if [[ "$PROVIDER" == "claude" ]]; then
    local claude_oauth_token=""
    if [[ -n "${ANTHROPIC_API_KEY_VALUE}" ]]; then
      args+=( -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY_VALUE}" )
    elif claude_oauth_token="$(extract_claude_oauth_token)"; then
      args+=( -e "CLAUDE_CODE_OAUTH_TOKEN=${claude_oauth_token}" )
    else
      warn "no ANTHROPIC_API_KEY set and could not extract Claude OAuth token from keychain"
    fi
  fi

  if [[ -n "${GWS_EXPORTED_CREDENTIALS}" ]]; then
    args+=( -e "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=${GWS_CREDENTIALS_DEST}" )
  fi

  if [[ -n "${GWS_ADC_SOURCE}" ]]; then
    args+=( -e "GOOGLE_APPLICATION_CREDENTIALS=${GWS_ADC_DEST}" )
  fi

  printf '%s\n' "${args[@]}"
}

run_container() {
  local -a run_args=()
  local -a mount_args=()
  local -a env_args=()
  local mount_output
  local env_output
  local line

  prepare_gws_runtime_inputs
  preflight_gws_scope_requirements
  mount_output="$(build_mount_args)"
  env_output="$(build_env_args)"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    mount_args+=("$line")
  done <<<"$mount_output"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    env_args+=("$line")
  done <<<"$env_output"

  run_args+=(
    run
    -w "$WORKDIR"
  )

  if [[ "$PROVIDER" == "codex" ]]; then
    run_args+=( --tmpfs "/home/coder/.codex:rw,nosuid,nodev,size=${TMPFS_SIZE}" )
  fi

  if [[ "$AUTO_REMOVE" -eq 1 ]]; then
    run_args+=( --rm )
  fi

  if [[ -t 0 && -t 1 ]]; then
    run_args+=( -it )
  else
    run_args+=( -i )
  fi

  run_args+=( "${mount_args[@]}" )
  run_args+=( "${env_args[@]}" )

  if [[ ${#CMD[@]} -eq 0 ]]; then
    CMD=("$SHELL_CMD")
  fi

  docker "${run_args[@]}" "$IMAGE" "${CMD[@]}"
}

main() {
  trap cleanup_runtime_artifacts EXIT
  parse_args "$@"

  if [[ ${#MOUNTS[@]} -eq 0 ]]; then
    MOUNTS+=("$(pwd)")
    MOUNT_PWD_TO_WORKSPACE=1
    WORKDIR="$(pwd)"
  fi

  require_docker
  run_container
}

main "$@"
