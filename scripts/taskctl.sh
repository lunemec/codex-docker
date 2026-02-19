#!/usr/bin/env bash
set -euo pipefail

ROOT="${TASK_ROOT_DIR:-coordination}"
TEMPLATE="$ROOT/templates/TASK_TEMPLATE.md"
DEFAULT_OWNER_AGENT="${TASK_DEFAULT_OWNER:-pm}"
DEFAULT_CREATOR_AGENT="${TASK_DEFAULT_CREATOR:-pm}"
DEFAULT_PRIORITY="${TASK_DEFAULT_PRIORITY:-50}"

abs_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$path"
  else
    readlink -f "$path"
  fi
}

require_container_workspace() {
  [[ -f /.dockerenv ]] || {
    echo "taskctl must run inside Docker (.dockerenv not found)" >&2
    exit 1
  }

  local cwd
  cwd="$(pwd -P)"
  [[ "$cwd" == "/workspace" || "$cwd" == /workspace/* ]] || {
    echo "taskctl must run from /workspace (current: $cwd)" >&2
    exit 1
  }

  local root_abs
  root_abs="$(abs_path "$ROOT")"
  [[ "$root_abs" == "/workspace" || "$root_abs" == /workspace/* ]] || {
    echo "TASK_ROOT_DIR must resolve under /workspace (current: $root_abs)" >&2
    exit 1
  }
}

require_container_workspace

now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

usage() {
  cat <<USAGE
Usage:
  $0 create <TASK_ID> <TITLE> [--to <owner_agent>] [--from <creator_agent>] [--priority <N>] [--parent <TASK_ID>]
  $0 delegate <from_agent> <to_agent> <TASK_ID> <TITLE> [--priority <N>] [--parent <TASK_ID>]
  $0 assign <TASK_ID> <agent>
  $0 claim <agent>
  $0 done <agent> <TASK_ID> [NOTE]
  $0 block <agent> <TASK_ID> <REASON>
  $0 ensure-agent <agent> [--task <TASK_ID|TASK_FILE>] [--force]
  $0 list [agent]

Notes:
  - Lower priority number means higher urgency (0 is highest).
  - Blocked tasks are moved out of active queues and a blocker report task is queued for creator_agent.
  - Agents are dynamic skill names (examples: pm, designer, architect, fe, be, db, review).
  - ensure-agent creates role prompts when missing and refreshes when role prompt is unfit for the current task context.
USAGE
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

require_task_id() {
  local task_id="$1"
  [[ "$task_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "invalid task id: $task_id" >&2
    exit 1
  }
}

require_agent() {
  local agent="$1"
  [[ "$agent" == "system" || "$agent" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
    echo "invalid agent: $agent" >&2
    exit 1
  }
}

normalize_priority() {
  local priority="$1"
  is_integer "$priority" || {
    echo "priority must be an integer: $priority" >&2
    exit 1
  }
  (( priority >= 0 && priority <= 999 )) || {
    echo "priority out of range 0..999: $priority" >&2
    exit 1
  }
  printf '%d' "$priority"
}

pad_priority() {
  local priority
  priority="$(normalize_priority "$1")"
  printf '%03d' "$priority"
}

set_field() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -qE "^${key}:" "$file"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
  else
    sed -i "1 a ${key}: ${value}" "$file"
  fi
}

field_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}: //p" "$file" | head -n1
}

append_unique_word() {
  local current="${1:-}"
  local candidate="$2"

  if [[ " $current " == *" $candidate "* ]]; then
    printf '%s' "$current"
  else
    if [[ -n "$current" ]]; then
      printf '%s %s' "$current" "$candidate"
    else
      printf '%s' "$candidate"
    fi
  fi
}

text_matches() {
  local text="$1"
  local pattern="$2"
  printf '%s' "$text" | grep -qiE "$pattern"
}

resolve_task_file() {
  local ref="$1"

  if [[ -f "$ref" ]]; then
    printf '%s' "$ref"
    return 0
  fi

  if [[ -f "$ROOT/$ref" ]]; then
    printf '%s' "$ROOT/$ref"
    return 0
  fi

  if [[ "$ref" =~ ^[A-Za-z0-9._-]+$ ]]; then
    local found
    found="$(find "$ROOT" -type f -name "${ref}.md" \
      ! -path "$ROOT/examples/*" \
      ! -path "$ROOT/templates/*" \
      ! -path "$ROOT/roles/*" | head -n1)"

    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
  fi

  return 1
}

compute_file_hash() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    cksum "$file" | awk '{print $1}'
  fi
}

compute_fit_signature() {
  local agent="$1"
  local task_file="${2:-}"
  local tags_csv="$3"

  local source_hash="none"
  if [[ -n "$task_file" && -f "$task_file" ]]; then
    source_hash="$(compute_file_hash "$task_file")"
  fi

  local payload="${agent}|${tags_csv}|${source_hash}"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$payload" | cksum | awk '{print $1}'
  fi
}

role_current_signature() {
  local role_file="$1"
  sed -n 's/^<!-- fit_signature: \(.*\) -->$/\1/p' "$role_file" | head -n1
}

role_is_auto_managed() {
  local role_file="$1"
  grep -Fxq "<!-- role_profile: auto-generated -->" "$role_file"
}

role_has_required_sections() {
  local role_file="$1"
  local section

  for section in "Task-fit profile:" "Primary focus:" "Execution rules:" "Delegation rules:"; do
    if ! grep -Fxq "$section" "$role_file"; then
      return 1
    fi
  done

  return 0
}

role_mentions_tags() {
  local role_file="$1"
  local tags="$2"
  local tag

  for tag in $tags; do
    [[ "$tag" == "general" ]] && continue
    if ! grep -qi "$tag" "$role_file"; then
      return 1
    fi
  done

  return 0
}

role_unfit_for_task() {
  local role_file="$1"
  local expected_signature="$2"
  local tags="$3"

  [[ -f "$role_file" ]] || return 0
  role_has_required_sections "$role_file" || return 0

  if [[ -n "$expected_signature" ]]; then
    local current_signature
    current_signature="$(role_current_signature "$role_file")"

    if [[ -n "$current_signature" ]]; then
      [[ "$current_signature" == "$expected_signature" ]] || return 0
      return 1
    fi

    role_mentions_tags "$role_file" "$tags" || return 0
  fi

  return 1
}

infer_skill_tags() {
  local agent="$1"
  local task_file="${2:-}"

  local corpus="$agent"
  if [[ -n "$task_file" && -f "$task_file" ]]; then
    corpus="$corpus $(cat "$task_file")"
  fi
  corpus="$(printf '%s' "$corpus" | tr '[:upper:]' '[:lower:]')"

  local tags=""

  case "$agent" in
    pm|product|coordinator) tags="$(append_unique_word "$tags" "product")" ;;
    designer|design|ux|ui) tags="$(append_unique_word "$tags" "design")" ;;
    architect|architecture) tags="$(append_unique_word "$tags" "architecture")" ;;
    fe|frontend|front-end) tags="$(append_unique_word "$tags" "frontend")" ;;
    be|backend|back-end) tags="$(append_unique_word "$tags" "backend")" ;;
    db|database|data-store) tags="$(append_unique_word "$tags" "database")" ;;
    review|qa|tester|testing) tags="$(append_unique_word "$tags" "qa")" ;;
  esac

  if text_matches "$corpus" '(product|roadmap|scope|requirement|backlog|acceptance criteria|priorit)'; then
    tags="$(append_unique_word "$tags" "product")"
  fi
  if text_matches "$corpus" '(design|ux|ui|wireframe|prototype|figma|layout|copy)'; then
    tags="$(append_unique_word "$tags" "design")"
  fi
  if text_matches "$corpus" '(architect|architecture|system design|interface|contract|boundary|sequence)'; then
    tags="$(append_unique_word "$tags" "architecture")"
  fi
  if text_matches "$corpus" '(frontend|front-end|react|vue|svelte|angular|css|html|browser|component|client)'; then
    tags="$(append_unique_word "$tags" "frontend")"
  fi
  if text_matches "$corpus" '(backend|back-end|api|endpoint|server|service|handler|controller|grpc|rest)'; then
    tags="$(append_unique_word "$tags" "backend")"
  fi
  if text_matches "$corpus" '(database|db|sql|schema|migration|index|query|postgres|mysql|redis)'; then
    tags="$(append_unique_word "$tags" "database")"
  fi
  if text_matches "$corpus" '(qa|test|testing|e2e|integration|regression|review|verification|validate)'; then
    tags="$(append_unique_word "$tags" "qa")"
  fi
  if text_matches "$corpus" '(security|auth|authentication|authorization|permission|token|owasp|encrypt|vuln)'; then
    tags="$(append_unique_word "$tags" "security")"
  fi
  if text_matches "$corpus" '(deploy|deployment|infra|infrastructure|ci|cd|docker|kubernetes|helm|terraform|observability)'; then
    tags="$(append_unique_word "$tags" "infra")"
  fi
  if text_matches "$corpus" '(analytics|metric|tracking|event|etl|warehouse|model|reporting|dataset|pipeline)'; then
    tags="$(append_unique_word "$tags" "data")"
  fi

  if [[ -z "$tags" ]]; then
    tags="general"
  fi

  printf '%s\n' $tags
}

render_primary_focus_lines() {
  local tags="$1"
  local tag

  for tag in $tags; do
    case "$tag" in
      product)
        cat <<'EOF'
- Translate goals into explicit scope, constraints, and acceptance criteria.
- Prioritize work sequencing to reduce dependency churn.
EOF
        ;;
      design)
        cat <<'EOF'
- Define interaction flows, edge states, and accessible behavior.
- Produce implementation-ready guidance for FE work.
EOF
        ;;
      architecture)
        cat <<'EOF'
- Define system boundaries, contracts, and dependency order.
- Reduce cross-team ambiguity before implementation starts.
EOF
        ;;
      frontend)
        cat <<'EOF'
- Implement user-facing behavior with reliable state handling and API integration.
- Preserve usability and consistency across desktop/mobile surfaces.
EOF
        ;;
      backend)
        cat <<'EOF'
- Implement service logic, contracts, validation, and error handling.
- Keep API behavior deterministic and observable.
EOF
        ;;
      database)
        cat <<'EOF'
- Own schema/migration safety, constraints, and data integrity.
- Keep migrations reversible or clearly risk-documented.
EOF
        ;;
      qa)
        cat <<'EOF'
- Identify regressions, missing tests, and acceptance gaps.
- Report findings with reproducible evidence.
EOF
        ;;
      security)
        cat <<'EOF'
- Enforce authentication/authorization and secure data handling expectations.
- Surface abuse paths and sensitive-risk gaps early.
EOF
        ;;
      infra)
        cat <<'EOF'
- Ensure deployment/runtime readiness, observability, and operational safety.
- Keep rollout and rollback paths explicit.
EOF
        ;;
      data)
        cat <<'EOF'
- Ensure events/metrics/data contracts are explicit and trustworthy.
- Protect data quality for downstream analytics/reporting.
EOF
        ;;
      *)
        cat <<'EOF'
- Deliver the requested outcome for your skill area with minimal scope expansion.
EOF
        ;;
    esac
  done
}

render_verification_lines() {
  local tags="$1"
  local tag

  for tag in $tags; do
    case "$tag" in
      frontend)
        echo "- Run frontend lint/build/test commands relevant to touched files."
        ;;
      backend)
        echo "- Run backend unit/integration checks covering contract and error paths."
        ;;
      database)
        echo "- Validate migration/apply paths and schema compatibility assumptions."
        ;;
      qa)
        echo "- Verify reported findings against acceptance criteria and changed code paths."
        ;;
      infra)
        echo "- Validate deploy/runtime checks and any required operational smoke tests."
        ;;
      security)
        echo "- Verify auth/permission behavior and sensitive-path handling."
        ;;
      data)
        echo "- Validate event/data outputs and expected schema fields."
        ;;
      *)
        ;;
    esac
  done
}

render_delegation_lines() {
  local tags="$1"
  local tag

  for tag in $tags; do
    case "$tag" in
      product)
        echo "- Delegate implementation to specialist skills (designer/architect/fe/be/db/review) when deeper execution is needed."
        ;;
      design)
        echo "- Delegate build work to FE and escalate contract gaps to PM/architect."
        ;;
      architecture)
        echo "- Delegate build tasks to FE/BE/DB with explicit interfaces and dependency ordering."
        ;;
      frontend)
        echo "- Delegate backend/data-contract blockers to BE/DB or creator agent."
        ;;
      backend)
        echo "- Delegate schema concerns to DB and UI-impact follow-ups to FE when needed."
        ;;
      database)
        echo "- Delegate consumer contract alignment to BE/architect if usage assumptions are unclear."
        ;;
      qa)
        echo "- Delegate fixes to owning implementation agents with precise reproduction notes."
        ;;
      security)
        echo "- Delegate remediations to impacted FE/BE/infra owners with clear risk notes."
        ;;
      infra)
        echo "- Delegate service-specific code changes to owning FE/BE/DB agents."
        ;;
      data)
        echo "- Delegate instrumentation/contract fixes to FE/BE/DB owners as appropriate."
        ;;
      *)
        ;;
    esac
  done

  echo "- If blocked by ambiguity or missing dependency, stop and report blocker to creator agent."
}

generate_role_prompt() {
  local agent="$1"
  local role_file="$2"
  local task_file="${3:-}"
  local tags="$4"
  local tags_csv="$5"
  local fit_signature="$6"

  local fit_source="general"
  if [[ -n "$task_file" ]]; then
    fit_source="$task_file"
  fi

  cat >"$role_file" <<EOF
<!-- role_profile: auto-generated -->
<!-- role_agent: $agent -->
<!-- role_tags: $tags_csv -->
<!-- fit_signature: $fit_signature -->
<!-- fit_source: $fit_source -->
<!-- generated_at: $(now) -->

You are the $agent specialist agent.

Task-fit profile:
- skill: $agent
- inferred_domains: $tags_csv
- fit_source: $fit_source

Primary focus:
EOF

  render_primary_focus_lines "$tags" >>"$role_file"

  cat >>"$role_file" <<EOF

Execution rules:
- Keep scope limited to the active task and its acceptance criteria.
- Record implementation outcomes and exact verification commands in the task's \`## Result\` section.
- If blocked by dependency or ambiguity, stop immediately and report via \`scripts/taskctl.sh block $agent <TASK_ID> "reason"\`.
EOF

  render_verification_lines "$tags" >>"$role_file"

  cat >>"$role_file" <<'EOF'

Delegation rules:
EOF

  render_delegation_lines "$tags" >>"$role_file"

  cat >>"$role_file" <<'EOF'

Definition of done:
- Deliverables in the task are complete and acceptance criteria are met.
- Verification evidence is captured in the task result.
- Any required follow-up tasks are explicitly delegated with owner, priority, and parent linkage.
EOF
}

ensure_agent_scaffold() {
  local agent="$1"
  local task_ref="${2:-}"
  local force_refresh="${3:-0}"

  require_agent "$agent"
  [[ "$agent" == "system" ]] && return 0

  mkdir -p \
    "$ROOT/inbox/$agent" \
    "$ROOT/in_progress/$agent" \
    "$ROOT/done/$agent" \
    "$ROOT/blocked/$agent" \
    "$ROOT/reports/$agent" \
    "$ROOT/runtime/logs/$agent" \
    "$ROOT/runtime/pids" \
    "$ROOT/roles"

  local role_file="$ROOT/roles/$agent.md"

  local task_file=""
  if [[ -n "$task_ref" ]]; then
    if ! task_file="$(resolve_task_file "$task_ref")"; then
      echo "unable to resolve task reference: $task_ref" >&2
      return 1
    fi
  fi

  local tags
  tags="$(infer_skill_tags "$agent" "$task_file" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [[ -n "$tags" ]] || tags="general"

  local tags_csv
  tags_csv="${tags// /,}"

  local fit_signature
  fit_signature="$(compute_fit_signature "$agent" "$task_file" "$tags_csv")"

  local needs_refresh=0
  if [[ ! -f "$role_file" ]]; then
    needs_refresh=1
  elif [[ "$force_refresh" -eq 1 ]]; then
    needs_refresh=1
  elif role_unfit_for_task "$role_file" "$fit_signature" "$tags"; then
    needs_refresh=1
  fi

  if [[ "$needs_refresh" -eq 1 ]]; then
    if [[ -f "$role_file" ]] && ! role_is_auto_managed "$role_file"; then
      local backup_dir="$ROOT/runtime/role_backups/$agent"
      mkdir -p "$backup_dir"
      cp "$role_file" "$backup_dir/$(basename "$role_file").$(date +%Y%m%d%H%M%S).bak"
    fi

    generate_role_prompt "$agent" "$role_file" "$task_file" "$tags" "$tags_csv" "$fit_signature"
  fi
}

find_existing_task() {
  local task_id="$1"
  find "$ROOT" -type f -name "${task_id}.md" \
    ! -path "$ROOT/examples/*" \
    ! -path "$ROOT/templates/*" \
    ! -path "$ROOT/roles/*" | head -n1
}

create_task() {
  local task_id="$1"
  local title="$2"
  local owner="$3"
  local creator="$4"
  local priority="$5"
  local parent_task_id="${6:-}"

  require_task_id "$task_id"
  require_agent "$owner"
  require_agent "$creator"
  priority="$(normalize_priority "$priority")"

  [[ -f "$TEMPLATE" ]] || { echo "missing template: $TEMPLATE" >&2; exit 1; }

  local existing
  existing="$(find_existing_task "$task_id")"
  [[ -z "$existing" ]] || { echo "task already exists: $existing" >&2; exit 1; }

  ensure_agent_scaffold "$owner"
  ensure_agent_scaffold "$creator"

  local out_dir="$ROOT/inbox/$owner/$(pad_priority "$priority")"
  local out="$out_dir/${task_id}.md"
  mkdir -p "$out_dir"

  cp "$TEMPLATE" "$out"
  set_field "$out" "id" "$task_id"
  set_field "$out" "title" "$title"
  set_field "$out" "owner_agent" "$owner"
  set_field "$out" "creator_agent" "$creator"
  set_field "$out" "status" "inbox"
  set_field "$out" "priority" "$priority"
  set_field "$out" "created_at" "$(now)"
  set_field "$out" "updated_at" "$(now)"

  if [[ -n "$parent_task_id" ]]; then
    require_task_id "$parent_task_id"
    set_field "$out" "parent_task_id" "$parent_task_id"
    set_field "$out" "depends_on" "[$parent_task_id]"
  else
    set_field "$out" "parent_task_id" "none"
    set_field "$out" "depends_on" "[]"
  fi

  ensure_agent_scaffold "$owner" "$out"

  echo "created $out"
}

assign_task() {
  local task_id="$1"
  local target_agent="$2"
  require_task_id "$task_id"
  require_agent "$target_agent"

  ensure_agent_scaffold "$target_agent"

  local src
  src="$(find "$ROOT/inbox" -type f -name "${task_id}.md" | head -n1)"
  [[ -n "$src" ]] || { echo "task not found in inbox queues: $task_id" >&2; exit 1; }

  local priority
  priority="$(field_value "$src" "priority")"
  priority="${priority:-$DEFAULT_PRIORITY}"
  priority="$(normalize_priority "$priority")"

  local dst_dir="$ROOT/inbox/$target_agent/$(pad_priority "$priority")"
  local dst="$dst_dir/${task_id}.md"
  mkdir -p "$dst_dir"

  mv "$src" "$dst"
  set_field "$dst" "owner_agent" "$target_agent"
  set_field "$dst" "status" "inbox"
  set_field "$dst" "updated_at" "$(now)"

  ensure_agent_scaffold "$target_agent" "$dst"

  echo "assigned $task_id -> $target_agent"
}

claim_task() {
  local agent="$1"
  require_agent "$agent"
  [[ "$agent" != "system" ]] || { echo "system cannot claim tasks" >&2; exit 1; }

  ensure_agent_scaffold "$agent"

  local next
  next="$(find "$ROOT/inbox/$agent" -type f -name '*.md' | sort | head -n1)"
  [[ -n "$next" ]] || { echo "no tasks in inbox/$agent"; exit 0; }

  local base
  base="$(basename "$next")"
  local dst="$ROOT/in_progress/$agent/$base"

  mv "$next" "$dst"
  set_field "$dst" "status" "in_progress"
  set_field "$dst" "updated_at" "$(now)"

  ensure_agent_scaffold "$agent" "$dst"

  echo "claimed $base"
}

create_blocker_report() {
  local blocker_agent="$1"
  local blocked_task_file="$2"
  local blocked_task_id="$3"
  local reason="$4"

  local creator
  creator="$(field_value "$blocked_task_file" "creator_agent")"
  creator="${creator:-}"

  if [[ -z "$creator" || "$creator" == "none" || "$creator" == "system" ]]; then
    return 0
  fi

  local report_id="BLK-${blocked_task_id}-$(date +%Y%m%d%H%M%S%N)"
  local report_title="Blocker from ${blocker_agent}: ${blocked_task_id}"

  create_task "$report_id" "$report_title" "$creator" "system" 0 "$blocked_task_id"

  local report_file
  report_file="$(find "$ROOT/inbox/$creator" -type f -name "${report_id}.md" | head -n1)"
  [[ -n "$report_file" ]] || return 0

  cat >>"$report_file" <<REPORT_NOTE_EOF

## Blocker Details
- blocked_task: $blocked_task_id
- blocked_by: $blocker_agent
- creator_to_notify: $creator
- blocked_task_file: $blocked_task_file
- reason: $reason

## Requested Action
Resolve ambiguity/dependency, then create follow-up task(s) for the appropriate skill agent.
REPORT_NOTE_EOF
}

transition_task() {
  local action="$1"
  local agent="$2"
  local task_id="$3"
  local note="${4:-}"

  require_agent "$agent"
  require_task_id "$task_id"

  local src="$ROOT/in_progress/$agent/${task_id}.md"
  [[ -f "$src" ]] || { echo "task not in progress for $agent: $src" >&2; exit 1; }

  local priority
  priority="$(field_value "$src" "priority")"
  priority="${priority:-$DEFAULT_PRIORITY}"
  priority="$(normalize_priority "$priority")"
  local pdir
  pdir="$(pad_priority "$priority")"

  local dst_state status
  if [[ "$action" == "done" ]]; then
    dst_state="done"
    status="done"
  else
    dst_state="blocked"
    status="blocked"
  fi

  local dst_dir="$ROOT/$dst_state/$agent/$pdir"
  local dst="$dst_dir/${task_id}.md"
  mkdir -p "$dst_dir"

  mv "$src" "$dst"
  set_field "$dst" "status" "$status"
  set_field "$dst" "updated_at" "$(now)"

  if [[ -n "$note" ]]; then
    if [[ "$action" == "done" ]]; then
      printf "\n## Completion Note\n%s\n" "$note" >>"$dst"
    else
      printf "\n## Blocked Reason\n%s\n" "$note" >>"$dst"
    fi
  fi

  if [[ "$action" == "block" ]]; then
    create_blocker_report "$agent" "$dst" "$task_id" "$note"
  fi

  echo "$action $task_id for $agent"
}

list_tasks() {
  local agent="${1:-}"
  if [[ -n "$agent" ]]; then
    find "$ROOT" -type f -name '*.md' \
      \( -path "$ROOT/inbox/$agent/*" -o -path "$ROOT/in_progress/$agent/*" -o -path "$ROOT/done/$agent/*" -o -path "$ROOT/blocked/$agent/*" -o -path "$ROOT/reports/$agent/*" \) | sort
  else
    find "$ROOT" -type f -name '*.md' \
      \( -path "$ROOT/inbox/*" -o -path "$ROOT/in_progress/*" -o -path "$ROOT/done/*" -o -path "$ROOT/blocked/*" -o -path "$ROOT/reports/*" \) | sort
  fi
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    create)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      local task_id="$2"
      local title="$3"
      local owner="$DEFAULT_OWNER_AGENT"
      local creator="$DEFAULT_CREATOR_AGENT"
      local priority="$DEFAULT_PRIORITY"
      local parent=""
      shift 3

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --to)
            owner="$2"
            shift 2
            ;;
          --from)
            creator="$2"
            shift 2
            ;;
          --priority)
            priority="$2"
            shift 2
            ;;
          --parent)
            parent="$2"
            shift 2
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      create_task "$task_id" "$title" "$owner" "$creator" "$priority" "$parent"
      ;;
    delegate)
      [[ $# -ge 5 ]] || { usage; exit 1; }
      local from_agent="$2"
      local to_agent="$3"
      local task_id="$4"
      local title="$5"
      local priority="$DEFAULT_PRIORITY"
      local parent=""
      shift 5

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --priority)
            priority="$2"
            shift 2
            ;;
          --parent)
            parent="$2"
            shift 2
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      create_task "$task_id" "$title" "$to_agent" "$from_agent" "$priority" "$parent"
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
      [[ $# -ge 3 ]] || { usage; exit 1; }
      local note="${4:-}"
      transition_task done "$2" "$3" "$note"
      ;;
    block)
      [[ $# -ge 4 ]] || { usage; exit 1; }
      shift
      local agent="$1"
      local task_id="$2"
      shift 2
      local reason="$*"
      transition_task block "$agent" "$task_id" "$reason"
      ;;
    ensure-agent)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      local agent="$2"
      local task_ref=""
      local force_refresh=0
      shift 2

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --task)
            task_ref="$2"
            shift 2
            ;;
          --force)
            force_refresh=1
            shift
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      ensure_agent_scaffold "$agent" "$task_ref" "$force_refresh"
      if [[ -n "$task_ref" ]]; then
        echo "ensured agent scaffold: $agent (task-fit refresh checked)"
      else
        echo "ensured agent scaffold: $agent"
      fi
      ;;
    list)
      if [[ $# -eq 2 ]]; then
        list_tasks "$2"
      elif [[ $# -eq 1 ]]; then
        list_tasks
      else
        usage
        exit 1
      fi
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
