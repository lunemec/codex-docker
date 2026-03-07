#!/usr/bin/env bash
set -euo pipefail

ROOT="${TASK_ROOT_DIR:-coordination}"
TEMPLATE="$ROOT/templates/TASK_TEMPLATE.md"
DEFAULT_BENCHMARK_PROFILE_PATH="$ROOT/benchmark_profiles/vault_sync_prompt_v1.json"
DEFAULT_BENCHMARK_SCORECARD_PATH="$ROOT/reports/coordinator/benchmark_scorecard.json"
DEFAULT_BENCHMARK_RERUN_DIR="$ROOT/reports/coordinator/benchmark_reruns"
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
CREATE_BENCHMARK_PROFILE_OVERRIDE=""
CREATE_BENCHMARK_WORKDIR_OVERRIDE=""
CREATE_BENCHMARK_SCORECARD_OVERRIDE=""
CREATE_BENCHMARK_OPT_OUT_REASON_OVERRIDE=""
CREATE_BENCHMARK_INHERIT_PARENT=1
declare -a CREATE_BENCHMARK_GATE_TARGET_OVERRIDES=()

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
  $0 create <TASK_ID> <TITLE> [--to <owner_agent>] [--from <creator_agent>] [--priority <N>] [--parent <TASK_ID>] [--phase <task_phase>] [--write-target <path>]... [--coding-owner-lanes <agents>] [--benchmark-profile <path|none>] [--benchmark-workdir <path>] [--gate-target <Gx>]... [--scorecard-artifact <path|none>] [--benchmark-opt-out-reason <text>] [--no-benchmark-inherit]
  $0 delegate <from_agent> <to_agent> <TASK_ID> <TITLE> [--priority <N>] [--parent <TASK_ID>] [--phase <task_phase>] [--write-target <path>]... [--coding-owner-lanes <agents>] [--benchmark-profile <path|none>] [--benchmark-workdir <path>] [--gate-target <Gx>]... [--scorecard-artifact <path|none>] [--benchmark-opt-out-reason <text>] [--no-benchmark-inherit]
  $0 assign <TASK_ID> <agent> [--coding-owner-lanes <agents>]
  $0 claim <agent> [--coding-owner-lanes <agents>]
  $0 verify-done <agent> <TASK_ID>
  $0 benchmark-init <agent> <TASK_ID>
  $0 benchmark-verify <agent> <TASK_ID> [--json]
  $0 benchmark-rerun <agent> <TASK_ID>
  $0 benchmark-score <agent> <TASK_ID>
  $0 benchmark-closeout-check <agent> <TASK_ID>
  $0 benchmark-audit-chain <agent> <TASK_ID>
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
  - benchmark-* commands enforce profile-driven gates/scores, strict evidence contracts (including Log Hash integrity), and independent rerun checks.
  - Benchmark metadata inherits from parent tasks by default; pass --no-benchmark-inherit only with --benchmark-opt-out-reason.
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

is_hex_hash_value() {
  local value="$1"
  [[ "$value" =~ ^[A-Fa-f0-9]{32,128}$ || "$value" =~ ^[0-9]{1,20}$ ]]
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

reset_create_benchmark_overrides() {
  CREATE_BENCHMARK_PROFILE_OVERRIDE=""
  CREATE_BENCHMARK_WORKDIR_OVERRIDE=""
  CREATE_BENCHMARK_SCORECARD_OVERRIDE=""
  CREATE_BENCHMARK_OPT_OUT_REASON_OVERRIDE=""
  CREATE_BENCHMARK_INHERIT_PARENT=1
  CREATE_BENCHMARK_GATE_TARGET_OVERRIDES=()
}

append_unique_create_gate_target_override() {
  local gate_target="$1"
  gate_target="$(printf '%s' "$gate_target" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -n "$gate_target" ]] || {
    echo "--gate-target requires a non-empty value" >&2
    exit 1
  }
  local existing
  for existing in "${CREATE_BENCHMARK_GATE_TARGET_OVERRIDES[@]}"; do
    [[ "$existing" == "$gate_target" ]] && return 0
  done
  CREATE_BENCHMARK_GATE_TARGET_OVERRIDES+=("$gate_target")
}

normalize_benchmark_scalar() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf 'none'
    return 0
  fi
  printf '%s' "$value"
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

