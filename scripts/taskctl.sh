#!/usr/bin/env bash
set -euo pipefail

ROOT="coordination"
TEMPLATE="$ROOT/templates/TASK_TEMPLATE.md"
DATE_NOW="$(date +%F)"

usage() {
  cat <<USAGE
Usage:
  $0 create <TASK_ID> <TITLE>
  $0 assign <TASK_ID> <agent>
  $0 claim <agent>
  $0 done <agent> <TASK_ID>
  $0 block <agent> <TASK_ID> <REASON>
  $0 list [agent]

Agents: coordinator, db, be, fe, review
USAGE
}

require_agent() {
  local agent="$1"
  case "$agent" in
    coordinator|db|be|fe|review) ;;
    *) echo "invalid agent: $agent" >&2; exit 1 ;;
  esac
}

set_field() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^${key}:" "$file"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
  else
    echo "${key}: ${value}" >>"$file"
  fi
}

find_task() {
  local task_id="$1"
  find "$ROOT" -type f -name "${task_id}.md" | head -n1
}

create_task() {
  local task_id="$1"
  local title="$2"
  local out="$ROOT/inbox/coordinator/${task_id}.md"

  [[ -f "$TEMPLATE" ]] || { echo "missing template: $TEMPLATE" >&2; exit 1; }
  [[ ! -e "$out" ]] || { echo "task already exists: $out" >&2; exit 1; }

  cp "$TEMPLATE" "$out"
  set_field "$out" "id" "$task_id"
  set_field "$out" "title" "$title"
  set_field "$out" "owner_agent" "coordinator"
  set_field "$out" "status" "inbox"
  set_field "$out" "created_at" "$DATE_NOW"
  set_field "$out" "updated_at" "$DATE_NOW"
  echo "created $out"
}

assign_task() {
  local task_id="$1"
  local agent="$2"
  require_agent "$agent"
  [[ "$agent" != "coordinator" ]] || { echo "assign target cannot be coordinator" >&2; exit 1; }

  local src="$ROOT/inbox/coordinator/${task_id}.md"
  local dst="$ROOT/inbox/${agent}/${task_id}.md"
  [[ -f "$src" ]] || { echo "not found in coordinator inbox: $src" >&2; exit 1; }

  mv "$src" "$dst"
  set_field "$dst" "owner_agent" "$agent"
  set_field "$dst" "status" "inbox"
  set_field "$dst" "updated_at" "$DATE_NOW"
  echo "assigned $task_id -> $agent"
}

claim_task() {
  local agent="$1"
  require_agent "$agent"
  [[ "$agent" != "coordinator" ]] || { echo "coordinator does not claim tasks" >&2; exit 1; }

  local next
  next="$(find "$ROOT/inbox/$agent" -maxdepth 1 -type f -name 'TASK-*.md' | sort | head -n1)"
  [[ -n "$next" ]] || { echo "no tasks in inbox/$agent"; exit 0; }

  local base
  base="$(basename "$next")"
  local dst="$ROOT/in_progress/$agent/$base"
  mv "$next" "$dst"
  set_field "$dst" "status" "in_progress"
  set_field "$dst" "updated_at" "$DATE_NOW"
  echo "claimed $base"
}

transition_task() {
  local action="$1"
  local agent="$2"
  local task_id="$3"
  local reason="${4:-}"
  require_agent "$agent"

  local src="$ROOT/in_progress/$agent/${task_id}.md"
  [[ -f "$src" ]] || { echo "task not in progress for $agent: $src" >&2; exit 1; }

  local dst status
  if [[ "$action" == "done" ]]; then
    dst="$ROOT/done/$agent/${task_id}.md"
    status="done"
  else
    dst="$ROOT/blocked/$agent/${task_id}.md"
    status="blocked"
  fi

  mv "$src" "$dst"
  set_field "$dst" "status" "$status"
  set_field "$dst" "updated_at" "$DATE_NOW"

  if [[ "$action" == "block" ]]; then
    printf "\n## Blocked Reason\n%s\n" "$reason" >>"$dst"
  fi

  echo "$action $task_id for $agent"
}

list_tasks() {
  local agent="${1:-}"
  if [[ -n "$agent" ]]; then
    require_agent "$agent"
    find "$ROOT" -type f -path "*/$agent/*" -name 'TASK-*.md' | sort
  else
    find "$ROOT" -type f -name 'TASK-*.md' | sort
  fi
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    create)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      shift
      create_task "$1" "$2"
      ;;
    assign)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      assign_task "$2" "$3"
      ;;
    claim)
      [[ $# -eq 2 ]] || { usage; exit 1; }
      claim_task "$2"
      ;;
    done)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      transition_task done "$2" "$3"
      ;;
    block)
      [[ $# -ge 4 ]] || { usage; exit 1; }
      transition_task block "$2" "$3" "$4"
      ;;
    list)
      if [[ $# -eq 2 ]]; then
        list_tasks "$2"
      elif [[ $# -eq 1 ]]; then
        list_tasks
      else
        usage; exit 1
      fi
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
