#!/usr/bin/env bash
set -euo pipefail

ROOT="${TASK_ROOT_DIR:-coordination}"
TEMPLATE="$ROOT/templates/TASK_TEMPLATE.md"
DEFAULT_BENCHMARK_PROFILE_PATH="$ROOT/benchmark_profiles/vault_sync_prompt_v1.json"
DEFAULT_BENCHMARK_SCORECARD_PATH="$ROOT/reports/coordinator/benchmark_scorecard.json"
DEFAULT_OWNER_AGENT="${TASK_DEFAULT_OWNER:-pm}"
DEFAULT_CREATOR_AGENT="${TASK_DEFAULT_CREATOR:-pm}"
DEFAULT_PRIORITY="${TASK_DEFAULT_PRIORITY:-50}"
DEFAULT_PHASE="${TASK_DEFAULT_PHASE:-plan}"
LOCK_ROOT="$ROOT/locks/files"
DEFAULT_LOCK_STALE_TTL_SECONDS="${TASK_LOCK_STALE_TTL_SECONDS:-3600}"
LOCK_REAPER_AGENTS_RAW="${TASK_LOCK_REAPER_AGENTS:-pm coordinator}"
DEFAULT_CODING_OWNER_LANES_RAW="fe,be,db"
CODING_OWNER_LANES_ENV_RAW="${TASK_CODING_OWNER_LANES:-$DEFAULT_CODING_OWNER_LANES_RAW}"
CODING_OWNER_LANES_OVERRIDE_RAW=""
VALID_TASK_PHASES_RAW="clarify research plan execute review closeout"

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
  $0 create <TASK_ID> <TITLE> [--to <owner_agent>] [--from <creator_agent>] [--priority <N>] [--parent <TASK_ID>] [--phase <task_phase>] [--write-target <path>]... [--coding-owner-lanes <agents>]
  $0 delegate <from_agent> <to_agent> <TASK_ID> <TITLE> [--priority <N>] [--parent <TASK_ID>] [--phase <task_phase>] [--write-target <path>]... [--coding-owner-lanes <agents>]
  $0 assign <TASK_ID> <agent> [--coding-owner-lanes <agents>]
  $0 claim <agent> [--coding-owner-lanes <agents>]
  $0 verify-done <agent> <TASK_ID>
  $0 benchmark-verify <agent> <TASK_ID> [--json]
  $0 benchmark-score <agent> <TASK_ID>
  $0 benchmark-closeout-check <agent> <TASK_ID>
  $0 done <agent> <TASK_ID> [NOTE]
  $0 block <agent> <TASK_ID> <REASON>
  $0 lock-acquire <TASK_ID> <owner_agent> <target>
  $0 lock-heartbeat <TASK_ID> <owner_agent> <target>
  $0 lock-release <TASK_ID> <owner_agent> <target>
  $0 lock-release-task <TASK_ID> <owner_agent>
  $0 lock-status <target>
  $0 lock-clean-stale [--ttl <seconds>] [--actor <agent>]
  $0 ensure-agent <agent> [--task <TASK_ID|TASK_FILE>] [--force]
  $0 list [agent]

Notes:
  - Lower priority number means higher urgency (0 is highest).
  - Blocked tasks are moved out of active queues and a blocker report task is queued for creator_agent.
  - Agents are dynamic skill names (examples: pm, designer, architect, fe, be, db, review).
  - Tasks owned by resolved coding-owner lanes must declare at least one --write-target path.
  - Coding-owner auto-target lanes default to "fe,be,db" (set TASK_CODING_OWNER_LANES; override once with --coding-owner-lanes).
  - Supported task phases: clarify, research, plan, execute, review, closeout.
  - done transitions run strict `verify-done` checks before moving tasks to done.
  - benchmark-* commands enforce profile-driven gates/scores and write scorecard artifacts for benchmark reviews.
  - lock-clean-stale requires orchestrator actor identity via --actor or TASK_ACTOR_AGENT.
  - Default stale-lock reaper lanes are "pm coordinator" (override with TASK_LOCK_REAPER_AGENTS).
  - ensure-agent creates role prompts when missing; existing role prompts are stable unless --force is used.
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

phase_in_valid_list() {
  local phase="$1"
  local item
  for item in $VALID_TASK_PHASES_RAW; do
    [[ "$phase" == "$item" ]] && return 0
  done
  return 1
}

normalize_phase_value() {
  local phase="${1:-}"
  phase="$(printf '%s' "$phase" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$phase" in
    ""|default)
      phase="$DEFAULT_PHASE"
      ;;
    planning)
      phase="plan"
      ;;
    execution)
      phase="execute"
      ;;
  esac

  phase_in_valid_list "$phase" || {
    echo "invalid task phase: $phase (expected one of: $VALID_TASK_PHASES_RAW)" >&2
    exit 1
  }
  printf '%s' "$phase"
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

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
}

normalize_ttl_seconds() {
  local ttl="$1"
  is_integer "$ttl" || {
    echo "ttl must be an integer (seconds): $ttl" >&2
    exit 1
  }
  (( ttl > 0 )) || {
    echo "ttl must be > 0 seconds: $ttl" >&2
    exit 1
  }
  printf '%d' "$ttl"
}

normalize_agent_list() {
  local raw="$1"
  raw="${raw//,/ }"
  printf '%s' "$raw" | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//'
}

set_coding_owner_lanes_override() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || {
    echo "--coding-owner-lanes requires a non-empty value" >&2
    exit 1
  }
  CODING_OWNER_LANES_OVERRIDE_RAW="$raw"
}

resolve_coding_owner_lanes() {
  local raw="$CODING_OWNER_LANES_ENV_RAW"
  if [[ -n "$CODING_OWNER_LANES_OVERRIDE_RAW" ]]; then
    raw="$CODING_OWNER_LANES_OVERRIDE_RAW"
  fi

  local normalized
  normalized="$(normalize_agent_list "$raw")"
  normalized="$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$normalized" ]] || normalized="$(normalize_agent_list "$DEFAULT_CODING_OWNER_LANES_RAW")"

  local deduped=""
  local lane
  for lane in $normalized; do
    require_agent "$lane"
    deduped="$(append_unique_word "$deduped" "$lane")"
  done

  printf '%s' "$deduped"
}