canonicalize_workspace_path_soft() {
  local target="$1"
  [[ -n "$target" ]] || return 1

  local absolute_target
  if [[ "$target" == /* ]]; then
    absolute_target="$(abs_path "$target")"
  else
    absolute_target="$(abs_path "/workspace/$target")"
  fi

  [[ "$absolute_target" == "/workspace" || "$absolute_target" == /workspace/* ]] || return 1

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

replace_task_section_from_file() {
  local task_file="$1"
  local section_name="$2"
  local replacement_file="$3"

  [[ -f "$task_file" ]] || {
    echo "cannot replace section in missing task file: $task_file" >&2
    return 1
  }
  [[ -f "$replacement_file" ]] || {
    echo "replacement section file not found: $replacement_file" >&2
    return 1
  }

  local rendered_tmp
  rendered_tmp="$(mktemp)"

  awk -v section_name="$section_name" -v replacement_file="$replacement_file" '
    function emit_replacement(    line) {
      while ((getline line < replacement_file) > 0) {
        print line
      }
      close(replacement_file)
    }

    BEGIN {
      in_section = 0
      replaced = 0
    }

    $0 == "## " section_name {
      print
      emit_replacement()
      in_section = 1
      replaced = 1
      next
    }

    in_section && /^## [^#]/ {
      in_section = 0
      print
      next
    }

    in_section {
      next
    }

    {
      print
    }

    END {
      if (!replaced) {
        print ""
        print "## " section_name
        emit_replacement()
      }
    }
  ' "$task_file" >"$rendered_tmp"

  mv "$rendered_tmp" "$task_file"
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
  raw="$(normalize_benchmark_scalar "$raw")"

  [[ -n "$raw" && "$raw" != "none" && "$raw" != "null" ]]
}

task_benchmark_opt_out_reason() {
  local task_file="$1"
  local raw
  raw="$(task_yaml_scalar_value "$task_file" "benchmark_opt_out_reason" 2>/dev/null || true)"
  raw="$(printf '%s' "$raw" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"

  if [[ -z "$raw" || "$raw" == "none" || "$raw" == "null" ]]; then
    printf ''
    return 0
  fi

  printf '%s' "$raw"
}

resolve_benchmark_profile_path_from_value() {
  local raw="$1"
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

task_benchmark_profile_path() {
  local task_file="$1"
  local raw
  raw="$(task_yaml_scalar_value "$task_file" "benchmark_profile" 2>/dev/null || true)"
  raw="$(normalize_benchmark_scalar "$raw")"
  resolve_benchmark_profile_path_from_value "$raw"
}

benchmark_gate_targets_for_profile() {
  local profile_file="$1"
  require_command jq

  [[ -f "$profile_file" ]] || {
    echo "benchmark profile not found for gate extraction: $profile_file" >&2
    return 1
  }

  jq -r '.gates[]?.id // empty' "$profile_file"
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

default_scorecard_artifact_for_task() {
  local owner_agent="$1"
  local task_id="$2"
  printf 'reports/%s/benchmark_scorecards/%s.json' "$owner_agent" "$task_id"
}

task_benchmark_workdir_path() {
  local task_file="$1"
  local raw
  raw="$(task_yaml_scalar_value "$task_file" "benchmark_workdir" 2>/dev/null || true)"
  raw="$(printf '%s' "$raw" | sed -E "s/^'+|'+$//g")"

  if [[ -z "$raw" || "$raw" == "none" || "$raw" == "null" ]]; then
    raw="."
  fi

  local absolute
  if [[ "$raw" == /* ]]; then
    absolute="$(abs_path "$raw")"
  else
    absolute="$(abs_path "$(pwd -P)/$raw")"
  fi

  [[ "$absolute" == "/workspace" || "$absolute" == /workspace/* ]] || {
    echo "benchmark workdir must resolve under /workspace: $raw" >&2
    return 1
  }
  [[ -d "$absolute" ]] || {
    echo "benchmark workdir does not exist: $absolute" >&2
    return 1
  }

  printf '%s' "$absolute"
}

task_benchmark_rerun_summary_path() {
  local task_file="$1"
  local agent="$2"
  local task_id
  task_id="$(field_value "$task_file" "id")"
  [[ -n "$task_id" ]] || task_id="$(basename "$task_file" .md)"

  local path="$ROOT/reports/$agent/benchmark_reruns/${task_id}.json"
  local absolute
  absolute="$(abs_path "$path")"
  [[ "$absolute" == "/workspace" || "$absolute" == /workspace/* ]] || {
    echo "benchmark rerun summary path must resolve under /workspace: $path" >&2
    return 1
  }
  printf '%s' "$absolute"
}

task_benchmark_required_rerun_commands() {
  local task_file="$1"
  local profile_file
  profile_file="$(task_benchmark_profile_path "$task_file")"
  [[ -f "$profile_file" ]] || {
    echo "benchmark rerun profile missing: $profile_file" >&2
    return 1
  }

  local -a commands=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    commands+=("$cmd")
  done < <(jq -r '.closeout.required_rerun_commands[]? // empty' "$profile_file")

  if (( ${#commands[@]} == 0 )); then
    while IFS= read -r cmd; do
      [[ -n "$cmd" ]] || continue
      commands+=("$cmd")
    done < <(jq -r '.gate_required_commands.G1[]? // empty' "$profile_file")
  fi

  printf '%s\n' "${commands[@]}"
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

extract_result_text_for_key() {
  local result_body="$1"
  local key="$2"
  local escaped_key
  escaped_key="$(escape_ere "$key")"
  printf '%s\n' "$result_body" | sed -nE "s/^[[:space:]]*-[[:space:]]*${escaped_key}:[[:space:]]*(.+)[[:space:]]*$/\\1/p" | head -n1
}

trim_spaces() {
  local value="$1"
  printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

append_unique_array_value() {
  local array_name="$1"
  local candidate="$2"
  local -n values_ref="$array_name"
  local existing
  for existing in "${values_ref[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  values_ref+=("$candidate")
}

parse_result_command_blocks() {
  local result_body="$1"
  local commands_name="$2"
  local exits_name="$3"
  local logs_name="$4"
  local observed_name="$5"
  local log_hashes_name="${6:-}"
  local -n commands_ref="$commands_name"
  local -n exits_ref="$exits_name"
  local -n logs_ref="$logs_name"
  local -n observed_ref="$observed_name"
  local has_log_hashes=0

  commands_ref=()
  exits_ref=()
  logs_ref=()
  observed_ref=()

  if [[ -n "$log_hashes_name" ]]; then
    has_log_hashes=1
    local -n log_hashes_ref="$log_hashes_name"
    log_hashes_ref=()
  fi

  local current_index=-1 line value
  while IFS= read -r line; do
    case "$line" in
      Command:*)
        value="$(trim_spaces "${line#Command:}")"
        commands_ref+=("$value")
        exits_ref+=("")
        logs_ref+=("")
        observed_ref+=("")
        if [[ "$has_log_hashes" -eq 1 ]]; then
          log_hashes_ref+=("")
        fi
        current_index=$(( ${#commands_ref[@]} - 1 ))
        ;;
      Exit:*)
        if (( current_index >= 0 )); then
          exits_ref[$current_index]="$(trim_spaces "${line#Exit:}")"
        fi
        ;;
      Log:*)
        if (( current_index >= 0 )); then
          logs_ref[$current_index]="$(trim_spaces "${line#Log:}")"
        fi
        ;;
      Observed:*)
        if (( current_index >= 0 )); then
          observed_ref[$current_index]="$(trim_spaces "${line#Observed:}")"
        fi
        ;;
      Log\ Hash:*)
        if (( current_index >= 0 )) && [[ "$has_log_hashes" -eq 1 ]]; then
          log_hashes_ref[$current_index]="$(trim_spaces "${line#Log Hash:}")"
        fi
        ;;
    esac
  done <<< "$result_body"
}

command_block_index_for_exact_command() {
  local needle="$1"
  local commands_name="$2"
  local -n commands_ref="$commands_name"
  local idx
  for idx in "${!commands_ref[@]}"; do
    if [[ "${commands_ref[$idx]}" == "$needle" ]]; then
      printf '%s' "$idx"
      return 0
    fi
  done
  return 1
}

is_valid_exit_code_value() {
  local value="$1"
  [[ "$value" =~ ^-?[0-9]+$ ]]
}

command_block_matches_pattern_with_passing_exit() {
  local pattern="$1"
  local commands_name="$2"
  local exits_name="$3"
  local logs_name="$4"
  local -n commands_ref="$commands_name"
  local -n exits_ref="$exits_name"
  local -n logs_ref="$logs_name"

  local idx
  for idx in "${!commands_ref[@]}"; do
    if printf '%s' "${commands_ref[$idx]}" | grep -Eqi -- "$pattern"; then
      if [[ "${exits_ref[$idx]}" == "0" && -n "${logs_ref[$idx]}" ]] \
        && is_workspace_scoped_path "${logs_ref[$idx]}" \
        && path_exists_in_workspace "${logs_ref[$idx]}"; then
        return 0
      fi
    fi
  done
  return 1
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

task_parent_id_value() {
  local task_file="$1"
  local raw
  raw="$(task_yaml_scalar_value "$task_file" "parent_task_id" 2>/dev/null || true)"
  raw="$(printf '%s' "$raw" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"
  printf '%s' "$raw"
}

task_parent_file_path() {
  local task_file="$1"
  local parent_id
  parent_id="$(task_parent_id_value "$task_file")"
  if [[ -z "$parent_id" || "$parent_id" == "none" ]]; then
    return 1
  fi

  local parent_file
  parent_file="$(find_existing_task "$parent_id")"
  [[ -n "$parent_file" ]] || return 1
  printf '%s' "$parent_file"
}

task_id_from_file() {
  local task_file="$1"
  local task_id
  task_id="$(field_value "$task_file" "id")"
  [[ -n "$task_id" ]] || task_id="$(basename "$task_file" .md)"
  printf '%s' "$task_id"
}

timestamp_to_epoch() {
  local ts_raw="$1"
  local ts
  ts="$(trim_spaces "$ts_raw")"
  [[ -n "$ts" ]] || {
    printf '0'
    return 0
  }

  local epoch
  if epoch="$(date -d "$ts" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi

  printf '0'
}

task_updated_at_epoch() {
  local task_file="$1"
  local updated_at
  updated_at="$(task_yaml_scalar_value "$task_file" "updated_at" 2>/dev/null || true)"

  local epoch
  epoch="$(timestamp_to_epoch "$updated_at")"
  if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
    printf '%s' "$epoch"
    return 0
  fi

  if command -v stat >/dev/null 2>&1; then
    stat -c %Y "$task_file" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

benchmark_collect_chain_task_files() {
  local root_task_file="$1"

  [[ -f "$root_task_file" ]] || {
    echo "benchmark chain root task file not found: $root_task_file" >&2
    return 1
  }

  local root_task_id
  root_task_id="$(task_id_from_file "$root_task_file")"

  local -a queue_ids=("$root_task_id")
  local -a chain_files=("$root_task_file")
  local -a seen_task_ids=("$root_task_id")

  while (( ${#queue_ids[@]} > 0 )); do
    local parent_id="${queue_ids[0]}"
    queue_ids=("${queue_ids[@]:1}")

    local candidate_file
    while IFS= read -r candidate_file; do
      [[ -n "$candidate_file" ]] || continue

      local candidate_parent
      candidate_parent="$(task_parent_id_value "$candidate_file" 2>/dev/null || true)"
      if [[ "$candidate_parent" != "$parent_id" ]]; then
        continue
      fi

      append_unique_array_value chain_files "$candidate_file"
      local candidate_id
      candidate_id="$(task_id_from_file "$candidate_file")"
      local already_seen=0
      local seen_id
      for seen_id in "${seen_task_ids[@]}"; do
        if [[ "$seen_id" == "$candidate_id" ]]; then
          already_seen=1
          break
        fi
      done
      if [[ "$already_seen" -eq 0 ]]; then
        seen_task_ids+=("$candidate_id")
        queue_ids+=("$candidate_id")
      fi
    done < <(find "$ROOT" -type f -name '*.md' \
      ! -path "$ROOT/examples/*" \
      ! -path "$ROOT/templates/*" \
      ! -path "$ROOT/roles/*" \
      ! -path "$ROOT/reports/*")
  done

  printf '%s\n' "${chain_files[@]}"
}

latest_execute_updated_epoch_in_chain() {
  local root_task_file="$1"
  local latest_epoch=0

  local chain_task_file
  while IFS= read -r chain_task_file; do
    [[ -n "$chain_task_file" ]] || continue
    local phase
    phase="$(task_phase_value "$chain_task_file" 2>/dev/null || true)"
    if [[ "$phase" != "execute" ]]; then
      continue
    fi

    local updated_epoch
    updated_epoch="$(task_updated_at_epoch "$chain_task_file")"
    if [[ "$updated_epoch" =~ ^[0-9]+$ ]] && (( updated_epoch > latest_epoch )); then
      latest_epoch="$updated_epoch"
    fi
  done < <(benchmark_collect_chain_task_files "$root_task_file")

  printf '%s' "$latest_epoch"
}

requirement_status_rank() {
  local status_raw="$1"
  local status
  status="$(printf '%s' "$status_raw" | tr '[:upper:]' '[:lower:]')"
  case "$status" in
    met) printf '3' ;;
    partial) printf '2' ;;
    missing) printf '1' ;;
    unverifiable) printf '0' ;;
    *) printf '0' ;;
  esac
}

requirement_status_for_rank() {
  local rank="${1:-0}"
  case "$rank" in
    3) printf 'Met' ;;
    2) printf 'Partial' ;;
    1) printf 'Missing' ;;
    *) printf 'Unverifiable' ;;
  esac
}

task_parent_chain_has_benchmark_profile() {
  local task_file="$1"
  local current="$task_file"
  local hop_count=0

  while (( hop_count < 128 )); do
    local parent_file
    if ! parent_file="$(task_parent_file_path "$current")"; then
      return 1
    fi

    if task_has_benchmark_profile "$parent_file"; then
      return 0
    fi

    current="$parent_file"
    hop_count=$((hop_count + 1))
  done

  echo "task parent traversal exceeded limit while checking benchmark ancestry: $task_file" >&2
  return 1
}

task_nearest_benchmark_ancestor_file() {
  local task_file="$1"
  local current="$task_file"
  local hop_count=0

  while (( hop_count < 128 )); do
    local parent_file
    if ! parent_file="$(task_parent_file_path "$current")"; then
      return 1
    fi

    if task_has_benchmark_profile "$parent_file"; then
      printf '%s' "$parent_file"
      return 0
    fi

    current="$parent_file"
    hop_count=$((hop_count + 1))
  done

  echo "task parent traversal exceeded limit while locating benchmark ancestor: $task_file" >&2
  return 1
}

expected_status_for_task_path() {
  local task_file="$1"
  case "$task_file" in
    "$ROOT"/inbox/*) printf 'inbox' ;;
    "$ROOT"/in_progress/*) printf 'in_progress' ;;
    "$ROOT"/done/*) printf 'done' ;;
    "$ROOT"/blocked/*) printf 'blocked' ;;
    *) printf '' ;;
  esac
}

verify_task_path_status_consistency() {
  local task_file="$1"
  local expected_status
  expected_status="$(expected_status_for_task_path "$task_file")"
  [[ -n "$expected_status" ]] || return 0

  local actual_status
  actual_status="$(field_value "$task_file" "status")"
  actual_status="$(trim_spaces "$actual_status")"

  if [[ "$actual_status" != "$expected_status" ]]; then
    echo "task path/status mismatch: file=$task_file expected_status=$expected_status actual_status=${actual_status:-<empty>}" >&2
    return 1
  fi

  return 0
}

path_exists_in_workspace() {
  local artifact="$1"
  local canonical
  canonical="$(canonicalize_workspace_path_soft "$artifact")" || return 1
  [[ -e "/workspace/$canonical" ]]
}

is_workspace_scoped_path() {
  local value="$1"
  canonicalize_workspace_path_soft "$value" >/dev/null 2>&1
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
  verify_task_path_status_consistency "$task_file" || return 1

  local phase
  phase="$(task_phase_value "$task_file")" || return 1
  local task_has_benchmark=0
  if task_has_benchmark_profile "$task_file"; then
    task_has_benchmark=1
  fi
  local task_has_benchmark_ancestor=0
  if task_parent_chain_has_benchmark_profile "$task_file"; then
    task_has_benchmark_ancestor=1
  fi
  local benchmark_opt_out_reason
  benchmark_opt_out_reason="$(task_benchmark_opt_out_reason "$task_file")"

  case "$phase" in
    execute|review|closeout)
      if [[ "$task_has_benchmark_ancestor" -eq 1 && "$task_has_benchmark" -eq 0 && -z "$benchmark_opt_out_reason" ]]; then
        echo "verify-done failed: benchmark-parent strict phase requires benchmark metadata or benchmark_opt_out_reason (task_id=$task_id phase=$phase)" >&2
        return 1
      fi
      ;;
  esac

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

  local -a result_command_blocks=()
  local -a result_exit_blocks=()
  local -a result_log_blocks=()
  local -a result_observed_blocks=()
  parse_result_command_blocks "$result_body" result_command_blocks result_exit_blocks result_log_blocks result_observed_blocks

  local evidence_cmd
  for evidence_cmd in "${evidence_commands[@]}"; do
    local block_idx
    if ! block_idx="$(command_block_index_for_exact_command "$evidence_cmd" result_command_blocks)"; then
      echo "verify-done failed: missing structured command block for evidence command: $evidence_cmd" >&2
      return 1
    fi

    local block_exit block_log block_observed
    block_exit="${result_exit_blocks[$block_idx]}"
    block_log="${result_log_blocks[$block_idx]}"
    block_observed="${result_observed_blocks[$block_idx]}"

    if ! is_valid_exit_code_value "$block_exit"; then
      echo "verify-done failed: invalid or missing Exit value for command: $evidence_cmd" >&2
      return 1
    fi
    if [[ -z "$block_log" ]]; then
      echo "verify-done failed: missing Log value for command: $evidence_cmd" >&2
      return 1
    fi
    if ! is_workspace_scoped_path "$block_log"; then
      echo "verify-done failed: log path must resolve under /workspace: $block_log" >&2
      return 1
    fi
    if ! path_exists_in_workspace "$block_log"; then
      echo "verify-done failed: log file not found for command: $block_log" >&2
      return 1
    fi
    if [[ -z "$block_observed" ]]; then
      echo "verify-done failed: missing Observed value for command: $evidence_cmd" >&2
      return 1
    fi
  done

  if phase_requires_strict_done_evidence "$phase"; then
    if (( ${#result_command_blocks[@]} == 0 )); then
      echo "verify-done failed: strict phase requires structured Command/Exit/Log/Observed evidence blocks" >&2
      return 1
    fi
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

  if [[ "$task_has_benchmark" -eq 1 ]]; then
    if ! benchmark_verify_task_file "$task_file" >/dev/null; then
      echo "verify-done failed: benchmark evidence contract failed for task_id=$task_id" >&2
      return 1
    fi

    if [[ "$phase" == "closeout" ]]; then
      local profile_file
      profile_file="$(task_benchmark_profile_path "$task_file")"
      local -a score_categories=()
      while IFS= read -r category; do
        [[ -n "$category" ]] || continue
        score_categories+=("$category")
      done < <(jq -r '.weight_order[]? // empty' "$profile_file")
      if (( ${#score_categories[@]} == 0 )); then
        while IFS= read -r category; do
          [[ -n "$category" ]] || continue
          score_categories+=("$category")
        done < <(jq -r '.weights | keys[]' "$profile_file")
      fi

      local category
      for category in "${score_categories[@]}"; do
        if [[ -z "$(extract_result_value_for_key "$result_body" "$category" '[0-9]+([.][0-9]+)?')" ]]; then
          echo "verify-done failed: closeout benchmark task missing category score row for $category" >&2
          return 1
        fi
      done

      if ! benchmark_audit_chain_task_file "$task_file" >/dev/null; then
        echo "verify-done failed: benchmark chain audit failed for task_id=$task_id" >&2
        return 1
      fi

      if ! benchmark_closeout_check_task_file "$task_file" "$agent" >/dev/null; then
        echo "verify-done failed: benchmark closeout check failed for task_id=$task_id" >&2
        return 1
      fi
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

  if ! jq -e '.weights and .gates and .requirements and .closeout' "$profile_file" >/dev/null 2>&1; then
    echo "benchmark-verify failed: invalid benchmark profile schema: $profile_file" >&2
    return 1
  fi

  local result_body
  result_body="$(extract_task_section "$task_file" "Result")"

  local -a requirement_ids=()
  local -a evidence_commands=()
  local -a evidence_artifacts=()
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requirement_ids+=("$item")
  done < <(task_yaml_array_values "$task_file" "requirement_ids")

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    evidence_commands+=("$item")
  done < <(task_yaml_array_values "$task_file" "evidence_commands")

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    evidence_artifacts+=("$item")
  done < <(task_yaml_array_values "$task_file" "evidence_artifacts")

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
  local missing_command_block_evidence=0
  local missing_command_block_fields=0
  local missing_required_artifact_evidence=0
  local missing_rgb_credibility_evidence=0
  local missing_log_hash_evidence=0
  local invalid_log_hash_entries=0
  local mismatched_log_hash_evidence=0
  local -a findings=()

  local -a command_block_commands=()
  local -a command_block_exits=()
  local -a command_block_logs=()
  local -a command_block_log_hashes=()
  local -a command_block_observed=()
  parse_result_command_blocks "$result_body" command_block_commands command_block_exits command_block_logs command_block_observed command_block_log_hashes
  local command_block_count="${#command_block_commands[@]}"

  if (( command_block_count == 0 )); then
    findings+=("missing structured command evidence blocks in ## Result (Command/Exit/Log/Observed)")
    findings_count=$((findings_count + 1))
    missing_command_block_evidence=$((missing_command_block_evidence + 1))
  fi

  if (( ${#requirement_ids[@]} == 0 )); then
    findings+=("requirement_ids frontmatter is empty")
    findings_count=$((findings_count + 1))
  fi

  if (( ${#gate_targets[@]} == 0 )); then
    findings+=("gate_targets frontmatter is empty")
    findings_count=$((findings_count + 1))
  fi

  local cmd_idx
  for cmd_idx in "${!command_block_commands[@]}"; do
    local block_command block_log block_hash
    block_command="${command_block_commands[$cmd_idx]}"
    block_log="${command_block_logs[$cmd_idx]}"
    block_hash="${command_block_log_hashes[$cmd_idx]}"

    if [[ -z "$block_hash" ]]; then
      findings+=("missing Log Hash entry for command block: $block_command")
      findings_count=$((findings_count + 1))
      missing_log_hash_evidence=$((missing_log_hash_evidence + 1))
      continue
    fi

    if ! is_hex_hash_value "$block_hash"; then
      findings+=("invalid Log Hash format for command block: $block_command")
      findings_count=$((findings_count + 1))
      invalid_log_hash_entries=$((invalid_log_hash_entries + 1))
      continue
    fi

    if [[ -z "$block_log" ]]; then
      continue
    fi

    if ! is_workspace_scoped_path "$block_log" || ! path_exists_in_workspace "$block_log"; then
      continue
    fi

    local canonical_log actual_hash normalized_hash
    canonical_log="$(canonicalize_workspace_path_soft "$block_log")" || continue
    actual_hash="$(compute_file_hash "/workspace/$canonical_log")"
    normalized_hash="$(printf '%s' "$block_hash" | tr '[:upper:]' '[:lower:]')"

    if [[ "$actual_hash" != "$normalized_hash" ]]; then
      findings+=("Log Hash mismatch for command block: $block_command")
      findings_count=$((findings_count + 1))
      mismatched_log_hash_evidence=$((mismatched_log_hash_evidence + 1))
    fi
  done

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
      local required_idx
      if ! required_idx="$(command_block_index_for_exact_command "$required_cmd" command_block_commands)"; then
        findings+=("missing required command evidence for $gate_id: $required_cmd")
        findings_count=$((findings_count + 1))
        missing_required_command_evidence=$((missing_required_command_evidence + 1))
        continue
      fi

      local required_exit required_log required_observed
      required_exit="${command_block_exits[$required_idx]}"
      required_log="${command_block_logs[$required_idx]}"
      required_observed="${command_block_observed[$required_idx]}"

      if ! is_valid_exit_code_value "$required_exit"; then
        findings+=("invalid exit code for $gate_id required command: $required_cmd")
        findings_count=$((findings_count + 1))
        missing_command_block_fields=$((missing_command_block_fields + 1))
      elif [[ "$required_exit" != "0" ]]; then
        findings+=("required command for $gate_id did not pass (exit=$required_exit): $required_cmd")
        findings_count=$((findings_count + 1))
        missing_required_command_evidence=$((missing_required_command_evidence + 1))
      fi

      if [[ -z "$required_log" ]]; then
        findings+=("missing log path for $gate_id required command: $required_cmd")
        findings_count=$((findings_count + 1))
        missing_command_block_fields=$((missing_command_block_fields + 1))
      elif ! is_workspace_scoped_path "$required_log"; then
        findings+=("log path must resolve under /workspace for $gate_id required command: $required_log")
        findings_count=$((findings_count + 1))
        missing_command_block_fields=$((missing_command_block_fields + 1))
      elif ! path_exists_in_workspace "$required_log"; then
        findings+=("log artifact missing for $gate_id required command: $required_log")
        findings_count=$((findings_count + 1))
        missing_command_block_fields=$((missing_command_block_fields + 1))
      fi

      if [[ -z "$required_observed" ]]; then
        findings+=("missing observed summary for $gate_id required command: $required_cmd")
        findings_count=$((findings_count + 1))
        missing_command_block_fields=$((missing_command_block_fields + 1))
      fi
    done

    local -a required_command_patterns=()
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      required_command_patterns+=("$pattern")
    done < <(jq -r --arg gate "$gate_id" '.gate_required_command_patterns[$gate][]? // empty' "$profile_file")

    local required_pattern
    for required_pattern in "${required_command_patterns[@]}"; do
      if ! command_block_matches_pattern_with_passing_exit "$required_pattern" command_block_commands command_block_exits command_block_logs; then
        findings+=("missing passing command evidence matching pattern for $gate_id: $required_pattern")
        findings_count=$((findings_count + 1))
        missing_required_command_evidence=$((missing_required_command_evidence + 1))
      fi
    done
  done

  local -a workspace_artifacts=()
  local artifact_candidate canonical_candidate
  for artifact_candidate in "${evidence_artifacts[@]}"; do
    [[ -n "$artifact_candidate" ]] || continue
    if canonical_candidate="$(canonicalize_workspace_path_soft "$artifact_candidate")" && [[ -e "/workspace/$canonical_candidate" ]]; then
      append_unique_array_value workspace_artifacts "$canonical_candidate"
      append_unique_array_value workspace_artifacts "/workspace/$canonical_candidate"
    fi
  done
  for artifact_candidate in "${command_block_logs[@]}"; do
    [[ -n "$artifact_candidate" ]] || continue
    if canonical_candidate="$(canonicalize_workspace_path_soft "$artifact_candidate")" && [[ -e "/workspace/$canonical_candidate" ]]; then
      append_unique_array_value workspace_artifacts "$canonical_candidate"
      append_unique_array_value workspace_artifacts "/workspace/$canonical_candidate"
    fi
  done

  local gate_for_artifacts
  for gate_for_artifacts in "${gate_targets[@]}"; do
    local -a required_artifact_patterns=()
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      required_artifact_patterns+=("$pattern")
    done < <(jq -r --arg gate "$gate_for_artifacts" '.gate_required_artifact_patterns[$gate][]? // empty' "$profile_file")

    local artifact_pattern
    for artifact_pattern in "${required_artifact_patterns[@]}"; do
      local matched=0
      for artifact_candidate in "${workspace_artifacts[@]}"; do
        if printf '%s' "$artifact_candidate" | grep -Eq -- "$artifact_pattern"; then
          matched=1
          break
        fi
      done

      if [[ "$matched" -eq 0 ]]; then
        findings+=("missing required artifact evidence for $gate_for_artifacts pattern: $artifact_pattern")
        findings_count=$((findings_count + 1))
        missing_required_artifact_evidence=$((missing_required_artifact_evidence + 1))
      fi
    done
  done

  local expected_cmd
  for expected_cmd in "${evidence_commands[@]}"; do
    local evidence_idx
    if ! evidence_idx="$(command_block_index_for_exact_command "$expected_cmd" command_block_commands)"; then
      findings+=("structured command block missing for evidence_commands entry: $expected_cmd")
      findings_count=$((findings_count + 1))
      missing_command_block_evidence=$((missing_command_block_evidence + 1))
      continue
    fi

    local evidence_exit evidence_log evidence_observed
    evidence_exit="${command_block_exits[$evidence_idx]}"
    evidence_log="${command_block_logs[$evidence_idx]}"
    evidence_observed="${command_block_observed[$evidence_idx]}"

    if ! is_valid_exit_code_value "$evidence_exit"; then
      findings+=("invalid exit code in evidence command block: $expected_cmd")
      findings_count=$((findings_count + 1))
      missing_command_block_fields=$((missing_command_block_fields + 1))
    fi
    if [[ -z "$evidence_log" ]]; then
      findings+=("missing log path in evidence command block: $expected_cmd")
      findings_count=$((findings_count + 1))
      missing_command_block_fields=$((missing_command_block_fields + 1))
    elif ! is_workspace_scoped_path "$evidence_log"; then
      findings+=("evidence command log path must resolve under /workspace: $evidence_log")
      findings_count=$((findings_count + 1))
      missing_command_block_fields=$((missing_command_block_fields + 1))
    elif ! path_exists_in_workspace "$evidence_log"; then
      findings+=("evidence command log missing: $evidence_log")
      findings_count=$((findings_count + 1))
      missing_command_block_fields=$((missing_command_block_fields + 1))
    fi
    if [[ -z "$evidence_observed" ]]; then
      findings+=("missing observed summary in evidence command block: $expected_cmd")
      findings_count=$((findings_count + 1))
      missing_command_block_fields=$((missing_command_block_fields + 1))
    fi
  done

  local g6_targeted=0
  local gate_target
  for gate_target in "${gate_targets[@]}"; do
    if [[ "$gate_target" == "G6" ]]; then
      g6_targeted=1
      break
    fi
  done

  local require_rgb
  require_rgb="$(jq -r '.credibility_checks.G6.require_rgb // false' "$profile_file")"
  if [[ "$g6_targeted" -eq 1 && "$require_rgb" == "true" ]]; then
    local red_command green_command blue_command red_exit green_exit blue_exit red_log green_log blue_log
    red_command="$(extract_result_text_for_key "$result_body" "Red Command")"
    green_command="$(extract_result_text_for_key "$result_body" "Green Command")"
    blue_command="$(extract_result_text_for_key "$result_body" "Blue Command")"
    red_exit="$(extract_result_value_for_key "$result_body" "Red Exit" '-?[0-9]+')"
    green_exit="$(extract_result_value_for_key "$result_body" "Green Exit" '-?[0-9]+')"
    blue_exit="$(extract_result_value_for_key "$result_body" "Blue Exit" '-?[0-9]+')"
    red_log="$(extract_result_text_for_key "$result_body" "Red Log")"
    green_log="$(extract_result_text_for_key "$result_body" "Green Log")"
    blue_log="$(extract_result_text_for_key "$result_body" "Blue Log")"

    if [[ -z "$red_command" || -z "$green_command" || -z "$blue_command" ]]; then
      findings+=("missing RGB command entries (Red/Green/Blue Command)")
      findings_count=$((findings_count + 1))
      missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
    fi

    if ! is_valid_exit_code_value "$red_exit" || [[ "$red_exit" == "0" ]]; then
      findings+=("invalid RGB credibility: Red Exit must be non-zero")
      findings_count=$((findings_count + 1))
      missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
    fi
    if ! is_valid_exit_code_value "$green_exit" || [[ "$green_exit" != "0" ]]; then
      findings+=("invalid RGB credibility: Green Exit must be 0")
      findings_count=$((findings_count + 1))
      missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
    fi
    if ! is_valid_exit_code_value "$blue_exit" || [[ "$blue_exit" != "0" ]]; then
      findings+=("invalid RGB credibility: Blue Exit must be 0")
      findings_count=$((findings_count + 1))
      missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
    fi

    local rgb_log
    for rgb_log in "$red_log" "$green_log" "$blue_log"; do
      if [[ -z "$rgb_log" ]]; then
        findings+=("missing RGB log entry")
        findings_count=$((findings_count + 1))
        missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
        continue
      fi
      if ! is_workspace_scoped_path "$rgb_log"; then
        findings+=("RGB log path must resolve under /workspace: $rgb_log")
        findings_count=$((findings_count + 1))
        missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
        continue
      fi
      if ! path_exists_in_workspace "$rgb_log"; then
        findings+=("RGB log artifact missing: $rgb_log")
        findings_count=$((findings_count + 1))
        missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
      fi
    done

    local red_pattern green_pattern blue_pattern
    red_pattern="$(jq -r '.credibility_checks.G6.red_command_pattern // ""' "$profile_file")"
    green_pattern="$(jq -r '.credibility_checks.G6.green_command_pattern // ""' "$profile_file")"
    blue_pattern="$(jq -r '.credibility_checks.G6.blue_command_pattern // ""' "$profile_file")"

    if [[ -n "$red_pattern" && -n "$red_command" ]] && ! printf '%s' "$red_command" | grep -Eq -- "$red_pattern"; then
      findings+=("Red Command does not match required pattern: $red_pattern")
      findings_count=$((findings_count + 1))
      missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
    fi
    if [[ -n "$green_pattern" && -n "$green_command" ]] && ! printf '%s' "$green_command" | grep -Eq -- "$green_pattern"; then
      findings+=("Green Command does not match required pattern: $green_pattern")
      findings_count=$((findings_count + 1))
      missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
    fi
    if [[ -n "$blue_pattern" && -n "$blue_command" ]] && ! printf '%s' "$blue_command" | grep -Eq -- "$blue_pattern"; then
      findings+=("Blue Command does not match required pattern: $blue_pattern")
      findings_count=$((findings_count + 1))
      missing_rgb_credibility_evidence=$((missing_rgb_credibility_evidence + 1))
    fi
  fi

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
    --argjson missing_command_block_evidence "$missing_command_block_evidence" \
    --argjson missing_command_block_fields "$missing_command_block_fields" \
    --argjson missing_required_artifact_evidence "$missing_required_artifact_evidence" \
    --argjson missing_rgb_credibility_evidence "$missing_rgb_credibility_evidence" \
    --argjson missing_log_hash_evidence "$missing_log_hash_evidence" \
    --argjson invalid_log_hash_entries "$invalid_log_hash_entries" \
    --argjson mismatched_log_hash_evidence "$mismatched_log_hash_evidence" \
    --argjson command_block_count "$command_block_count" \
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
      missing_command_block_evidence: $missing_command_block_evidence,
      missing_command_block_fields: $missing_command_block_fields,
      missing_required_artifact_evidence: $missing_required_artifact_evidence,
      missing_rgb_credibility_evidence: $missing_rgb_credibility_evidence,
      missing_log_hash_evidence: $missing_log_hash_evidence,
      invalid_log_hash_entries: $invalid_log_hash_entries,
      mismatched_log_hash_evidence: $mismatched_log_hash_evidence,
      command_block_count: $command_block_count,
      findings_count: $findings_count,
      findings: $findings,
      data_valid: $data_valid
    }')"

  if [[ "$output_mode" == "json" ]]; then
    printf '%s\n' "$summary_json"
  else
    echo "benchmark-verify: task_file=$task_file"
    echo "benchmark-verify: profile_file=$profile_file"
    echo "benchmark-verify: requirement_ids=${#requirement_ids[@]} gate_targets=${#gate_targets[@]} command_blocks=$command_block_count findings=$findings_count"
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

benchmark_rerun_task_file() {
  local task_file="$1"
  local agent="$2"
  require_command jq

  [[ -f "$task_file" ]] || {
    echo "benchmark-rerun failed: task file not found: $task_file" >&2
    return 1
  }
  require_agent "$agent"

  local profile_file
  profile_file="$(task_benchmark_profile_path "$task_file")"
  [[ -f "$profile_file" ]] || {
    echo "benchmark-rerun failed: benchmark profile not found: $profile_file" >&2
    return 1
  }

  local workdir
  workdir="$(task_benchmark_workdir_path "$task_file")" || return 1

  local summary_json_path
  summary_json_path="$(task_benchmark_rerun_summary_path "$task_file" "$agent")" || return 1
  local summary_dir
  summary_dir="$(dirname "$summary_json_path")"
  mkdir -p "$summary_dir"

  local log_dir="${summary_json_path%.json}"
  if [[ "$log_dir" == "$summary_json_path" ]]; then
    log_dir="${summary_json_path}.logs"
  fi
  mkdir -p "$log_dir"

  local -a rerun_commands=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    rerun_commands+=("$cmd")
  done < <(task_benchmark_required_rerun_commands "$task_file")

  if (( ${#rerun_commands[@]} == 0 )); then
    echo "benchmark-rerun failed: no required rerun commands configured for task: $task_file" >&2
    return 1
  fi

  local all_pass=true
  local command_results='[]'
  local i rerun_cmd log_file log_hash rc
  for i in "${!rerun_commands[@]}"; do
    rerun_cmd="${rerun_commands[$i]}"
    log_file="$log_dir/cmd_$(printf '%03d' "$i").log"

    set +e
    (
      cd "$workdir"
      bash -lc "$rerun_cmd"
    ) >"$log_file" 2>&1
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
      all_pass=false
    fi

    log_hash="$(compute_file_hash "$log_file")"
    command_results="$(jq -cn \
      --argjson base "$command_results" \
      --arg command "$rerun_cmd" \
      --argjson exit "$rc" \
      --arg log "$log_file" \
      --arg log_hash "$log_hash" \
      '$base + [{command: $command, exit: $exit, log: $log, log_hash: $log_hash}]')"
  done

  local task_id
  task_id="$(task_id_from_file "$task_file")"
  local generated_at
  generated_at="$(now)"
  local generated_epoch
  generated_epoch="$(timestamp_to_epoch "$generated_at")"
  local task_file_hash profile_hash required_commands_json required_commands_hash
  task_file_hash="$(compute_file_hash "$task_file")"
  profile_hash="$(compute_file_hash "$profile_file")"
  required_commands_json="$(json_array_from_values "${rerun_commands[@]}")"
  required_commands_hash="$(compute_text_hash "$required_commands_json")"

  jq -cn \
    --arg generated_at "$generated_at" \
    --argjson generated_epoch "$generated_epoch" \
    --arg task_id "$task_id" \
    --arg task_file "$task_file" \
    --arg task_file_hash "$task_file_hash" \
    --arg agent "$agent" \
    --arg workdir "$workdir" \
    --arg profile_file "$profile_file" \
    --arg profile_hash "$profile_hash" \
    --argjson required_commands "$required_commands_json" \
    --arg required_commands_hash "$required_commands_hash" \
    --argjson commands "$command_results" \
    --argjson all_pass "$all_pass" \
    '{
      generated_at: $generated_at,
      generated_epoch: $generated_epoch,
      task_id: $task_id,
      task_file: $task_file,
      task_file_hash: $task_file_hash,
      agent: $agent,
      workdir: $workdir,
      profile_file: $profile_file,
      profile_hash: $profile_hash,
      required_commands: $required_commands,
      required_commands_hash: $required_commands_hash,
      all_pass: $all_pass,
      commands: $commands
    }' >"$summary_json_path"

  if [[ "$all_pass" == "true" ]]; then
    echo "benchmark-rerun passed: summary=$summary_json_path"
    return 0
  fi

  echo "benchmark-rerun failed: summary=$summary_json_path" >&2
  jq -r '.commands[]? | select(.exit != 0) | "failed command: \(.command) (exit=\(.exit), log=\(.log))"' "$summary_json_path" >&2 || true
  return 1
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
  weak_evidence_count="$(printf '%s' "$verify_json" | jq -r '.missing_requirement_status_entries + .missing_gate_status_entries + .missing_required_command_evidence + .missing_command_block_evidence + .missing_command_block_fields + .missing_required_artifact_evidence + .missing_rgb_credibility_evidence + (.missing_log_hash_evidence // 0) + (.invalid_log_hash_entries // 0) + (.mismatched_log_hash_evidence // 0)')"

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

benchmark_requirement_consistency_check_task_file() {
  local task_file="$1"

  local -a root_requirement_ids=()
  while IFS= read -r requirement_id; do
    [[ -n "$requirement_id" ]] || continue
    root_requirement_ids+=("$requirement_id")
  done < <(task_yaml_array_values "$task_file" "requirement_ids" 2>/dev/null || true)

  if (( ${#root_requirement_ids[@]} == 0 )); then
    return 0
  fi

  local root_result_body
  root_result_body="$(extract_task_section "$task_file" "Result")"

  local -a execute_min_rank=()
  local -a review_min_rank=()
  local idx
  for idx in "${!root_requirement_ids[@]}"; do
    execute_min_rank+=("99")
    review_min_rank+=("99")
  done

  local chain_task_file
  while IFS= read -r chain_task_file; do
    [[ -n "$chain_task_file" ]] || continue
    if [[ "$chain_task_file" == "$task_file" ]]; then
      continue
    fi

    local chain_phase
    chain_phase="$(task_phase_value "$chain_task_file" 2>/dev/null || true)"
    if [[ "$chain_phase" != "execute" && "$chain_phase" != "review" ]]; then
      continue
    fi

    local chain_result_body
    chain_result_body="$(extract_task_section "$chain_task_file" "Result")"

    for idx in "${!root_requirement_ids[@]}"; do
      local requirement_id status rank current_rank
      requirement_id="${root_requirement_ids[$idx]}"
      status="$(extract_result_value_for_key "$chain_result_body" "$requirement_id" 'Met|Partial|Missing|Unverifiable')"
      [[ -n "$status" ]] || continue
      rank="$(requirement_status_rank "$status")"

      if [[ "$chain_phase" == "review" ]]; then
        current_rank="${review_min_rank[$idx]}"
        if (( rank < current_rank )); then
          review_min_rank[$idx]="$rank"
        fi
      else
        current_rank="${execute_min_rank[$idx]}"
        if (( rank < current_rank )); then
          execute_min_rank[$idx]="$rank"
        fi
      fi
    done
  done < <(benchmark_collect_chain_task_files "$task_file")

  local -a findings=()
  for idx in "${!root_requirement_ids[@]}"; do
    local requirement_id parent_status parent_rank source_rank source_phase source_status
    requirement_id="${root_requirement_ids[$idx]}"
    parent_status="$(extract_result_value_for_key "$root_result_body" "$requirement_id" 'Met|Partial|Missing|Unverifiable')"
    if [[ -z "$parent_status" ]]; then
      findings+=("root closeout missing requirement status row for $requirement_id")
      continue
    fi
    parent_rank="$(requirement_status_rank "$parent_status")"

    source_rank="99"
    source_phase=""
    if (( review_min_rank[$idx] != 99 )); then
      source_rank="${review_min_rank[$idx]}"
      source_phase="review"
    elif (( execute_min_rank[$idx] != 99 )); then
      source_rank="${execute_min_rank[$idx]}"
      source_phase="execute"
    fi

    if [[ "$source_phase" == "" ]]; then
      continue
    fi

    if (( parent_rank > source_rank )); then
      source_status="$(requirement_status_for_rank "$source_rank")"
      findings+=("root closeout requirement $requirement_id status=$parent_status exceeds $source_phase evidence floor=$source_status")
    fi
  done

  if (( ${#findings[@]} > 0 )); then
    local finding
    for finding in "${findings[@]}"; do
      echo "benchmark-closeout consistency finding: $finding"
    done
    return 1
  fi

  return 0
}

benchmark_init_task_file() {
  local task_file="$1"
  require_command jq

  [[ -f "$task_file" ]] || {
    echo "benchmark-init failed: task file not found: $task_file" >&2
    return 1
  }

  local benchmark_opt_out_reason
  benchmark_opt_out_reason="$(task_benchmark_opt_out_reason "$task_file")"
  if [[ -n "$benchmark_opt_out_reason" ]]; then
    echo "benchmark-init failed: task has benchmark_opt_out_reason and is not benchmark-scored: $task_file" >&2
    return 1
  fi

  local benchmark_profile_value
  benchmark_profile_value="$(normalize_benchmark_scalar "$(task_yaml_scalar_value "$task_file" "benchmark_profile" 2>/dev/null || true)")"
  if [[ "$benchmark_profile_value" == "none" ]]; then
    local default_profile_value="$DEFAULT_BENCHMARK_PROFILE_PATH"
    if [[ -f "$ROOT/benchmark_profiles/vault_sync_prompt_v1.json" ]]; then
      default_profile_value="benchmark_profiles/vault_sync_prompt_v1.json"
    fi
    set_field "$task_file" "benchmark_profile" "$(yaml_quote_single "$default_profile_value")"
  fi

  local profile_file
  profile_file="$(task_benchmark_profile_path "$task_file")"
  [[ -f "$profile_file" ]] || {
    echo "benchmark-init failed: benchmark profile not found: $profile_file" >&2
    return 1
  }

  local benchmark_workdir_value
  benchmark_workdir_value="$(task_yaml_scalar_value "$task_file" "benchmark_workdir" 2>/dev/null || true)"
  benchmark_workdir_value="$(printf '%s' "$benchmark_workdir_value" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"
  if [[ -z "$benchmark_workdir_value" || "$benchmark_workdir_value" == "none" || "$benchmark_workdir_value" == "null" ]]; then
    set_field "$task_file" "benchmark_workdir" "'.'"
  fi

  local task_id
  task_id="$(task_id_from_file "$task_file")"
  local owner_agent
  owner_agent="$(field_value "$task_file" "owner_agent")"
  if [[ -z "$owner_agent" || "$owner_agent" == "none" ]]; then
    owner_agent="coordinator"
  fi

  local scorecard_artifact_value
  scorecard_artifact_value="$(normalize_benchmark_scalar "$(task_yaml_scalar_value "$task_file" "scorecard_artifact" 2>/dev/null || true)")"
  if [[ "$scorecard_artifact_value" == "none" ]]; then
    scorecard_artifact_value="$(default_scorecard_artifact_for_task "$owner_agent" "$task_id")"
    set_field "$task_file" "scorecard_artifact" "$(yaml_quote_single "$scorecard_artifact_value")"
  fi

  local -a requirement_ids=()
  while IFS= read -r requirement_id; do
    [[ -n "$requirement_id" ]] || continue
    requirement_ids+=("$requirement_id")
  done < <(task_yaml_array_values "$task_file" "requirement_ids" 2>/dev/null || true)
  if (( ${#requirement_ids[@]} == 0 )); then
    while IFS= read -r requirement_id; do
      [[ -n "$requirement_id" ]] || continue
      requirement_ids+=("$requirement_id")
    done < <(jq -r '.requirements[]?.id // empty' "$profile_file")
    if (( ${#requirement_ids[@]} > 0 )); then
      set_field "$task_file" "requirement_ids" "$(yaml_inline_list "${requirement_ids[@]}")"
    fi
  fi

  local -a gate_targets=()
  while IFS= read -r gate_target; do
    [[ -n "$gate_target" ]] || continue
    gate_targets+=("$gate_target")
  done < <(task_yaml_array_values "$task_file" "gate_targets" 2>/dev/null || true)
  if (( ${#gate_targets[@]} == 0 )); then
    while IFS= read -r gate_target; do
      [[ -n "$gate_target" ]] || continue
      gate_targets+=("$gate_target")
    done < <(benchmark_gate_targets_for_profile "$profile_file")
    if (( ${#gate_targets[@]} > 0 )); then
      set_field "$task_file" "gate_targets" "$(yaml_inline_list "${gate_targets[@]}")"
    fi
  fi

  local -a evidence_commands=()
  while IFS= read -r evidence_command; do
    [[ -n "$evidence_command" ]] || continue
    evidence_commands+=("$evidence_command")
  done < <(task_yaml_array_values "$task_file" "evidence_commands" 2>/dev/null || true)
  if (( ${#evidence_commands[@]} == 0 )); then
    while IFS= read -r evidence_command; do
      [[ -n "$evidence_command" ]] || continue
      evidence_commands+=("$evidence_command")
    done < <(task_benchmark_required_rerun_commands "$task_file")
    if (( ${#evidence_commands[@]} > 0 )); then
      set_field "$task_file" "evidence_commands" "$(yaml_inline_list "${evidence_commands[@]}")"
    fi
  fi

  local log_root_relative
  log_root_relative="$(canonicalize_workspace_path_soft "$ROOT/reports/$owner_agent/benchmark_logs/$task_id")"
  local log_root_absolute="/workspace/$log_root_relative"
  mkdir -p "$log_root_absolute"

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

  local include_g6=0
  local gate_target
  for gate_target in "${gate_targets[@]}"; do
    if [[ "$gate_target" == "G6" ]]; then
      include_g6=1
      break
    fi
  done

  local result_tmp
  result_tmp="$(mktemp)"
  {
    echo "Requirement Statuses:"
    local requirement_id
    for requirement_id in "${requirement_ids[@]}"; do
      echo "- $requirement_id: Unverifiable"
    done
    echo
    echo "Acceptance Criteria:"
    echo "- PENDING: replace with explicit pass/fail outcomes"
    echo
    echo "Gate Statuses:"
    for gate_target in "${gate_targets[@]}"; do
      echo "- $gate_target: fail"
    done
    echo

    if [[ "$include_g6" -eq 1 ]]; then
      echo "- Red Command: replace-with-red-check"
      echo "- Red Exit: 1"
      echo "- Red Log: $log_root_absolute/rgb-red.log"
      echo "- Green Command: replace-with-green-check"
      echo "- Green Exit: 0"
      echo "- Green Log: $log_root_absolute/rgb-green.log"
      echo "- Blue Command: replace-with-blue-check"
      echo "- Blue Exit: 0"
      echo "- Blue Log: $log_root_absolute/rgb-blue.log"
      echo
    fi

    local category
    for category in "${weight_order[@]}"; do
      echo "- $category: 0"
    done
    echo

    local i evidence_command log_path
    for i in "${!evidence_commands[@]}"; do
      evidence_command="${evidence_commands[$i]}"
      log_path="$log_root_absolute/cmd_$(printf '%03d' "$i").log"
      echo "Command: $evidence_command"
      echo "Exit: 0"
      echo "Log: $log_path"
      echo "Log Hash: pending"
      echo "Observed: pending"
      echo
    done
  } >"$result_tmp"

  replace_task_section_from_file "$task_file" "Result" "$result_tmp"
  rm -f "$result_tmp"

  set_field "$task_file" "updated_at" "$(now)"

  echo "benchmark-init: task_file=$task_file profile=$profile_file commands=${#evidence_commands[@]} requirements=${#requirement_ids[@]} gates=${#gate_targets[@]}"
}

benchmark_closeout_check_task_file() {
  local task_file="$1"
  local agent="${2:-coordinator}"
  require_command jq

  local profile_file
  profile_file="$(task_benchmark_profile_path "$task_file")"
  [[ -f "$profile_file" ]] || {
    echo "benchmark-closeout-check failed: profile file not found: $profile_file" >&2
    return 1
  }

  local require_independent_rerun
  require_independent_rerun="$(jq -r '.closeout.require_independent_rerun // true' "$profile_file")"
  local rerun_agent
  rerun_agent="$(jq -r '.closeout.independent_rerun_agent // "review"' "$profile_file")"
  rerun_agent="$(printf '%s' "$rerun_agent" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -n "$rerun_agent" ]] || rerun_agent="review"
  require_agent "$rerun_agent"

  if [[ "$require_independent_rerun" == "true" && "$rerun_agent" != "review" ]]; then
    echo "benchmark-closeout-check failed: independent rerun agent must be review (configured=$rerun_agent)" >&2
    return 1
  fi

  if [[ "$require_independent_rerun" == "true" ]]; then
    if ! benchmark_rerun_task_file "$task_file" "$rerun_agent" >/dev/null; then
      echo "benchmark-closeout-check failed: independent rerun failed (agent=$rerun_agent)" >&2
      return 1
    fi
  fi

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

  if [[ "$require_independent_rerun" == "true" ]]; then
    local rerun_summary_path rerun_all_pass
    rerun_summary_path="$(task_benchmark_rerun_summary_path "$task_file" "$rerun_agent")"
    [[ -f "$rerun_summary_path" ]] || {
      echo "benchmark-closeout-check failed: rerun summary missing: $rerun_summary_path" >&2
      return 1
    }

    local summary_agent
    summary_agent="$(jq -r '.agent // ""' "$rerun_summary_path")"
    if [[ "$summary_agent" != "review" ]]; then
      echo "benchmark-closeout-check failed: rerun summary is not review-owned: $rerun_summary_path (agent=$summary_agent)" >&2
      return 1
    fi

    rerun_all_pass="$(jq -r '.all_pass' "$rerun_summary_path")"
    if [[ "$rerun_all_pass" != "true" ]]; then
      echo "benchmark-closeout-check failed: rerun summary indicates failed commands: $rerun_summary_path" >&2
      jq -r '.commands[]? | select(.exit != 0) | "rerun failure: \(.command) (exit=\(.exit), log=\(.log))"' "$rerun_summary_path"
      return 1
    fi

    local current_task_file_hash summary_task_file_hash
    current_task_file_hash="$(compute_file_hash "$task_file")"
    summary_task_file_hash="$(jq -r '.task_file_hash // ""' "$rerun_summary_path")"
    if [[ -z "$summary_task_file_hash" || "$summary_task_file_hash" != "$current_task_file_hash" ]]; then
      echo "benchmark-closeout-check failed: rerun summary task_file_hash mismatch (summary=$summary_task_file_hash current=$current_task_file_hash)" >&2
      return 1
    fi

    local current_profile_hash summary_profile_hash
    current_profile_hash="$(compute_file_hash "$profile_file")"
    summary_profile_hash="$(jq -r '.profile_hash // ""' "$rerun_summary_path")"
    if [[ -z "$summary_profile_hash" || "$summary_profile_hash" != "$current_profile_hash" ]]; then
      echo "benchmark-closeout-check failed: rerun summary profile_hash mismatch (summary=$summary_profile_hash current=$current_profile_hash)" >&2
      return 1
    fi

    local -a rerun_commands=()
    while IFS= read -r rerun_cmd; do
      [[ -n "$rerun_cmd" ]] || continue
      rerun_commands+=("$rerun_cmd")
    done < <(task_benchmark_required_rerun_commands "$task_file")
    local expected_commands_json expected_commands_hash summary_commands_hash
    expected_commands_json="$(json_array_from_values "${rerun_commands[@]}")"
    expected_commands_hash="$(compute_text_hash "$expected_commands_json")"
    summary_commands_hash="$(jq -r '.required_commands_hash // ""' "$rerun_summary_path")"
    if [[ -z "$summary_commands_hash" || "$summary_commands_hash" != "$expected_commands_hash" ]]; then
      echo "benchmark-closeout-check failed: rerun summary required_commands_hash mismatch (summary=$summary_commands_hash current=$expected_commands_hash)" >&2
      return 1
    fi

    local hash_failures=0
    local summary_cmd summary_log summary_log_hash
    while IFS=$'\t' read -r summary_cmd summary_log summary_log_hash; do
      [[ -n "$summary_cmd" ]] || continue
      if [[ -z "$summary_log_hash" ]] || ! is_hex_hash_value "$summary_log_hash"; then
        echo "benchmark-closeout-check failed: rerun command missing/invalid log_hash: $summary_cmd" >&2
        hash_failures=$((hash_failures + 1))
        continue
      fi
      if [[ -z "$summary_log" || ! -f "$summary_log" ]]; then
        echo "benchmark-closeout-check failed: rerun command log missing: $summary_cmd log=$summary_log" >&2
        hash_failures=$((hash_failures + 1))
        continue
      fi

      local actual_summary_hash normalized_summary_hash
      actual_summary_hash="$(compute_file_hash "$summary_log")"
      normalized_summary_hash="$(printf '%s' "$summary_log_hash" | tr '[:upper:]' '[:lower:]')"
      if [[ "$actual_summary_hash" != "$normalized_summary_hash" ]]; then
        echo "benchmark-closeout-check failed: rerun command log hash mismatch: $summary_cmd" >&2
        hash_failures=$((hash_failures + 1))
      fi
    done < <(jq -r '.commands[]? | [.command, (.log // ""), (.log_hash // "")] | @tsv' "$rerun_summary_path")

    if (( hash_failures > 0 )); then
      return 1
    fi

    local summary_generated_epoch summary_generated_at latest_execute_epoch
    summary_generated_epoch="$(jq -r '.generated_epoch // 0' "$rerun_summary_path")"
    if ! [[ "$summary_generated_epoch" =~ ^[0-9]+$ ]] || (( summary_generated_epoch <= 0 )); then
      summary_generated_at="$(jq -r '.generated_at // ""' "$rerun_summary_path")"
      summary_generated_epoch="$(timestamp_to_epoch "$summary_generated_at")"
    fi
    latest_execute_epoch="$(latest_execute_updated_epoch_in_chain "$task_file")"
    if [[ "$latest_execute_epoch" =~ ^[0-9]+$ ]] && (( latest_execute_epoch > 0 )) && (( summary_generated_epoch < latest_execute_epoch )); then
      echo "benchmark-closeout-check failed: rerun summary stale vs execute updates (rerun_epoch=$summary_generated_epoch latest_execute_epoch=$latest_execute_epoch)" >&2
      return 1
    fi
  fi

  if ! benchmark_requirement_consistency_check_task_file "$task_file"; then
    echo "benchmark-closeout-check failed: closeout requirement statuses conflict with child execute/review outcomes"
    return 1
  fi

  if [[ "$ready" != "true" ]]; then
    echo "benchmark-closeout-check failed: final_total=$final_total min_score=$min_score require_all_gates_pass=$require_all_gates_pass all_target_gates_pass=$all_target_gates_pass"
    jq -r '.findings[]? | "finding: " + .' "$scorecard_json_path"
    return 1
  fi

  echo "benchmark-closeout-check passed: final_total=$final_total min_score=$min_score all_target_gates_pass=$all_target_gates_pass require_independent_rerun=$require_independent_rerun rerun_agent=$rerun_agent"
}

benchmark_audit_chain_task_file() {
  local task_file="$1"

  [[ -f "$task_file" ]] || {
    echo "benchmark-audit-chain failed: task file not found: $task_file" >&2
    return 1
  }

  local root_task_id
  root_task_id="$(task_id_from_file "$task_file")"

  local root_has_benchmark=0
  if task_has_benchmark_profile "$task_file"; then
    root_has_benchmark=1
  fi

  local profile_file=""
  if [[ "$root_has_benchmark" -eq 1 ]]; then
    profile_file="$(task_benchmark_profile_path "$task_file")"
  fi

  local -a chain_files=()
  while IFS= read -r chain_file; do
    [[ -n "$chain_file" ]] || continue
    chain_files+=("$chain_file")
  done < <(benchmark_collect_chain_task_files "$task_file")

  local -a root_requirement_ids=()
  while IFS= read -r requirement_id; do
    [[ -n "$requirement_id" ]] || continue
    root_requirement_ids+=("$requirement_id")
  done < <(task_yaml_array_values "$task_file" "requirement_ids" 2>/dev/null || true)
  if (( ${#root_requirement_ids[@]} == 0 )) && [[ "$root_has_benchmark" -eq 1 ]] && [[ -f "$profile_file" ]]; then
    while IFS= read -r requirement_id; do
      [[ -n "$requirement_id" ]] || continue
      root_requirement_ids+=("$requirement_id")
    done < <(jq -r '.requirements[]?.id // empty' "$profile_file")
  fi

  local -a requirement_execute_coverage=()
  local -a requirement_review_coverage=()
  local req_index
  for req_index in "${!root_requirement_ids[@]}"; do
    requirement_execute_coverage+=("0")
    requirement_review_coverage+=("0")
  done

  local -a findings=()
  local has_execute=0
  local has_review=0
  local has_closeout=0
  local has_child_benchmark=0

  local chain_task_file
  for chain_task_file in "${chain_files[@]}"; do
    if ! verify_task_path_status_consistency "$chain_task_file"; then
      findings+=("path/status mismatch: $chain_task_file")
      continue
    fi

    local chain_phase
    chain_phase="$(task_phase_value "$chain_task_file" 2>/dev/null || true)"
    case "$chain_phase" in
      execute) has_execute=1 ;;
      review) has_review=1 ;;
      closeout) has_closeout=1 ;;
    esac

    if [[ "$chain_phase" == "execute" || "$chain_phase" == "review" || "$chain_phase" == "closeout" ]]; then
      local req_count=0
      local ev_count=0
      local -a chain_requirement_ids=()
      while IFS= read -r task_requirement_id; do
        [[ -n "$task_requirement_id" ]] || continue
        chain_requirement_ids+=("$task_requirement_id")
      done < <(task_yaml_array_values "$chain_task_file" "requirement_ids" 2>/dev/null || true)
      req_count="${#chain_requirement_ids[@]}"
      while IFS= read -r _; do
        ev_count=$((ev_count + 1))
      done < <(task_yaml_array_values "$chain_task_file" "evidence_commands" 2>/dev/null || true)

      if [[ "$req_count" -eq 0 ]]; then
        findings+=("missing requirement_ids for strict phase task: $chain_task_file")
      fi
      if [[ "$ev_count" -eq 0 ]]; then
        findings+=("missing evidence_commands for strict phase task: $chain_task_file")
      fi

      if (( ${#root_requirement_ids[@]} > 0 )) && [[ "$chain_phase" == "execute" || "$chain_phase" == "review" ]]; then
        local chain_result_body
        chain_result_body="$(extract_task_section "$chain_task_file" "Result")"

        for req_index in "${!root_requirement_ids[@]}"; do
          local requirement_id declared_in_task=0 task_requirement_id requirement_status
          requirement_id="${root_requirement_ids[$req_index]}"
          for task_requirement_id in "${chain_requirement_ids[@]}"; do
            if [[ "$task_requirement_id" == "$requirement_id" ]]; then
              declared_in_task=1
              break
            fi
          done

          if [[ "$declared_in_task" -eq 0 ]]; then
            continue
          fi

          requirement_status="$(extract_result_value_for_key "$chain_result_body" "$requirement_id" 'Met|Partial|Missing|Unverifiable')"
          if [[ -z "$requirement_status" ]]; then
            findings+=("missing requirement status in $chain_phase task for $requirement_id: $chain_task_file")
          fi

          if [[ "$chain_phase" == "execute" ]]; then
            requirement_execute_coverage[$req_index]="1"
          else
            requirement_review_coverage[$req_index]="1"
          fi
        done
      fi
    fi

    if task_has_benchmark_profile "$chain_task_file"; then
      if [[ "$chain_task_file" != "$task_file" ]]; then
        has_child_benchmark=1
      fi
      if ! benchmark_verify_task_file "$chain_task_file" >/dev/null; then
        findings+=("benchmark evidence contract failed: $chain_task_file")
      fi
    fi
  done

  if [[ "$root_has_benchmark" -eq 1 && "$has_child_benchmark" -eq 0 ]]; then
    findings+=("benchmark root has no benchmark-configured child tasks")
  fi
  if [[ "$has_execute" -eq 0 ]]; then
    findings+=("no execute-phase task found in chain")
  fi
  if [[ "$has_review" -eq 0 ]]; then
    findings+=("no review-phase task found in chain")
  fi
  if [[ "$has_closeout" -eq 0 ]]; then
    findings+=("no closeout-phase task found in chain")
  fi

  for req_index in "${!root_requirement_ids[@]}"; do
    local requirement_id
    requirement_id="${root_requirement_ids[$req_index]}"
    if [[ "${requirement_execute_coverage[$req_index]}" != "1" ]]; then
      findings+=("requirement $requirement_id has no execute-phase evidence coverage in chain")
    fi
    if [[ "${requirement_review_coverage[$req_index]}" != "1" ]]; then
      findings+=("requirement $requirement_id has no review-phase evidence coverage in chain")
    fi
  done

  if (( ${#findings[@]} > 0 )); then
    local finding
    for finding in "${findings[@]}"; do
      echo "benchmark-audit-chain finding: $finding"
    done
    return 1
  fi

  echo "benchmark-audit-chain passed: root_task_id=$root_task_id tasks_scanned=${#chain_files[@]}"
}

resolve_task_for_benchmark_commands() {
  local agent="$1"
  local task_id="$2"
  local in_progress_task="$ROOT/in_progress/$agent/${task_id}.md"
  if [[ -f "$in_progress_task" ]]; then
    verify_task_path_status_consistency "$in_progress_task" || return 1
    printf '%s' "$in_progress_task"
    return 0
  fi

  local existing
  existing="$(find_existing_task "$task_id")"
  if [[ -n "$existing" ]]; then
    verify_task_path_status_consistency "$existing" || return 1
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
  local benchmark_profile_value="none"
  local benchmark_workdir_value="."
  local scorecard_artifact_value="none"
  local benchmark_opt_out_reason_value="none"
  local -a gate_targets_value=()
  local parent_task_file=""
  local benchmark_parent_task_file=""
  local parent_has_benchmark=0
  local parent_benchmark_profile="none"
  local parent_benchmark_workdir="."
  local parent_scorecard_artifact="none"
  local parent_opt_out_reason="none"
  local -a parent_gate_targets=()
  local explicit_profile=0
  local explicit_workdir=0
  local explicit_scorecard=0
  local explicit_opt_out_reason=0
  local explicit_gate_targets=0

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

  if [[ -n "$parent_task_id" ]]; then
    require_task_id "$parent_task_id"
    parent_task_file="$(find_existing_task "$parent_task_id" || true)"
    if [[ -n "$parent_task_file" ]]; then
      if task_has_benchmark_profile "$parent_task_file"; then
        benchmark_parent_task_file="$parent_task_file"
      else
        benchmark_parent_task_file="$(task_nearest_benchmark_ancestor_file "$parent_task_file" 2>/dev/null || true)"
      fi

      if [[ -n "$benchmark_parent_task_file" ]]; then
        parent_has_benchmark=1
      fi

      if [[ "$parent_has_benchmark" -eq 1 ]]; then
        parent_benchmark_profile="$(task_yaml_scalar_value "$benchmark_parent_task_file" "benchmark_profile" 2>/dev/null || true)"
      fi
      parent_benchmark_profile="$(normalize_benchmark_scalar "$parent_benchmark_profile")"

      if [[ "$parent_has_benchmark" -eq 1 ]]; then
        parent_benchmark_workdir="$(task_yaml_scalar_value "$benchmark_parent_task_file" "benchmark_workdir" 2>/dev/null || true)"
      fi
      parent_benchmark_workdir="$(printf '%s' "$parent_benchmark_workdir" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"
      [[ -n "$parent_benchmark_workdir" ]] || parent_benchmark_workdir="."

      if [[ "$parent_has_benchmark" -eq 1 ]]; then
        parent_scorecard_artifact="$(task_yaml_scalar_value "$benchmark_parent_task_file" "scorecard_artifact" 2>/dev/null || true)"
      fi
      parent_scorecard_artifact="$(normalize_benchmark_scalar "$parent_scorecard_artifact")"

      if [[ "$parent_has_benchmark" -eq 1 ]]; then
        parent_opt_out_reason="$(task_yaml_scalar_value "$benchmark_parent_task_file" "benchmark_opt_out_reason" 2>/dev/null || true)"
      fi
      parent_opt_out_reason="$(printf '%s' "$parent_opt_out_reason" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"
      [[ -n "$parent_opt_out_reason" ]] || parent_opt_out_reason="none"

      if [[ "$parent_has_benchmark" -eq 1 ]]; then
        while IFS= read -r gate_target; do
          [[ -n "$gate_target" ]] || continue
          append_unique_array_value parent_gate_targets "$gate_target"
        done < <(task_yaml_array_values "$benchmark_parent_task_file" "gate_targets" 2>/dev/null || true)
      fi
    fi
  fi

  if [[ -n "$CREATE_BENCHMARK_PROFILE_OVERRIDE" ]]; then
    benchmark_profile_value="$(normalize_benchmark_scalar "$CREATE_BENCHMARK_PROFILE_OVERRIDE")"
    explicit_profile=1
  fi
  if [[ -n "$CREATE_BENCHMARK_WORKDIR_OVERRIDE" ]]; then
    benchmark_workdir_value="$(printf '%s' "$CREATE_BENCHMARK_WORKDIR_OVERRIDE" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"
    [[ -n "$benchmark_workdir_value" ]] || benchmark_workdir_value="."
    explicit_workdir=1
  fi
  if [[ -n "$CREATE_BENCHMARK_SCORECARD_OVERRIDE" ]]; then
    scorecard_artifact_value="$(normalize_benchmark_scalar "$CREATE_BENCHMARK_SCORECARD_OVERRIDE")"
    explicit_scorecard=1
  fi
  if [[ -n "$CREATE_BENCHMARK_OPT_OUT_REASON_OVERRIDE" ]]; then
    benchmark_opt_out_reason_value="$(printf '%s' "$CREATE_BENCHMARK_OPT_OUT_REASON_OVERRIDE" | sed -E "s/^'+|'+$//g; s/^[[:space:]]+//; s/[[:space:]]+$//")"
    if [[ -z "$benchmark_opt_out_reason_value" ]]; then
      benchmark_opt_out_reason_value="none"
    fi
    explicit_opt_out_reason=1
  fi
  if (( ${#CREATE_BENCHMARK_GATE_TARGET_OVERRIDES[@]} > 0 )); then
    gate_targets_value=()
    while IFS= read -r gate_target; do
      [[ -n "$gate_target" ]] || continue
      append_unique_array_value gate_targets_value "$gate_target"
    done < <(printf '%s\n' "${CREATE_BENCHMARK_GATE_TARGET_OVERRIDES[@]}")
    explicit_gate_targets=1
  fi

  if [[ "$CREATE_BENCHMARK_INHERIT_PARENT" -eq 1 && "$parent_has_benchmark" -eq 1 ]]; then
    if [[ "$explicit_profile" -eq 0 ]]; then
      benchmark_profile_value="$parent_benchmark_profile"
    fi
    if [[ "$explicit_workdir" -eq 0 ]]; then
      benchmark_workdir_value="$parent_benchmark_workdir"
    fi
    if [[ "$explicit_scorecard" -eq 0 ]]; then
      scorecard_artifact_value="$parent_scorecard_artifact"
    fi
    if [[ "$explicit_opt_out_reason" -eq 0 ]]; then
      benchmark_opt_out_reason_value="$parent_opt_out_reason"
    fi
    if [[ "$explicit_gate_targets" -eq 0 && ${#parent_gate_targets[@]} -gt 0 ]]; then
      gate_targets_value=("${parent_gate_targets[@]}")
    fi
  fi

  benchmark_profile_value="$(normalize_benchmark_scalar "$benchmark_profile_value")"
  scorecard_artifact_value="$(normalize_benchmark_scalar "$scorecard_artifact_value")"
  if [[ -z "$benchmark_opt_out_reason_value" || "$benchmark_opt_out_reason_value" == "null" ]]; then
    benchmark_opt_out_reason_value="none"
  fi

  if [[ "$benchmark_profile_value" != "none" ]]; then
    local profile_path
    profile_path="$(resolve_benchmark_profile_path_from_value "$benchmark_profile_value")" || exit 1

    if (( ${#gate_targets_value[@]} == 0 )); then
      while IFS= read -r gate_target; do
        [[ -n "$gate_target" ]] || continue
        append_unique_array_value gate_targets_value "$gate_target"
      done < <(benchmark_gate_targets_for_profile "$profile_path")
    fi

    if [[ "$scorecard_artifact_value" == "none" ]]; then
      scorecard_artifact_value="$(default_scorecard_artifact_for_task "$owner" "$task_id")"
    fi
    if [[ -z "$benchmark_workdir_value" || "$benchmark_workdir_value" == "none" ]]; then
      benchmark_workdir_value="."
    fi
  else
    benchmark_workdir_value="."
    gate_targets_value=()
    scorecard_artifact_value="none"
  fi

  case "$phase" in
    execute|review|closeout)
      if [[ "$parent_has_benchmark" -eq 1 && "$benchmark_profile_value" == "none" && "$benchmark_opt_out_reason_value" == "none" ]]; then
        echo "benchmark metadata required for benchmark-parent strict phases (phase=$phase parent_task_id=$parent_task_id); set --benchmark-profile or pass --benchmark-opt-out-reason" >&2
        exit 1
      fi
      ;;
  esac

  if [[ "$benchmark_profile_value" != "none" && "$benchmark_opt_out_reason_value" != "none" ]]; then
    echo "benchmark_opt_out_reason cannot be set when benchmark_profile is active (task_id=$task_id)" >&2
    exit 1
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
  grep -qE '^benchmark_workdir:' "$out" || set_field "$out" "benchmark_workdir" "."
  grep -qE '^gate_targets:' "$out" || set_field "$out" "gate_targets" "[]"
  grep -qE '^scorecard_artifact:' "$out" || set_field "$out" "scorecard_artifact" "none"
  grep -qE '^benchmark_opt_out_reason:' "$out" || set_field "$out" "benchmark_opt_out_reason" "none"
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

  if [[ "$benchmark_profile_value" == "none" ]]; then
    set_field "$out" "benchmark_profile" "none"
  else
    set_field "$out" "benchmark_profile" "$(yaml_quote_single "$benchmark_profile_value")"
  fi
  set_field "$out" "benchmark_workdir" "$(yaml_quote_single "$benchmark_workdir_value")"
  set_field "$out" "gate_targets" "$(yaml_inline_list "${gate_targets_value[@]}")"
  if [[ "$scorecard_artifact_value" == "none" ]]; then
    set_field "$out" "scorecard_artifact" "none"
  else
    set_field "$out" "scorecard_artifact" "$(yaml_quote_single "$scorecard_artifact_value")"
  fi
  if [[ "$benchmark_opt_out_reason_value" == "none" ]]; then
    set_field "$out" "benchmark_opt_out_reason" "none"
  else
    set_field "$out" "benchmark_opt_out_reason" "$(yaml_quote_single "$benchmark_opt_out_reason_value")"
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
  verify_task_path_status_consistency "$src" || exit 1

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
      reset_create_benchmark_overrides
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
          --benchmark-profile)
            CREATE_BENCHMARK_PROFILE_OVERRIDE="${2:-}"
            shift 2
            ;;
          --benchmark-workdir)
            CREATE_BENCHMARK_WORKDIR_OVERRIDE="${2:-}"
            shift 2
            ;;
          --gate-target)
            append_unique_create_gate_target_override "${2:-}"
            shift 2
            ;;
          --scorecard-artifact)
            CREATE_BENCHMARK_SCORECARD_OVERRIDE="${2:-}"
            shift 2
            ;;
          --benchmark-opt-out-reason)
            CREATE_BENCHMARK_OPT_OUT_REASON_OVERRIDE="${2:-}"
            shift 2
            ;;
          --no-benchmark-inherit)
            CREATE_BENCHMARK_INHERIT_PARENT=0
            shift
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
      reset_create_benchmark_overrides
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
          --benchmark-profile)
            CREATE_BENCHMARK_PROFILE_OVERRIDE="${2:-}"
            shift 2
            ;;
          --benchmark-workdir)
            CREATE_BENCHMARK_WORKDIR_OVERRIDE="${2:-}"
            shift 2
            ;;
          --gate-target)
            append_unique_create_gate_target_override "${2:-}"
            shift 2
            ;;
          --scorecard-artifact)
            CREATE_BENCHMARK_SCORECARD_OVERRIDE="${2:-}"
            shift 2
            ;;
          --benchmark-opt-out-reason)
            CREATE_BENCHMARK_OPT_OUT_REASON_OVERRIDE="${2:-}"
            shift 2
            ;;
          --no-benchmark-inherit)
            CREATE_BENCHMARK_INHERIT_PARENT=0
            shift
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
    benchmark-init)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      local benchmark_task_file
      benchmark_task_file="$(resolve_task_for_benchmark_commands "$2" "$3")" || exit 1
      benchmark_init_task_file "$benchmark_task_file"
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
    benchmark-rerun)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      local benchmark_task_file
      benchmark_task_file="$(resolve_task_for_benchmark_commands "$2" "$3")" || exit 1
      benchmark_rerun_task_file "$benchmark_task_file" "$2"
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
      benchmark_closeout_check_task_file "$benchmark_task_file" "$2"
      ;;
    benchmark-audit-chain)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      local benchmark_task_file
      benchmark_task_file="$(resolve_task_for_benchmark_commands "$2" "$3")" || exit 1
      benchmark_audit_chain_task_file "$benchmark_task_file"
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
