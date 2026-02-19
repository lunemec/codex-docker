#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IMAGE="${CODEX_DEV_IMAGE:-codex-dev:toolbelt}"
DEFAULT_WORKSPACE="/workspace"
DEFAULT_PREFIX="${CODEX_DEV_NAME_PREFIX:-codex}"
DEFAULT_SHELL="${CODEX_DEV_SHELL:-bash}"

ACTION="up"
PROJECT_DIR=""
IMAGE="$DEFAULT_IMAGE"
CONTAINER_NAME=""
SHELL_CMD="$DEFAULT_SHELL"
DETACH=0
WITH_DOCKER_SOCK=1
AUTO_REMOVE=1
CMD=()

usage() {
  cat <<USAGE
Usage:
  $0 [up|attach|down|status] [PROJECT_DIR] [options] [-- CMD...]

Actions:
  up       Start project container; if already running, open shell in it.
  attach   Open shell in existing running container.
  down     Stop/remove container for project.
  status   Show container status for project.

Options:
  --project DIR        Project directory to mount (default: current dir)
  --image IMAGE        Container image (default: ${DEFAULT_IMAGE})
  --name NAME          Explicit container name (default: derived from project path)
  --shell SHELL        Shell for attach/up interactive mode (default: ${DEFAULT_SHELL})
  --detach             Start in background (for 'up')
  --no-docker-sock     Do not mount /var/run/docker.sock
  --keep               Do not use --rm (container remains after exit)
  -h, --help           Show this help

Examples:
  $0 up /path/to/project
  $0 up --project /path/to/project --image codex-dev:toolbelt
  $0 attach /path/to/project
  $0 down /path/to/project
  $0 up /path/to/project -- bash -lc 'scripts/agents_ctl.sh start'
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

sanitize_name() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$raw" ]] || raw="project"
  printf '%s' "$raw"
}

hash_path() {
  local path="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$path" | sha1sum | awk '{print $1}' | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$path" | shasum | awk '{print $1}' | cut -c1-8
  else
    cksum <<<"$path" | awk '{print $1}'
  fi
}

container_id_for_name() {
  local name="$1"
  docker ps -aq --filter "name=^/${name}$"
}

container_running_for_name() {
  local name="$1"
  local cid
  cid="$(container_id_for_name "$name")"
  [[ -n "$cid" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" == "true" ]]
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

resolve_project_and_name() {
  if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(pwd)"
  fi

  PROJECT_DIR="$(abs_path "$PROJECT_DIR")"
  [[ -d "$PROJECT_DIR" ]] || {
    echo "project directory not found: $PROJECT_DIR" >&2
    exit 1
  }

  if [[ -z "$CONTAINER_NAME" ]]; then
    local base
    base="$(sanitize_name "$(basename "$PROJECT_DIR")")"
    CONTAINER_NAME="${DEFAULT_PREFIX}-${base}-$(hash_path "$PROJECT_DIR")"
  fi
}

start_or_attach() {
  if container_running_for_name "$CONTAINER_NAME"; then
    if [[ "$DETACH" -eq 1 ]]; then
      echo "$CONTAINER_NAME already running"
      return 0
    fi
    exec docker exec -it "$CONTAINER_NAME" "$SHELL_CMD"
  fi

  local existing
  existing="$(container_id_for_name "$CONTAINER_NAME")"
  if [[ -n "$existing" ]]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
  fi

  local run_args=(
    run
    --name "$CONTAINER_NAME"
    -v "$PROJECT_DIR:$DEFAULT_WORKSPACE"
    -w "$DEFAULT_WORKSPACE"
  )

  if [[ "$WITH_DOCKER_SOCK" -eq 1 ]] && [[ -S /var/run/docker.sock ]]; then
    run_args+=( -v /var/run/docker.sock:/var/run/docker.sock )
  fi

  if [[ "$AUTO_REMOVE" -eq 1 ]]; then
    run_args+=( --rm )
  fi

  if [[ "$DETACH" -eq 1 ]]; then
    run_args+=( -d )
  else
    run_args+=( -it )
  fi

  local command=("${CMD[@]}")
  if [[ ${#command[@]} -eq 0 ]]; then
    if [[ "$DETACH" -eq 1 ]]; then
      command=(bash -lc "while sleep 3600; do :; done")
    else
      command=("$SHELL_CMD")
    fi
  fi

  docker "${run_args[@]}" "$IMAGE" "${command[@]}"
}

attach_container() {
  if ! container_running_for_name "$CONTAINER_NAME"; then
    echo "container not running: $CONTAINER_NAME" >&2
    echo "start it with: $0 up --project '$PROJECT_DIR'" >&2
    exit 1
  fi

  exec docker exec -it "$CONTAINER_NAME" "$SHELL_CMD"
}

down_container() {
  local cid
  cid="$(container_id_for_name "$CONTAINER_NAME")"
  if [[ -z "$cid" ]]; then
    echo "container not found: $CONTAINER_NAME"
    return 0
  fi

  docker rm -f "$CONTAINER_NAME" >/dev/null
  echo "removed $CONTAINER_NAME"
}

status_container() {
  local cid
  cid="$(container_id_for_name "$CONTAINER_NAME")"
  if [[ -z "$cid" ]]; then
    echo "$CONTAINER_NAME: not_found"
    return 0
  fi

  local state image mounted
  state="$(docker inspect -f '{{.State.Status}}' "$cid")"
  image="$(docker inspect -f '{{.Config.Image}}' "$cid")"
  mounted="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination \"/workspace\"}}{{.Source}}{{end}}{{end}}' "$cid")"

  echo "$CONTAINER_NAME: state=$state image=$image workspace=${mounted:-none}"
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      up|attach|down|status)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        PROJECT_DIR="$2"
        shift 2
        ;;
      --image)
        IMAGE="$2"
        shift 2
        ;;
      --name)
        CONTAINER_NAME="$2"
        shift 2
        ;;
      --shell)
        SHELL_CMD="$2"
        shift 2
        ;;
      --detach)
        DETACH=1
        shift
        ;;
      --no-docker-sock)
        WITH_DOCKER_SOCK=0
        shift
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
      *)
        if [[ -z "$PROJECT_DIR" ]]; then
          PROJECT_DIR="$1"
          shift
        else
          echo "unknown argument: $1" >&2
          usage
          exit 1
        fi
        ;;
    esac
  done

  if [[ "$ACTION" != "up" && "$DETACH" -eq 1 ]]; then
    echo "--detach is only valid for 'up'" >&2
    exit 1
  fi

  if [[ "$ACTION" != "up" && ${#CMD[@]} -gt 0 ]]; then
    echo "custom command is only valid for 'up'" >&2
    exit 1
  fi
}

main() {
  parse_args "$@"
  require_docker
  resolve_project_and_name

  case "$ACTION" in
    up)
      start_or_attach
      ;;
    attach)
      attach_container
      ;;
    down)
      down_container
      ;;
    status)
      status_container
      ;;
  esac
}

main "$@"