agent_in_space_list() {
  local needle="$1"
  local haystack="$2"
  local item
  for item in $haystack; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

require_lock_reap_actor_allowed() {
  local actor_agent="$1"
  local allowed_agents="$2"

  [[ -n "$actor_agent" ]] || {
    echo "lock-clean-stale requires actor identity (--actor <agent> or TASK_ACTOR_AGENT)" >&2
    return 1
  }

  require_agent "$actor_agent"

  [[ -n "$allowed_agents" ]] || {
    echo "lock-clean-stale has no allowed reaper lanes configured (TASK_LOCK_REAPER_AGENTS)" >&2
    return 1
  }

  if ! agent_in_space_list "$actor_agent" "$allowed_agents"; then
    echo "lock-clean-stale denied: actor_agent=$actor_agent allowed_reaper_agents=\"$allowed_agents\"" >&2
    return 2
  fi
}

canonicalize_target_path() {
  local target="$1"
  [[ -n "$target" ]] || {
    echo "target path must not be empty" >&2
    exit 1
  }

  local absolute_target
  if [[ "$target" == /* ]]; then
    absolute_target="$(abs_path "$target")"
  else
    absolute_target="$(abs_path "/workspace/$target")"
  fi

  [[ "$absolute_target" == "/workspace" || "$absolute_target" == /workspace/* ]] || {
    echo "target must resolve under /workspace: $target" >&2
    exit 1
  }

  if [[ "$absolute_target" == "/workspace" ]]; then
    printf '.'
  else
    printf '%s' "${absolute_target#/workspace/}"
  fi
}

compute_text_hash() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$value" | cksum | awk '{print $1}'
  fi
}

lock_path_for_canonical_target() {
  local canonical_target="$1"
  local target_hash
  target_hash="$(compute_text_hash "$canonical_target")"
  printf '%s/%s.lock' "$LOCK_ROOT" "$target_hash"
}

lock_path_for_target() {
  local target="$1"
  local canonical_target
  canonical_target="$(canonicalize_target_path "$target")"
  lock_path_for_canonical_target "$canonical_target"
}

ensure_lock_root() {
  mkdir -p "$LOCK_ROOT"
}

write_lock_payload_file() {
  local out_file="$1"
  local task_id="$2"
  local owner_agent="$3"
  local canonical_target="$4"
  local acquired_at="$5"
  local heartbeat_at="$6"

  require_command jq
  jq -cn \
    --arg task_id "$task_id" \
    --arg owner_agent "$owner_agent" \
    --arg canonical_target "$canonical_target" \
    --arg acquired_at "$acquired_at" \
    --arg heartbeat_at "$heartbeat_at" \
    '{
      task_id: $task_id,
      owner_agent: $owner_agent,
      canonical_target: $canonical_target,
      acquired_at: $acquired_at,
      heartbeat_at: $heartbeat_at
    }' >"$out_file"
}

create_lock_payload_file_atomic() {
  local lock_file="$1"
  local task_id="$2"
  local owner_agent="$3"
  local canonical_target="$4"
  local acquired_at="$5"
  local heartbeat_at="$6"

  ensure_lock_root
  local tmp_file
  tmp_file="$(mktemp "$LOCK_ROOT/.lock-create.XXXXXX")"
  write_lock_payload_file "$tmp_file" "$task_id" "$owner_agent" "$canonical_target" "$acquired_at" "$heartbeat_at"

  if ln "$tmp_file" "$lock_file" 2>/dev/null; then
    rm -f "$tmp_file"
    return 0
  fi

  rm -f "$tmp_file"
  return 1
}

read_lock_payload() {
  local lock_file="$1"
  [[ -f "$lock_file" ]] || return 1
  cat "$lock_file"
}

remove_lock_payload() {
  local lock_file="$1"
  rm -f "$lock_file"
}

lock_payload_field() {
  local lock_file="$1"
  local field="$2"
  require_command jq
  jq -r --arg field "$field" '.[$field] // ""' "$lock_file"
}

lock_owner_matches() {
  local lock_file="$1"
  local task_id="$2"
  local owner_agent="$3"
  [[ -f "$lock_file" ]] || return 1

  local existing_task_id existing_owner
  existing_task_id="$(lock_payload_field "$lock_file" "task_id" 2>/dev/null || true)"
  existing_owner="$(lock_payload_field "$lock_file" "owner_agent" 2>/dev/null || true)"
  [[ "$existing_task_id" == "$task_id" && "$existing_owner" == "$owner_agent" ]]
}

lock_acquire() {
  local task_id="$1"
  local owner_agent="$2"
  local target="$3"

  require_task_id "$task_id"
  require_agent "$owner_agent"

  local canonical_target lock_file timestamp
  canonical_target="$(canonicalize_target_path "$target")"
  lock_file="$(lock_path_for_canonical_target "$canonical_target")"
  timestamp="$(now)"

  ensure_lock_root

  if [[ -f "$lock_file" ]]; then
    if lock_owner_matches "$lock_file" "$task_id" "$owner_agent"; then
      local acquired_at
      acquired_at="$(lock_payload_field "$lock_file" "acquired_at" 2>/dev/null || true)"
      acquired_at="${acquired_at:-$timestamp}"
      write_lock_payload_file "$lock_file" "$task_id" "$owner_agent" "$canonical_target" "$acquired_at" "$timestamp"
      echo "lock already held: target=$canonical_target task_id=$task_id owner_agent=$owner_agent"
      return 0
    fi

    local holder_task holder_owner
    holder_task="$(lock_payload_field "$lock_file" "task_id" 2>/dev/null || true)"
    holder_owner="$(lock_payload_field "$lock_file" "owner_agent" 2>/dev/null || true)"
    echo "lock conflict: target=$canonical_target holder_task_id=${holder_task:-unknown} holder_owner_agent=${holder_owner:-unknown}" >&2
    return 2
  fi

  if create_lock_payload_file_atomic "$lock_file" "$task_id" "$owner_agent" "$canonical_target" "$timestamp" "$timestamp"; then
    echo "lock acquired: target=$canonical_target task_id=$task_id owner_agent=$owner_agent"
    return 0
  fi

  if [[ -f "$lock_file" ]] && lock_owner_matches "$lock_file" "$task_id" "$owner_agent"; then
    echo "lock already held: target=$canonical_target task_id=$task_id owner_agent=$owner_agent"
    return 0
  fi

  local holder_task holder_owner
  holder_task="$(lock_payload_field "$lock_file" "task_id" 2>/dev/null || true)"
  holder_owner="$(lock_payload_field "$lock_file" "owner_agent" 2>/dev/null || true)"
  echo "lock conflict: target=$canonical_target holder_task_id=${holder_task:-unknown} holder_owner_agent=${holder_owner:-unknown}" >&2
  return 2
}

lock_heartbeat() {
  local task_id="$1"
  local owner_agent="$2"
  local target="$3"

  require_task_id "$task_id"
  require_agent "$owner_agent"

  local canonical_target lock_file
  canonical_target="$(canonicalize_target_path "$target")"
  lock_file="$(lock_path_for_canonical_target "$canonical_target")"

  [[ -f "$lock_file" ]] || {
    echo "lock not found for heartbeat: target=$canonical_target" >&2
    return 1
  }

  if ! lock_owner_matches "$lock_file" "$task_id" "$owner_agent"; then
    local holder_task holder_owner
    holder_task="$(lock_payload_field "$lock_file" "task_id" 2>/dev/null || true)"
    holder_owner="$(lock_payload_field "$lock_file" "owner_agent" 2>/dev/null || true)"
    echo "lock heartbeat denied: target=$canonical_target holder_task_id=${holder_task:-unknown} holder_owner_agent=${holder_owner:-unknown}" >&2
    return 2
  fi

  local acquired_at
  acquired_at="$(lock_payload_field "$lock_file" "acquired_at" 2>/dev/null || true)"
  acquired_at="${acquired_at:-$(now)}"
  write_lock_payload_file "$lock_file" "$task_id" "$owner_agent" "$canonical_target" "$acquired_at" "$(now)"
  echo "lock heartbeat updated: target=$canonical_target task_id=$task_id owner_agent=$owner_agent"
}

lock_release() {
  local task_id="$1"
  local owner_agent="$2"
  local target="$3"

  require_task_id "$task_id"
  require_agent "$owner_agent"

  local canonical_target lock_file
  canonical_target="$(canonicalize_target_path "$target")"
  lock_file="$(lock_path_for_canonical_target "$canonical_target")"

  if [[ ! -f "$lock_file" ]]; then
    echo "lock already clear: target=$canonical_target"
    return 0
  fi

  if ! lock_owner_matches "$lock_file" "$task_id" "$owner_agent"; then
    local holder_task holder_owner
    holder_task="$(lock_payload_field "$lock_file" "task_id" 2>/dev/null || true)"
    holder_owner="$(lock_payload_field "$lock_file" "owner_agent" 2>/dev/null || true)"
    echo "lock release denied: target=$canonical_target holder_task_id=${holder_task:-unknown} holder_owner_agent=${holder_owner:-unknown}" >&2
    return 2
  fi

  remove_lock_payload "$lock_file"
  echo "lock released: target=$canonical_target task_id=$task_id owner_agent=$owner_agent"
}

lock_release_task() {
  local task_id="$1"
  local owner_agent="$2"

  require_task_id "$task_id"
  require_agent "$owner_agent"

  ensure_lock_root

  local released=0
  local lock_file
  shopt -s nullglob
  for lock_file in "$LOCK_ROOT"/*.lock; do
    if lock_owner_matches "$lock_file" "$task_id" "$owner_agent"; then
      remove_lock_payload "$lock_file"
      released=$((released + 1))
    fi
  done
  shopt -u nullglob

  echo "lock-release-task: task_id=$task_id owner_agent=$owner_agent released=$released"
}

timestamp_to_epoch() {
  local timestamp="$1"
  date -d "$timestamp" '+%s'
}

lock_is_stale() {
  local lock_file="$1"
  local ttl_seconds="$2"
  local now_epoch="$3"

  local heartbeat_at acquired_at reference_ts
  heartbeat_at="$(lock_payload_field "$lock_file" "heartbeat_at" 2>/dev/null || true)"
  acquired_at="$(lock_payload_field "$lock_file" "acquired_at" 2>/dev/null || true)"
  reference_ts="${heartbeat_at:-$acquired_at}"

  [[ -n "$reference_ts" ]] || return 0

  local reference_epoch
  reference_epoch="$(timestamp_to_epoch "$reference_ts" 2>/dev/null || true)"
  [[ -n "$reference_epoch" ]] || return 0

  local age
  age=$((now_epoch - reference_epoch))
  (( age > ttl_seconds ))
}

write_lock_reap_audit_report() {
  local actor_agent="$1"
  local lock_file="$2"
  local ttl_seconds="$3"
  local now_epoch="$4"

  local task_id owner_agent canonical_target acquired_at heartbeat_at
  task_id="$(lock_payload_field "$lock_file" "task_id" 2>/dev/null || true)"
  owner_agent="$(lock_payload_field "$lock_file" "owner_agent" 2>/dev/null || true)"
  canonical_target="$(lock_payload_field "$lock_file" "canonical_target" 2>/dev/null || true)"
  acquired_at="$(lock_payload_field "$lock_file" "acquired_at" 2>/dev/null || true)"
  heartbeat_at="$(lock_payload_field "$lock_file" "heartbeat_at" 2>/dev/null || true)"

  local reference_ts reference_epoch age_seconds
  reference_ts="${heartbeat_at:-$acquired_at}"
  age_seconds=""
  if [[ -n "$reference_ts" ]]; then
    reference_epoch="$(timestamp_to_epoch "$reference_ts" 2>/dev/null || true)"
    if [[ -n "$reference_epoch" ]]; then
      age_seconds=$((now_epoch - reference_epoch))
    fi
  fi

  local report_dir report_file
  report_dir="$ROOT/reports/$actor_agent"
  mkdir -p "$report_dir"
  report_file="$report_dir/LOCK-REAP-$(date +%Y%m%d%H%M%S%N).md"

  cat >"$report_file" <<EOF
# Lock Reap Audit

- action: lock-clean-stale
- actor_agent: $actor_agent
- reaped_at: $(now)
- ttl_seconds: $ttl_seconds
- lock_file: $lock_file
- canonical_target: ${canonical_target:-unknown}
- task_id: ${task_id:-unknown}
- owner_agent: ${owner_agent:-unknown}
- acquired_at: ${acquired_at:-unknown}
- heartbeat_at: ${heartbeat_at:-unknown}
- stale_age_seconds: ${age_seconds:-unknown}
EOF

  printf '%s' "$report_file"
}

lock_status() {
  local target="$1"
  local canonical_target lock_file
  canonical_target="$(canonicalize_target_path "$target")"
  lock_file="$(lock_path_for_canonical_target "$canonical_target")"

  echo "canonical_target: $canonical_target"
  echo "lock_file: $lock_file"

  if [[ ! -f "$lock_file" ]]; then
    echo "status: unlocked"
    return 0
  fi

  echo "status: locked"
  read_lock_payload "$lock_file"
}

lock_clean_stale() {
  local ttl_seconds="$1"
  local actor_agent="${2:-${TASK_ACTOR_AGENT:-}}"
  ttl_seconds="$(normalize_ttl_seconds "$ttl_seconds")"

  local allowed_reaper_agents
  allowed_reaper_agents="$(normalize_agent_list "$LOCK_REAPER_AGENTS_RAW")"
  require_lock_reap_actor_allowed "$actor_agent" "$allowed_reaper_agents" || return $?

  ensure_lock_root
  local now_epoch
  now_epoch="$(date '+%s')"

  local scanned=0
  local removed=0
  local kept=0

  local lock_file
  shopt -s nullglob
  for lock_file in "$LOCK_ROOT"/*.lock; do
    scanned=$((scanned + 1))
    if lock_is_stale "$lock_file" "$ttl_seconds" "$now_epoch"; then
      local canonical_target report_file
      canonical_target="$(lock_payload_field "$lock_file" "canonical_target" 2>/dev/null || true)"
      report_file="$(write_lock_reap_audit_report "$actor_agent" "$lock_file" "$ttl_seconds" "$now_epoch")"
      remove_lock_payload "$lock_file"
      removed=$((removed + 1))
      echo "reaped lock: file=$lock_file canonical_target=${canonical_target:-unknown} actor_agent=$actor_agent audit_report=$report_file"
    else
      kept=$((kept + 1))
    fi
  done
  shopt -u nullglob

  echo "lock-clean-stale summary: actor_agent=$actor_agent scanned=$scanned removed=$removed kept=$kept ttl_seconds=$ttl_seconds"
}

extract_frontmatter_to_file() {
  local source_file="$1"
  local out_file="$2"
  awk '
    BEGIN { section = 0 }
    /^---$/ { section++; next }
    section == 1 { print }
    section >= 2 { exit }
  ' "$source_file" >"$out_file"
}

task_intended_write_target_count() {
  local task_file="$1"
  require_command yq

  local frontmatter_file
  frontmatter_file="$(mktemp)"
  extract_frontmatter_to_file "$task_file" "$frontmatter_file"

  if [[ ! -s "$frontmatter_file" ]]; then
    rm -f "$frontmatter_file"
    echo "unable to extract task frontmatter: $task_file" >&2
    return 1
  fi

  if ! yq -e '.intended_write_targets | type == "array"' "$frontmatter_file" >/dev/null 2>&1; then
    rm -f "$frontmatter_file"
    echo "task missing intended_write_targets array: $task_file" >&2
    return 1
  fi

  local count
  count="$(yq -r '.intended_write_targets | length' "$frontmatter_file")"
  rm -f "$frontmatter_file"
  printf '%s' "$count"
}

task_intended_write_targets() {
  local task_file="$1"
  require_command yq

  local frontmatter_file
  frontmatter_file="$(mktemp)"
  extract_frontmatter_to_file "$task_file" "$frontmatter_file"

  if [[ ! -s "$frontmatter_file" ]]; then
    rm -f "$frontmatter_file"
    echo "unable to extract task frontmatter: $task_file" >&2
    return 1
  fi

  if ! yq -e '.intended_write_targets | type == "array"' "$frontmatter_file" >/dev/null 2>&1; then
    rm -f "$frontmatter_file"
    echo "task missing intended_write_targets array: $task_file" >&2
    return 1
  fi

  yq -r '.intended_write_targets[]? // empty' "$frontmatter_file"
  rm -f "$frontmatter_file"
}

agent_requires_write_targets() {
  local agent="$1"
  local coding_owner_lanes
  coding_owner_lanes="$(resolve_coding_owner_lanes)"
  agent_in_space_list "$agent" "$coding_owner_lanes"
}

default_phase_for_owner() {
  local owner_agent="$1"

  if agent_requires_write_targets "$owner_agent"; then
    printf 'execute'
    return 0
  fi

  case "$owner_agent" in
    review)
      printf 'review'
      ;;
    researcher)
      printf 'research'
      ;;
    planner|architect|pm|coordinator|designer)
      printf 'plan'
      ;;
    *)
      printf '%s' "$DEFAULT_PHASE"
      ;;
  esac
}

phase_requires_strict_done_evidence() {
  local phase="$1"
  case "$phase" in
    execute|review|closeout) return 0 ;;
    *) return 1 ;;
  esac
}

owner_auto_includes_taskfile_target() {
  local agent="$1"
  agent_requires_write_targets "$agent"
}

coding_owner_auto_target_agents() {
  local coding_owner_lanes
  coding_owner_lanes="$(resolve_coding_owner_lanes)"
  printf '%s\n' $coding_owner_lanes
}

task_in_progress_write_target() {
  local task_id="$1"
  local owner_agent="$2"
  canonicalize_target_path "$ROOT/in_progress/$owner_agent/${task_id}.md"
}

is_coding_owner_taskfile_target() {
  local task_id="$1"
  local candidate_target="$2"

  local coding_owner owner_target
  while IFS= read -r coding_owner; do
    [[ -n "$coding_owner" ]] || continue
    owner_target="$(task_in_progress_write_target "$task_id" "$coding_owner")"
    if [[ "$candidate_target" == "$owner_target" ]]; then
      return 0
    fi
  done < <(coding_owner_auto_target_agents)

  return 1
}

validate_write_target_requirement() {
  local owner_agent="$1"
  shift
  local -a targets=("$@")

  if ! agent_requires_write_targets "$owner_agent"; then
    return 0
  fi

  (( ${#targets[@]} > 0 )) || {
    echo "coding tasks for owner_agent=$owner_agent require non-empty intended_write_targets (pass --write-target <path>)" >&2
    return 1
  }
}

validate_task_write_target_policy() {
  local task_file="$1"
  local owner_agent="$2"

  if ! agent_requires_write_targets "$owner_agent"; then
    return 0
  fi

  local count
  count="$(task_intended_write_target_count "$task_file")" || return 1
  (( count > 0 )) || {
    echo "coding tasks for owner_agent=$owner_agent require non-empty intended_write_targets: $task_file" >&2
    return 1
  }
}

refresh_assign_self_taskfile_target() {
  local task_file="$1"
  local task_id="$2"
  local owner_agent="$3"

  if ! owner_auto_includes_taskfile_target "$owner_agent"; then
    return 0
  fi

  local owner_target
  owner_target="$(task_in_progress_write_target "$task_id" "$owner_agent")"

  local -a refreshed_targets=()
  local target canonical_target
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    canonical_target="$(canonicalize_target_path "$target")"
    if is_coding_owner_taskfile_target "$task_id" "$canonical_target"; then
      continue
    fi
    refreshed_targets+=("$canonical_target")
  done < <(task_intended_write_targets "$task_file")

  refreshed_targets+=("$owner_target")

  local -a normalized_targets=()
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    normalized_targets+=("$target")
  done < <(canonicalize_write_targets "${refreshed_targets[@]}")

  set_field "$task_file" "intended_write_targets" "$(yaml_inline_list "${normalized_targets[@]}")"
}

canonicalize_write_targets() {
  local -a targets=("$@")
  local -a normalized=()
  local target canonical_target existing

  for target in "${targets[@]}"; do
    [[ -n "$target" ]] || continue
    canonical_target="$(canonicalize_target_path "$target")"
    local seen=0
    for existing in "${normalized[@]}"; do
      if [[ "$existing" == "$canonical_target" ]]; then
        seen=1
        break
      fi
    done
    if [[ "$seen" -eq 0 ]]; then
      normalized+=("$canonical_target")
    fi
  done

  printf '%s\n' "${normalized[@]}"
}

yaml_quote_single() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

yaml_inline_list() {
  local -a values=("$@")
  if (( ${#values[@]} == 0 )); then
    printf '[]'
    return 0
  fi

  local index
  local rendered="["
  for index in "${!values[@]}"; do
    if (( index > 0 )); then
      rendered+=", "
    fi
    rendered+="$(yaml_quote_single "${values[$index]}")"
  done
  rendered+="]"
  printf '%s' "$rendered"
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
    researcher|research) tags="$(append_unique_word "$tags" "product")" ;;
    planner) tags="$(append_unique_word "$tags" "architecture")" ;;
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

coordinator_handover_path() {
  printf '%s/reports/coordinator/HANDOVER.md' "$ROOT"
}

ensure_coordinator_handover() {
  local agent="$1"
  [[ "$agent" == "coordinator" ]] || return 0

  local handover_file
  handover_file="$(coordinator_handover_path)"
  [[ -f "$handover_file" ]] && return 0

  cat >"$handover_file" <<EOF
# Coordinator Handover

Last updated: $(now)

## Current Objective
- User objective:
- Parent task:

## Active Plan
- Current phase:
- In-progress tasks:

## Delegation Status
- Waiting on:
- Recently completed:

## Decisions and Constraints
- Key decisions:
- Constraints:

## Risks and Blockers
- Active blockers:
- Mitigations:

## Next Actions
1. Capture the next coordinator action before ending the session.

## Resume Checklist
1. Read this handover first.
2. Check current queues with \`scripts/taskctl.sh list coordinator\`.
3. Resume from \`## Next Actions\`.
4. Update this file after meaningful plan/delegation changes and before completing or blocking a task.
EOF
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

  if [[ "$agent" == "coordinator" ]]; then
    local handover_file
    handover_file="$(coordinator_handover_path)"
    cat >>"$role_file" <<EOF
- Handover continuity: maintain \`$handover_file\` as the persistent coordinator state file.
- At startup, read \`$handover_file\` first and resume work from its \`## Next Actions\`.
- Update \`$handover_file\` after meaningful plan or delegation changes.
- Update \`$handover_file\` before completing (\`scripts/taskctl.sh done coordinator <TASK_ID>\`) or before blocking (\`scripts/taskctl.sh block coordinator <TASK_ID> "reason"\`) a task.
EOF
  fi

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

  ensure_coordinator_handover "$agent"

  local role_file="$ROOT/roles/$agent.md"

  local task_file=""
  if [[ -n "$task_ref" ]]; then
    if ! task_file="$(resolve_task_file "$task_ref")"; then
      echo "unable to resolve task reference: $task_ref" >&2
      return 1
    fi
  fi

  local tags
  tags="$(infer_skill_tags "$agent" "" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [[ -n "$tags" ]] || tags="general"

  local tags_csv
  tags_csv="${tags// /,}"

  local fit_signature
  fit_signature="$(compute_fit_signature "$agent" "" "$tags_csv")"

  local needs_refresh=0
  if [[ ! -f "$role_file" ]]; then
    needs_refresh=1
  elif [[ "$force_refresh" -eq 1 ]]; then
    needs_refresh=1
  fi

  if [[ "$needs_refresh" -eq 1 ]]; then
    if [[ -f "$role_file" ]] && ! role_is_auto_managed "$role_file"; then
      local backup_dir="$ROOT/runtime/role_backups/$agent"
      mkdir -p "$backup_dir"
      cp "$role_file" "$backup_dir/$(basename "$role_file").$(date +%Y%m%d%H%M%S).bak"
    fi

    generate_role_prompt "$agent" "$role_file" "" "$tags" "$tags_csv" "$fit_signature"
  fi
}

find_existing_task() {
  local task_id="$1"
  find "$ROOT" -type f -name "${task_id}.md" \
    ! -path "$ROOT/examples/*" \
    ! -path "$ROOT/templates/*" \
    ! -path "$ROOT/roles/*" | head -n1
}

ensure_task_prompt_sidecar() {
  local task_id="$1"
  local sidecar_root="$ROOT/task_prompts/$task_id"
  local section

  for section in prompt context deliverables validation; do
    mkdir -p "$sidecar_root/$section"
    [[ -f "$sidecar_root/$section/000.md" ]] || : >"$sidecar_root/$section/000.md"
  done
}

extract_task_section() {
  local task_file="$1"
  local section_name="$2"

  awk -v section_name="$section_name" '
    BEGIN { in_section = 0 }
    $0 == "## " section_name { in_section = 1; next }
    in_section && /^## [^#]/ { exit }
    in_section { print }
  ' "$task_file"
}

task_yaml_array_values() {
  local task_file="$1"
  local field="$2"
  require_command yq

  local frontmatter_file
  frontmatter_file="$(mktemp)"
  extract_frontmatter_to_file "$task_file" "$frontmatter_file"

  if [[ ! -s "$frontmatter_file" ]]; then
    rm -f "$frontmatter_file"
    echo "unable to extract task frontmatter: $task_file" >&2
    return 1
  fi

  if ! yq -e ".${field} | type == \"array\"" "$frontmatter_file" >/dev/null 2>&1; then
    rm -f "$frontmatter_file"
    echo "task missing ${field} array: $task_file" >&2
    return 1
  fi

  yq -r ".${field}[]? // empty" "$frontmatter_file"
  rm -f "$frontmatter_file"
}

task_yaml_scalar_value() {
  local task_file="$1"
  local field="$2"
  require_command yq

  local frontmatter_file
  frontmatter_file="$(mktemp)"
  extract_frontmatter_to_file "$task_file" "$frontmatter_file"

  if [[ ! -s "$frontmatter_file" ]]; then
    rm -f "$frontmatter_file"
    echo "unable to extract task frontmatter: $task_file" >&2
    return 1
  fi

  yq -r ".${field} // \"\"" "$frontmatter_file"
  rm -f "$frontmatter_file"
}

task_has_benchmark_profile() {
  local task_file="$1"
  local raw
  raw="$(task_yaml_scalar_value "$task_file" "benchmark_profile" 2>/dev/null || true)"
  raw="$(printf '%s' "$raw" | sed -E "s/^'+|'+$//g")"

  [[ -n "$raw" && "$raw" != "none" && "$raw" != "null" ]]
}

task_benchmark_profile_path() {
  local task_file="$1"
  local raw
  raw="$(task_yaml_scalar_value "$task_file" "benchmark_profile" 2>/dev/null || true)"
  raw="$(printf '%s' "$raw" | sed -E "s/^'+|'+$//g")"

  if [[ -z "$raw" || "$raw" == "none" || "$raw" == "null" ]]; then
    raw="$DEFAULT_BENCHMARK_PROFILE_PATH"
  fi

  local absolute root_candidate workspace_candidate
  if [[ "$raw" == /* ]]; then
    absolute="$(abs_path "$raw")"
  else
    root_candidate="$(abs_path "$ROOT/$raw")"
    workspace_candidate="$(abs_path "/workspace/$raw")"

    if [[ -e "$root_candidate" || -d "$(dirname "$root_candidate")" ]]; then
      absolute="$root_candidate"
    else
      absolute="$workspace_candidate"
    fi
  fi

  [[ "$absolute" == "/workspace" || "$absolute" == /workspace/* ]] || {
    echo "benchmark profile path must resolve under /workspace: $raw" >&2
    return 1
  }

  printf '%s' "$absolute"
}

task_scorecard_artifact_path() {
  local task_file="$1"
  local raw
  raw="$(task_yaml_scalar_value "$task_file" "scorecard_artifact" 2>/dev/null || true)"
  raw="$(printf '%s' "$raw" | sed -E "s/^'+|'+$//g")"

  if [[ -z "$raw" || "$raw" == "none" || "$raw" == "null" ]]; then
    raw="$DEFAULT_BENCHMARK_SCORECARD_PATH"
  fi

  local absolute root_candidate workspace_candidate
  if [[ "$raw" == /* ]]; then
    absolute="$(abs_path "$raw")"
  else
    root_candidate="$(abs_path "$ROOT/$raw")"
    workspace_candidate="$(abs_path "/workspace/$raw")"

    if [[ -e "$root_candidate" || -d "$(dirname "$root_candidate")" ]]; then
      absolute="$root_candidate"
    else
      absolute="$workspace_candidate"
    fi
  fi

  [[ "$absolute" == "/workspace" || "$absolute" == /workspace/* ]] || {
    echo "scorecard artifact path must resolve under /workspace: $raw" >&2
    return 1
  }

  printf '%s' "$absolute"
}

escape_ere() {
  local value="$1"
  printf '%s' "$value" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g'
}

extract_result_value_for_key() {
  local result_body="$1"
  local key="$2"
  local value_regex="$3"
  local escaped_key
  escaped_key="$(escape_ere "$key")"

  printf '%s\n' "$result_body" | sed -nE "s/^[[:space:]]*-[[:space:]]*${escaped_key}:[[:space:]]*(${value_regex})[[:space:]]*$/\\1/p" | head -n1
}

is_number_value() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

number_greater_than() {
  local lhs="$1"
  local rhs="$2"
  awk -v a="$lhs" -v b="$rhs" 'BEGIN { exit !(a > b) }'
}

json_array_from_values() {
  if [[ "$#" -eq 0 ]]; then
    printf '[]'
    return 0
  fi

  printf '%s\n' "$@" | jq -R . | jq -cs .
}

task_phase_value() {
  local task_file="$1"
  require_command yq

  local frontmatter_file
  frontmatter_file="$(mktemp)"
  extract_frontmatter_to_file "$task_file" "$frontmatter_file"

  if [[ ! -s "$frontmatter_file" ]]; then
    rm -f "$frontmatter_file"
    echo "unable to extract task frontmatter: $task_file" >&2
    return 1
  fi

  local phase
  phase="$(yq -r '.phase // ""' "$frontmatter_file")"
  rm -f "$frontmatter_file"
  normalize_phase_value "$phase"
}

path_exists_in_workspace() {
  local artifact="$1"
  local canonical
  canonical="$(canonicalize_target_path "$artifact")"
  [[ -e "/workspace/$canonical" ]]
}

result_section_has_placeholder_text() {
  local result_body="$1"
  printf '%s' "$result_body" | rg -qi '(agent fills this before|^pending$|^todo$|^tbd$|placeholder|not implemented)'
}

verify_task_done_in_progress() {
  local agent="$1"
  local task_id="$2"
  local completion_note="${3:-}"

  local task_file="$ROOT/in_progress/$agent/${task_id}.md"
  [[ -f "$task_file" ]] || {
    echo "task not in progress for verification: $task_file" >&2
    return 1
  }

  local phase
  phase="$(task_phase_value "$task_file")" || return 1

  local result_body
  result_body="$(extract_task_section "$task_file" "Result")"

  local has_meaningful_result=0
  if printf '%s' "$result_body" | grep -q '[^[:space:]]'; then
    if ! result_section_has_placeholder_text "$result_body"; then
      has_meaningful_result=1
    fi
  fi

  if phase_requires_strict_done_evidence "$phase"; then
    (( has_meaningful_result == 1 )) || {
      echo "verify-done failed: phase=$phase requires non-placeholder ## Result evidence" >&2
      return 1
    }
  elif (( has_meaningful_result == 0 )); then
    if [[ -z "$completion_note" ]]; then
      echo "verify-done failed: phase=$phase requires either non-placeholder ## Result or completion note" >&2
      return 1
    fi
  fi

  local -a requirement_ids=()
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requirement_ids+=("$item")
  done < <(task_yaml_array_values "$task_file" "requirement_ids")

  local -a evidence_commands=()
  local -a evidence_artifacts=()
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    evidence_commands+=("$item")
  done < <(task_yaml_array_values "$task_file" "evidence_commands")

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    evidence_artifacts+=("$item")
  done < <(task_yaml_array_values "$task_file" "evidence_artifacts")

  local cmd
  for cmd in "${evidence_commands[@]}"; do
    if ! printf '%s' "$result_body" | grep -Fq -- "$cmd"; then
      echo "verify-done failed: command evidence missing from ## Result: $cmd" >&2
      return 1
    fi
  done

  local artifact
  for artifact in "${evidence_artifacts[@]}"; do
    if ! path_exists_in_workspace "$artifact"; then
      echo "verify-done failed: expected evidence artifact does not exist: $artifact" >&2
      return 1
    fi
  done

  if phase_requires_strict_done_evidence "$phase"; then
    if (( ${#requirement_ids[@]} == 0 )); then
      echo "verify-done failed: strict phase requires non-empty requirement_ids frontmatter" >&2
      return 1
    fi
    if ! printf '%s' "$result_body" | grep -qi 'Requirement Statuses:'; then
      echo "verify-done failed: strict phase requires \"Requirement Statuses:\" section in ## Result" >&2
      return 1
    fi

    local requirement_id requirement_status
    for requirement_id in "${requirement_ids[@]}"; do
      requirement_status="$(extract_result_value_for_key "$result_body" "$requirement_id" 'Met|Partial|Missing|Unverifiable')"
      if [[ -z "$requirement_status" ]]; then
        echo "verify-done failed: requirement status missing/invalid for $requirement_id (expected Met|Partial|Missing|Unverifiable)" >&2
        return 1
      fi
    done

    if ! printf '%s' "$result_body" | grep -qi 'Acceptance Criteria:'; then
      echo "verify-done failed: strict phase requires \"Acceptance Criteria:\" section in ## Result" >&2
      return 1
    fi
    if ! printf '%s' "$result_body" | grep -qi 'Command:'; then
      echo "verify-done failed: strict phase requires at least one \"Command:\" line in ## Result" >&2
      return 1
    fi
    if ! printf '%s' "$result_body" | grep -qi 'Exit:'; then
      echo "verify-done failed: strict phase requires at least one \"Exit:\" line in ## Result" >&2
      return 1
    fi
    if ! printf '%s' "$result_body" | grep -qi 'Log:'; then
      echo "verify-done failed: strict phase requires at least one \"Log:\" line in ## Result" >&2
      return 1
    fi
  fi

  if task_has_benchmark_profile "$task_file"; then
    if ! benchmark_verify_task_file "$task_file" >/dev/null; then
      echo "verify-done failed: benchmark evidence contract failed for task_id=$task_id" >&2
      return 1
    fi
  fi

  echo "verify-done passed: task_id=$task_id phase=$phase"
}

benchmark_verify_task_file() {
  local task_file="$1"
  local output_mode="${2:-text}"
  require_command jq

  [[ -f "$task_file" ]] || {
    echo "benchmark-verify failed: task file not found: $task_file" >&2
    return 1
  }

  local profile_file
  profile_file="$(task_benchmark_profile_path "$task_file")"
  [[ -f "$profile_file" ]] || {
    echo "benchmark-verify failed: benchmark profile not found: $profile_file" >&2
    return 1
  }

  if ! jq -e '.weights and .gates and .requirements' "$profile_file" >/dev/null 2>&1; then
    echo "benchmark-verify failed: invalid benchmark profile schema: $profile_file" >&2
    return 1
  fi

  local result_body
  result_body="$(extract_task_section "$task_file" "Result")"

  local -a requirement_ids=()
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requirement_ids+=("$item")
  done < <(task_yaml_array_values "$task_file" "requirement_ids")

  local -a gate_targets=()
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    gate_targets+=("$item")
  done < <(task_yaml_array_values "$task_file" "gate_targets")

  local required_status_regex
  required_status_regex="$(jq -r '.required_status_values // ["Met","Partial","Missing","Unverifiable"] | join("|")' "$profile_file")"
  [[ -n "$required_status_regex" ]] || required_status_regex="Met|Partial|Missing|Unverifiable"

  local findings_count=0
  local missing_requirement_status_entries=0
  local missing_gate_status_entries=0
  local missing_required_command_evidence=0
  local -a findings=()

  if (( ${#requirement_ids[@]} == 0 )); then
    findings+=("requirement_ids frontmatter is empty")
    findings_count=$((findings_count + 1))
  fi

  if (( ${#gate_targets[@]} == 0 )); then
    findings+=("gate_targets frontmatter is empty")
    findings_count=$((findings_count + 1))
  fi

  local requirement_statuses_json='{}'
  local requirement_id requirement_status
  for requirement_id in "${requirement_ids[@]}"; do
    if ! jq -e --arg id "$requirement_id" '.requirements[]? | select(.id == $id)' "$profile_file" >/dev/null 2>&1; then
      findings+=("requirement id not present in profile: $requirement_id")
      findings_count=$((findings_count + 1))
    fi

    requirement_status="$(extract_result_value_for_key "$result_body" "$requirement_id" "$required_status_regex")"
    if [[ -z "$requirement_status" ]]; then
      requirement_status="Unverifiable"
      missing_requirement_status_entries=$((missing_requirement_status_entries + 1))
      findings+=("missing requirement status in ## Result for $requirement_id")
      findings_count=$((findings_count + 1))
    fi

    requirement_statuses_json="$(jq -cn \
      --argjson base "$requirement_statuses_json" \
      --arg requirement_id "$requirement_id" \
      --arg status "$requirement_status" \
      '$base + {($requirement_id): $status}')"
  done

  local gate_statuses_json='{}'
  local gate_id gate_status
  for gate_id in "${gate_targets[@]}"; do
    if ! jq -e --arg id "$gate_id" '.gates[]? | select(.id == $id)' "$profile_file" >/dev/null 2>&1; then
      findings+=("gate target not present in profile: $gate_id")
      findings_count=$((findings_count + 1))
    fi

    gate_status="$(extract_result_value_for_key "$result_body" "$gate_id" 'pass|fail|PASS|FAIL')"
    if [[ -z "$gate_status" ]]; then
      gate_status="fail"
      missing_gate_status_entries=$((missing_gate_status_entries + 1))
      findings+=("missing gate status in ## Result for $gate_id")
      findings_count=$((findings_count + 1))
    fi
    gate_status="$(printf '%s' "$gate_status" | tr '[:upper:]' '[:lower:]')"

    gate_statuses_json="$(jq -cn \
      --argjson base "$gate_statuses_json" \
      --arg gate_id "$gate_id" \
      --arg status "$gate_status" \
      '$base + {($gate_id): $status}')"

    local -a required_commands=()
    while IFS= read -r cmd; do
      [[ -n "$cmd" ]] || continue
      required_commands+=("$cmd")
    done < <(jq -r --arg gate "$gate_id" '.gate_required_commands[$gate][]? // empty' "$profile_file")

    local required_cmd
    for required_cmd in "${required_commands[@]}"; do
      if ! printf '%s\n' "$result_body" | grep -Fq -- "Command: $required_cmd"; then
        findings+=("missing required command evidence for $gate_id: $required_cmd")
        findings_count=$((findings_count + 1))
        missing_required_command_evidence=$((missing_required_command_evidence + 1))
      fi
    done
  done

  local requirement_ids_json gate_targets_json findings_json
  requirement_ids_json="$(json_array_from_values "${requirement_ids[@]}")"
  gate_targets_json="$(json_array_from_values "${gate_targets[@]}")"
  findings_json="$(json_array_from_values "${findings[@]}")"

  local data_valid=true
  if (( findings_count > 0 )); then
    data_valid=false
  fi

  local summary_json
  summary_json="$(jq -cn \
    --arg task_file "$task_file" \
    --arg profile_file "$profile_file" \
    --argjson requirement_ids "$requirement_ids_json" \
    --argjson gate_targets "$gate_targets_json" \
    --argjson requirement_statuses "$requirement_statuses_json" \
    --argjson gate_statuses "$gate_statuses_json" \
    --argjson findings "$findings_json" \
    --argjson missing_requirement_status_entries "$missing_requirement_status_entries" \
    --argjson missing_gate_status_entries "$missing_gate_status_entries" \
    --argjson missing_required_command_evidence "$missing_required_command_evidence" \
    --argjson findings_count "$findings_count" \
    --argjson data_valid "$data_valid" \
    '{
      task_file: $task_file,
      profile_file: $profile_file,
      requirement_ids: $requirement_ids,
      gate_targets: $gate_targets,
      requirement_statuses: $requirement_statuses,
      gate_statuses: $gate_statuses,
      missing_requirement_status_entries: $missing_requirement_status_entries,
      missing_gate_status_entries: $missing_gate_status_entries,
      missing_required_command_evidence: $missing_required_command_evidence,
      findings_count: $findings_count,
      findings: $findings,
      data_valid: $data_valid
    }')"

  if [[ "$output_mode" == "json" ]]; then
    printf '%s\n' "$summary_json"
  else
    echo "benchmark-verify: task_file=$task_file"
    echo "benchmark-verify: profile_file=$profile_file"
    echo "benchmark-verify: requirement_ids=${#requirement_ids[@]} gate_targets=${#gate_targets[@]} findings=$findings_count"
    if (( findings_count > 0 )); then
      local finding
      for finding in "${findings[@]}"; do
        echo "benchmark-verify finding: $finding"
      done
    fi
  fi

  if (( findings_count > 0 )); then
    return 1
  fi
  return 0
}

benchmark_score_task_file() {
  local task_file="$1"
  require_command jq

  local verify_json
  local verify_rc=0
  if verify_json="$(benchmark_verify_task_file "$task_file" json)"; then
    verify_rc=0
  else
    verify_rc=$?
  fi

  local profile_file
  profile_file="$(printf '%s' "$verify_json" | jq -r '.profile_file')"
  [[ -f "$profile_file" ]] || {
    echo "benchmark-score failed: profile file missing: $profile_file" >&2
    return 1
  }

  local result_body
  result_body="$(extract_task_section "$task_file" "Result")"

  local -a weight_order=()
  while IFS= read -r category; do
    [[ -n "$category" ]] || continue
    weight_order+=("$category")
  done < <(jq -r '.weight_order[]? // empty' "$profile_file")

  if (( ${#weight_order[@]} == 0 )); then
    while IFS= read -r category; do
      [[ -n "$category" ]] || continue
      weight_order+=("$category")
    done < <(jq -r '.weights | keys[]' "$profile_file")
  fi

  local category_scores_json='{}'
  local -a score_findings=()
  local raw_total=0
  local category category_score max_score
  for category in "${weight_order[@]}"; do
    max_score="$(jq -r --arg category "$category" '.weights[$category] // 0' "$profile_file")"
    if ! is_number_value "$max_score"; then
      score_findings+=("invalid max score in profile for category $category: $max_score")
      max_score=0
    fi

    category_score="$(extract_result_value_for_key "$result_body" "$category" '[0-9]+([.][0-9]+)?')"
    if [[ -z "$category_score" ]]; then
      score_findings+=("missing category score in ## Result for $category; defaulting to 0")
      category_score=0
    fi

    if ! is_number_value "$category_score"; then
      score_findings+=("invalid numeric score for $category: $category_score; defaulting to 0")
      category_score=0
    fi

    if number_greater_than "$category_score" "$max_score"; then
      score_findings+=("category score for $category exceeded max ($category_score > $max_score); clamped to max")
      category_score="$max_score"
    fi

    raw_total="$(awk -v total="$raw_total" -v value="$category_score" 'BEGIN { printf "%.2f", total + value }')"
    category_scores_json="$(jq -cn \
      --argjson base "$category_scores_json" \
      --arg category "$category" \
      --argjson score "$category_score" \
      '$base + {($category): $score}')"
  done

  local unverifiable_count missing_requirement_count weak_evidence_count
  unverifiable_count="$(printf '%s' "$verify_json" | jq -r '.requirement_statuses | to_entries | map(select(.value == "Unverifiable")) | length')"
  missing_requirement_count="$(printf '%s' "$verify_json" | jq -r '.requirement_statuses | to_entries | map(select(.value == "Missing")) | length')"
  weak_evidence_count="$(printf '%s' "$verify_json" | jq -r '.missing_requirement_status_entries + .missing_gate_status_entries + .missing_required_command_evidence')"

  local conservative_penalty
  conservative_penalty="$(awk -v u="$unverifiable_count" -v m="$missing_requirement_count" -v w="$weak_evidence_count" -v verify_rc="$verify_rc" '
    BEGIN {
      penalty = (u * 2) + (m * 1) + (w * 2);
      if (verify_rc != 0) penalty += 5;
      if (penalty > 30) penalty = 30;
      printf "%.2f", penalty;
    }')"

  local final_total
  final_total="$(awk -v raw="$raw_total" -v penalty="$conservative_penalty" '
    BEGIN {
      total = raw - penalty;
      if (total < 0) total = 0;
      printf "%.2f", total;
    }')"

  local min_score require_all_gates_pass all_target_gates_pass
  min_score="$(jq -r '.closeout.min_score // 80' "$profile_file")"
  require_all_gates_pass="$(jq -r '.closeout.require_all_gates_pass // true' "$profile_file")"
  all_target_gates_pass="$(printf '%s' "$verify_json" | jq -r '.gate_statuses | to_entries | if length == 0 then false else all(.value == "pass") end')"

  local score_threshold_met=false
  if awk -v score="$final_total" -v min="$min_score" 'BEGIN { exit !(score >= min) }'; then
    score_threshold_met=true
  fi

  local closeout_ready=true
  if [[ "$score_threshold_met" != "true" ]]; then
    closeout_ready=false
  fi
  if [[ "$require_all_gates_pass" == "true" && "$all_target_gates_pass" != "true" ]]; then
    closeout_ready=false
  fi
  if [[ "$verify_rc" -ne 0 ]]; then
    closeout_ready=false
  fi

  local score_findings_json verify_findings_json all_findings_json
  score_findings_json="$(json_array_from_values "${score_findings[@]}")"
  verify_findings_json="$(printf '%s' "$verify_json" | jq -c '.findings')"
  all_findings_json="$(jq -cn --argjson verify_findings "$verify_findings_json" --argjson score_findings "$score_findings_json" '$verify_findings + $score_findings')"

  local scorecard_json_path scorecard_md_path
  scorecard_json_path="$(task_scorecard_artifact_path "$task_file")"
  scorecard_md_path="${scorecard_json_path%.json}.md"
  if [[ "$scorecard_md_path" == "$scorecard_json_path" ]]; then
    scorecard_md_path="${scorecard_json_path}.md"
  fi

  mkdir -p "$(dirname "$scorecard_json_path")"
  mkdir -p "$(dirname "$scorecard_md_path")"

  local requirement_statuses_json gate_statuses_json gate_targets_json requirement_ids_json weights_json
  requirement_statuses_json="$(printf '%s' "$verify_json" | jq -c '.requirement_statuses')"
  gate_statuses_json="$(printf '%s' "$verify_json" | jq -c '.gate_statuses')"
  gate_targets_json="$(printf '%s' "$verify_json" | jq -c '.gate_targets')"
  requirement_ids_json="$(printf '%s' "$verify_json" | jq -c '.requirement_ids')"
  weights_json="$(jq -c '.weights' "$profile_file")"

  local scorecard_json
  scorecard_json="$(jq -cn \
    --arg generated_at "$(now)" \
    --arg task_file "$task_file" \
    --arg profile_file "$profile_file" \
    --argjson requirement_ids "$requirement_ids_json" \
    --argjson requirement_statuses "$requirement_statuses_json" \
    --argjson gate_targets "$gate_targets_json" \
    --argjson gate_statuses "$gate_statuses_json" \
    --argjson weights "$weights_json" \
    --argjson category_scores "$category_scores_json" \
    --argjson raw_total "$raw_total" \
    --argjson conservative_penalty "$conservative_penalty" \
    --argjson final_total "$final_total" \
    --argjson min_score "$min_score" \
    --argjson require_all_gates_pass "$require_all_gates_pass" \
    --argjson all_target_gates_pass "$all_target_gates_pass" \
    --argjson score_threshold_met "$score_threshold_met" \
    --argjson closeout_ready "$closeout_ready" \
    --argjson findings "$all_findings_json" \
    '{
      generated_at: $generated_at,
      task_file: $task_file,
      profile_file: $profile_file,
      requirement_ids: $requirement_ids,
      requirement_statuses: $requirement_statuses,
      gate_targets: $gate_targets,
      gate_statuses: $gate_statuses,
      weights: $weights,
      category_scores: $category_scores,
      raw_total: $raw_total,
      conservative_penalty: $conservative_penalty,
      final_total: $final_total,
      findings: $findings,
      closeout: {
        min_score: $min_score,
        require_all_gates_pass: $require_all_gates_pass,
        all_target_gates_pass: $all_target_gates_pass,
        score_threshold_met: $score_threshold_met,
        ready: $closeout_ready
      }
    }')"

  printf '%s\n' "$scorecard_json" >"$scorecard_json_path"

  {
    echo "# Benchmark Scorecard"
    echo
    echo "- generated_at: $(printf '%s' "$scorecard_json" | jq -r '.generated_at')"
    echo "- task_file: $(printf '%s' "$scorecard_json" | jq -r '.task_file')"
    echo "- profile_file: $(printf '%s' "$scorecard_json" | jq -r '.profile_file')"
    echo "- raw_total: $(printf '%s' "$scorecard_json" | jq -r '.raw_total')"
    echo "- conservative_penalty: $(printf '%s' "$scorecard_json" | jq -r '.conservative_penalty')"
    echo "- final_total: $(printf '%s' "$scorecard_json" | jq -r '.final_total')"
    echo "- closeout_ready: $(printf '%s' "$scorecard_json" | jq -r '.closeout.ready')"
    echo
    echo "## Category Scores"
    echo
    echo "| Category | Max | Score |"
    echo "|---|---:|---:|"
    for category in "${weight_order[@]}"; do
      max_score="$(printf '%s' "$scorecard_json" | jq -r --arg category "$category" '.weights[$category] // 0')"
      category_score="$(printf '%s' "$scorecard_json" | jq -r --arg category "$category" '.category_scores[$category] // 0')"
      echo "| $category | $max_score | $category_score |"
    done
    echo
    echo "## Gate Statuses"
    echo
    printf '%s' "$scorecard_json" | jq -r '.gate_statuses | to_entries[]? | "- \(.key): \(.value)"'
    echo
    echo "## Findings"
    echo
    printf '%s' "$scorecard_json" | jq -r '.findings[]? | "- " + .'
  } >"$scorecard_md_path"

  echo "benchmark-score: wrote scorecards json=$scorecard_json_path md=$scorecard_md_path final_total=$final_total closeout_ready=$closeout_ready"

  return 0
}

benchmark_closeout_check_task_file() {
  local task_file="$1"
  require_command jq

  benchmark_score_task_file "$task_file" >/dev/null

  local scorecard_json_path
  scorecard_json_path="$(task_scorecard_artifact_path "$task_file")"
  [[ -f "$scorecard_json_path" ]] || {
    echo "benchmark-closeout-check failed: scorecard not found: $scorecard_json_path" >&2
    return 1
  }

  local ready final_total min_score all_target_gates_pass require_all_gates_pass
  ready="$(jq -r '.closeout.ready' "$scorecard_json_path")"
  final_total="$(jq -r '.final_total' "$scorecard_json_path")"
  min_score="$(jq -r '.closeout.min_score' "$scorecard_json_path")"
  all_target_gates_pass="$(jq -r '.closeout.all_target_gates_pass' "$scorecard_json_path")"
  require_all_gates_pass="$(jq -r '.closeout.require_all_gates_pass' "$scorecard_json_path")"

  if [[ "$ready" != "true" ]]; then
    echo "benchmark-closeout-check failed: final_total=$final_total min_score=$min_score require_all_gates_pass=$require_all_gates_pass all_target_gates_pass=$all_target_gates_pass"
    jq -r '.findings[]? | "finding: " + .' "$scorecard_json_path"
    return 1
  fi

  echo "benchmark-closeout-check passed: final_total=$final_total min_score=$min_score all_target_gates_pass=$all_target_gates_pass"
}

resolve_task_for_benchmark_commands() {
  local agent="$1"
  local task_id="$2"
  local in_progress_task="$ROOT/in_progress/$agent/${task_id}.md"
  if [[ -f "$in_progress_task" ]]; then
    printf '%s' "$in_progress_task"
    return 0
  fi

  local existing
  existing="$(find_existing_task "$task_id")"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi

  echo "task not found for benchmark command: task_id=$task_id (agent=$agent)" >&2
  return 1
}

create_task() {
  local task_id="$1"
  local title="$2"
  local owner="$3"
  local creator="$4"
  local priority="$5"
  local parent_task_id="${6:-}"
  local phase="${7:-}"
  shift 7
  local -a requested_targets=("$@")
  local -a explicit_write_targets=()
  local -a write_targets=()

  require_task_id "$task_id"
  require_agent "$owner"
  require_agent "$creator"
  priority="$(normalize_priority "$priority")"
  if [[ -z "$phase" ]]; then
    phase="$(default_phase_for_owner "$owner")"
  fi
  phase="$(normalize_phase_value "$phase")"

  if (( ${#requested_targets[@]} > 0 )); then
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      explicit_write_targets+=("$target")
    done < <(canonicalize_write_targets "${requested_targets[@]}")
  fi

  validate_write_target_requirement "$owner" "${explicit_write_targets[@]}"
  write_targets=("${explicit_write_targets[@]}")

  if owner_auto_includes_taskfile_target "$owner"; then
    write_targets+=("$(task_in_progress_write_target "$task_id" "$owner")")
  fi

  if (( ${#write_targets[@]} > 0 )); then
    local -a normalized_write_targets=()
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      normalized_write_targets+=("$target")
    done < <(canonicalize_write_targets "${write_targets[@]}")
    write_targets=("${normalized_write_targets[@]}")
  fi

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
  set_field "$out" "title" "$(yaml_quote_single "$title")"
  set_field "$out" "owner_agent" "$owner"
  set_field "$out" "creator_agent" "$creator"
  set_field "$out" "status" "inbox"
  set_field "$out" "priority" "$priority"
  set_field "$out" "phase" "$phase"
  grep -qE '^requirement_ids:' "$out" || set_field "$out" "requirement_ids" "[]"
  grep -qE '^evidence_commands:' "$out" || set_field "$out" "evidence_commands" "[]"
  grep -qE '^evidence_artifacts:' "$out" || set_field "$out" "evidence_artifacts" "[]"
  grep -qE '^benchmark_profile:' "$out" || set_field "$out" "benchmark_profile" "none"
  grep -qE '^gate_targets:' "$out" || set_field "$out" "gate_targets" "[]"
  grep -qE '^scorecard_artifact:' "$out" || set_field "$out" "scorecard_artifact" "none"
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

  if (( ${#write_targets[@]} > 0 )); then
    set_field "$out" "intended_write_targets" "$(yaml_inline_list "${write_targets[@]}")"
  fi

  validate_task_write_target_policy "$out" "$owner"

  ensure_task_prompt_sidecar "$task_id"
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
  validate_task_write_target_policy "$src" "$target_agent"

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
  refresh_assign_self_taskfile_target "$dst" "$task_id" "$target_agent"

  ensure_agent_scaffold "$target_agent" "$dst"

  echo "assigned $task_id -> $target_agent"
}

claim_task() {
  local agent="$1"
  require_agent "$agent"
  [[ "$agent" != "system" ]] || { echo "system cannot claim tasks" >&2; exit 1; }

  ensure_agent_scaffold "$agent"

  local next=""
  local invalid_count=0
  local candidate

  while IFS= read -r candidate; do
    local owner_agent
    owner_agent="$(field_value "$candidate" "owner_agent")"
    owner_agent="${owner_agent:-$agent}"
    if validate_task_write_target_policy "$candidate" "$owner_agent"; then
      next="$candidate"
      break
    fi
    invalid_count=$((invalid_count + 1))
    echo "skipping unclaimable task for $agent: $candidate" >&2
  done < <(find "$ROOT/inbox/$agent" -type f -name '*.md' | sort)

  if [[ -z "$next" ]]; then
    if [[ "$invalid_count" -gt 0 ]]; then
      echo "no claimable tasks in inbox/$agent (fix intended_write_targets metadata)"
    else
      echo "no tasks in inbox/$agent"
    fi
    exit 0
  fi

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

  create_task "$report_id" "$report_title" "$creator" "system" 0 "$blocked_task_id" "clarify"

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

  if [[ "$action" == "done" ]]; then
    verify_task_done_in_progress "$agent" "$task_id" "$note" || exit 1
  fi

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
      local phase=""
      local -a write_targets=()
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
          --phase)
            phase="$2"
            shift 2
            ;;
          --write-target)
            write_targets+=("$2")
            shift 2
            ;;
          --coding-owner-lanes)
            set_coding_owner_lanes_override "${2:-}"
            shift 2
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      create_task "$task_id" "$title" "$owner" "$creator" "$priority" "$parent" "$phase" "${write_targets[@]}"
      ;;
    delegate)
      [[ $# -ge 5 ]] || { usage; exit 1; }
      local from_agent="$2"
      local to_agent="$3"
      local task_id="$4"
      local title="$5"
      local priority="$DEFAULT_PRIORITY"
      local parent=""
      local phase=""
      local -a write_targets=()
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
          --phase)
            phase="$2"
            shift 2
            ;;
          --write-target)
            write_targets+=("$2")
            shift 2
            ;;
          --coding-owner-lanes)
            set_coding_owner_lanes_override "${2:-}"
            shift 2
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      create_task "$task_id" "$title" "$to_agent" "$from_agent" "$priority" "$parent" "$phase" "${write_targets[@]}"
      ;;
    assign)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      local task_id="$2"
      local target_agent="$3"
      shift 3

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --coding-owner-lanes)
            set_coding_owner_lanes_override "${2:-}"
            shift 2
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      assign_task "$task_id" "$target_agent"
      ;;
    claim)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      local agent="$2"
      shift 2

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --coding-owner-lanes)
            set_coding_owner_lanes_override "${2:-}"
            shift 2
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      claim_task "$agent"
      ;;
    done)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      local note="${4:-}"
      transition_task done "$2" "$3" "$note"
      ;;
    verify-done)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      verify_task_done_in_progress "$2" "$3"
      ;;
    benchmark-verify)
      [[ $# -ge 3 ]] || { usage; exit 1; }
      local agent="$2"
      local task_id="$3"
      local output_mode="text"
      shift 3

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --json)
            output_mode="json"
            shift
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      local benchmark_task_file
      benchmark_task_file="$(resolve_task_for_benchmark_commands "$agent" "$task_id")" || exit 1
      benchmark_verify_task_file "$benchmark_task_file" "$output_mode"
      ;;
    benchmark-score)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      local benchmark_task_file
      benchmark_task_file="$(resolve_task_for_benchmark_commands "$2" "$3")" || exit 1
      benchmark_score_task_file "$benchmark_task_file"
      ;;
    benchmark-closeout-check)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      local benchmark_task_file
      benchmark_task_file="$(resolve_task_for_benchmark_commands "$2" "$3")" || exit 1
      benchmark_closeout_check_task_file "$benchmark_task_file"
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
    lock-acquire)
      [[ $# -eq 4 ]] || { usage; exit 1; }
      lock_acquire "$2" "$3" "$4"
      ;;
    lock-heartbeat)
      [[ $# -eq 4 ]] || { usage; exit 1; }
      lock_heartbeat "$2" "$3" "$4"
      ;;
    lock-release)
      [[ $# -eq 4 ]] || { usage; exit 1; }
      lock_release "$2" "$3" "$4"
      ;;
    lock-release-task)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      lock_release_task "$2" "$3"
      ;;
    lock-status)
      [[ $# -eq 2 ]] || { usage; exit 1; }
      lock_status "$2"
      ;;
    lock-clean-stale)
      local ttl_seconds="$DEFAULT_LOCK_STALE_TTL_SECONDS"
      local actor_agent="${TASK_ACTOR_AGENT:-}"
      shift

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --ttl)
            ttl_seconds="$2"
            shift 2
            ;;
          --actor)
            actor_agent="$2"
            shift 2
            ;;
          *)
            echo "unknown arg: $1" >&2
            usage
            exit 1
            ;;
        esac
      done

      lock_clean_stale "$ttl_seconds" "$actor_agent"
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
