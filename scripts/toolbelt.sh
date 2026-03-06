#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IMAGE="${CODEX_DEV_IMAGE:-codex-dev:toolbelt}"
DEFAULT_SHELL="${CODEX_DEV_SHELL:-bash}"
DEFAULT_WORKDIR="/workspace"
DEFAULT_TMPFS_SIZE="${CODEX_TOOLBELT_TMPFS_SIZE:-512m}"

IMAGE="$DEFAULT_IMAGE"
WORKDIR="$DEFAULT_WORKDIR"
SHELL_CMD="$DEFAULT_SHELL"
WITH_DOCKER_SOCK=0
AUTO_REMOVE=1
TMPFS_SIZE="$DEFAULT_TMPFS_SIZE"
MOUNTS=()
MOUNT_PWD_TO_WORKSPACE=0
CMD=()
AUTH_SRC="${CODEX_AUTH_JSON_SRC:-$HOME/.codex/auth.json}"
CONFIG_SRC="${CODEX_CONFIG_TOML_SRC:-$HOME/.codex/config.toml}"

usage() {
  cat <<'USAGE'
Usage:
  toolbelt [options] [directory1 directory2 ...] [-- CMD...]

Description:
  Run codex-dev:toolbelt with selective mounts.
  If no directories are provided, the current directory is mounted to /workspace.
  Each provided directory/path is mounted to /workspace/<basename(path)>.

Options:
  --docker            Mount /var/run/docker.sock
  --image IMAGE       Container image (default: codex-dev:toolbelt)
  --workdir DIR       Container working directory (default: /workspace)
  --shell SHELL       Default interactive shell when no CMD is provided (default: bash)
  --tmpfs-size SIZE   /root/.codex tmpfs size (default: 512m)
  --keep              Keep container after exit (omit --rm)
  -h, --help          Show this help

Environment overrides:
  CODEX_DEV_IMAGE
  CODEX_DEV_SHELL
  CODEX_TOOLBELT_TMPFS_SIZE
  CODEX_AUTH_JSON_SRC
  CODEX_CONFIG_TOML_SRC

Examples:
  toolbelt
  toolbelt --docker ./directory1 ./directory2
  toolbelt ./directory1 ./directory2 -- bash -lc 'ls -la /workspace'
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --docker)
        WITH_DOCKER_SOCK=1
        shift
        ;;
      --image)
        IMAGE="$2"
        shift 2
        ;;
      --workdir|-w)
        WORKDIR="$2"
        shift 2
        ;;
      --shell)
        SHELL_CMD="$2"
        shift 2
        ;;
      --tmpfs-size)
        TMPFS_SIZE="$2"
        shift 2
        ;;
      --keep)
        AUTO_REMOVE=0
        shift
        ;;
      --)
        shift
        CMD=("$@")
        break
        ;;
      -h|--help)
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
  local idx=0
  local -A seen_dest=()
  local -a args=()

  for source in "${MOUNTS[@]}"; do
    abs_source="$(abs_path "$source")"
    if [[ ! -e "$abs_source" ]]; then
      echo "mount path not found: $source" >&2
      exit 1
    fi

    if [[ "$MOUNT_PWD_TO_WORKSPACE" -eq 1 && "$idx" -eq 0 ]]; then
      dest_path="/workspace"
    else
      dest_name="$(basename "$abs_source")"
      if [[ "$dest_name" == "." || "$dest_name" == "/" ]]; then
        echo "cannot derive mount name from: $source" >&2
        exit 1
      fi
      dest_path="/workspace/${dest_name}"
    fi

    if [[ -n "${seen_dest[$dest_path]:-}" ]]; then
      echo "mount destination collision at ${dest_path}: $source and ${seen_dest[$dest_path]}" >&2
      echo "use paths with unique basenames" >&2
      exit 1
    fi
    seen_dest["$dest_path"]="$source"

    args+=( -v "${abs_source}:${dest_path}" )
    idx=$((idx + 1))
  done

  if [[ -f "$AUTH_SRC" ]]; then
    args+=( -v "${AUTH_SRC}:/run/secrets/codex-auth.json:ro" )
  fi

  if [[ -f "$CONFIG_SRC" ]]; then
    args+=( -v "${CONFIG_SRC}:/run/secrets/codex-config.toml:ro" )
  fi

  if [[ "$WITH_DOCKER_SOCK" -eq 1 ]]; then
    if [[ ! -S /var/run/docker.sock ]]; then
      echo "requested --docker but /var/run/docker.sock is not available" >&2
      exit 1
    fi
    args+=( -v /var/run/docker.sock:/var/run/docker.sock )
  fi

  printf '%s\n' "${args[@]}"
}

run_container() {
  local -a run_args=()
  local -a mount_args=()
  local line

  while IFS= read -r line; do
    mount_args+=("$line")
  done < <(build_mount_args)

  run_args+=(
    run
    --tmpfs "/root/.codex:rw,nosuid,nodev,size=${TMPFS_SIZE}"
    -w "$WORKDIR"
  )

  if [[ "$AUTO_REMOVE" -eq 1 ]]; then
    run_args+=( --rm )
  fi

  if [[ -t 0 && -t 1 ]]; then
    run_args+=( -it )
  else
    run_args+=( -i )
  fi

  run_args+=( "${mount_args[@]}" )

  if [[ ${#CMD[@]} -eq 0 ]]; then
    CMD=("$SHELL_CMD")
  fi

  docker "${run_args[@]}" "$IMAGE" "${CMD[@]}"
}

main() {
  parse_args "$@"

  if [[ ${#MOUNTS[@]} -eq 0 ]]; then
    MOUNTS+=("$(pwd)")
    MOUNT_PWD_TO_WORKSPACE=1
  fi

  require_docker
  run_container
}

main "$@"
