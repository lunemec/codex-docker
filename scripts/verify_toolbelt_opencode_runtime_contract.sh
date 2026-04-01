#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
HARNESS_PATH="${TMP_ROOT}/bootstrap-opencode-harness.sh"

cleanup() {
  rm -rf "${TMP_ROOT}"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"

  [[ "${haystack}" == *"${needle}"* ]] || fail "${context}: missing '${needle}'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"

  [[ "${haystack}" != *"${needle}"* ]] || fail "${context}: unexpectedly found '${needle}'"
}

write_entrypoint_harness() {
  local path="$1"

  cat >"${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source <(sed '/^case "${TOOLBELT_PROVIDER}" in/,$d' "${REPO_ROOT}/container/toolbelt-entrypoint.sh")
bootstrap_opencode_home
EOF

  chmod +x "${path}"
}

write_default_opencode_config() {
  local path="$1"

  cat >"${path}" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "context-mode": {
      "type": "local",
      "command": ["context-mode"]
    }
  },
  "plugin": ["context-mode"]
}
EOF
}

run_bootstrap_case() {
  local scenario="$1"
  shift

  local scenario_root="${TMP_ROOT}/${scenario}"
  local opencode_home="${scenario_root}/home/.config/opencode"
  local opencode_src="${scenario_root}/secrets/opencode"
  local stdout_path="${scenario_root}/stdout.log"
  local stderr_path="${scenario_root}/stderr.log"

  mkdir -p "${opencode_home}" "${opencode_src}"
  write_default_opencode_config "${opencode_home}/opencode.json"

  CASE_ROOT="${scenario_root}"
  CASE_OPENCODE_HOME="${opencode_home}"
  CASE_OPENCODE_SRC="${opencode_src}"

  "$@"

  set +e
  REPO_ROOT="${REPO_ROOT}" TOOLBELT_WITH_OPENCODE=1 OPENCODE_HOME="${opencode_home}" OPENCODE_CONFIG_SRC="${opencode_src}" \
    bash "${HARNESS_PATH}" >"${stdout_path}" 2>"${stderr_path}"
  CASE_STATUS=$?
  set -e

  CASE_STDOUT="$(cat "${stdout_path}")"
  CASE_STDERR="$(cat "${stderr_path}")"
}

assert_json_check() {
  local json_path="$1"
  local context="$2"
  local program="$3"

  python3 - "${json_path}" "${context}" "${program}" <<'PY'
import json
import sys

path = sys.argv[1]
context = sys.argv[2]
program = sys.argv[3]

with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

namespace = {"data": data}
if not eval(program, {"__builtins__": {}}, namespace):
    raise SystemExit(f"FAIL: {context}")
PY
}

setup_merge_case() {
  mkdir -p "${CASE_OPENCODE_SRC}/providers"
  cat >"${CASE_OPENCODE_SRC}/providers/authorized.json" <<'EOF'
{"openai":"host-token"}
EOF
  cat >"${CASE_OPENCODE_SRC}/opencode.json" <<'EOF'
{
  "plugin": ["host-plugin"],
  "mcp": {
    "host-service": {
      "type": "local",
      "command": ["host-service"]
    }
  },
  "provider": {
    "openai": {
      "apiKey": "host-key"
    }
  }
}
EOF
}

setup_missing_json_case() {
  mkdir -p "${CASE_OPENCODE_SRC}/providers"
  cat >"${CASE_OPENCODE_SRC}/providers/authorized.json" <<'EOF'
{"anthropic":"host-token"}
EOF
}

setup_invalid_json_case() {
  cat >"${CASE_OPENCODE_SRC}/opencode.json" <<'EOF'
{"plugin":
EOF
}

setup_preserve_context_mode_case() {
  cat >"${CASE_OPENCODE_SRC}/opencode.json" <<'EOF'
{
  "plugin": ["context-mode", "host-plugin"],
  "mcp": {
    "context-mode": {
      "type": "local",
      "command": ["custom-context-mode"]
    }
  }
}
EOF
}

trap cleanup EXIT

write_entrypoint_harness "${HARNESS_PATH}"

run_bootstrap_case merge-host-config setup_merge_case
[[ "${CASE_STATUS}" -eq 0 ]] || fail "merge-host-config should succeed"
assert_contains "$(cat "${CASE_OPENCODE_HOME}/providers/authorized.json")" '"openai":"host-token"' "merge-host-config copied provider file"
assert_json_check "${CASE_OPENCODE_HOME}/opencode.json" "merge-host-config should preserve host settings" '"host-plugin" in data.get("plugin", []) and data.get("provider", {}).get("openai", {}).get("apiKey") == "host-key" and "host-service" in data.get("mcp", {})'
assert_json_check "${CASE_OPENCODE_HOME}/opencode.json" "merge-host-config should add context-mode defaults" '"context-mode" in data.get("plugin", []) and data.get("mcp", {}).get("context-mode", {}).get("command") == ["context-mode"]'

run_bootstrap_case missing-host-json setup_missing_json_case
[[ "${CASE_STATUS}" -eq 0 ]] || fail "missing-host-json should succeed"
assert_contains "$(cat "${CASE_OPENCODE_HOME}/providers/authorized.json")" '"anthropic":"host-token"' "missing-host-json copied provider file"
assert_json_check "${CASE_OPENCODE_HOME}/opencode.json" "missing-host-json should keep default config" 'data.get("plugin") == ["context-mode"] and data.get("mcp", {}).get("context-mode", {}).get("command") == ["context-mode"]'

run_bootstrap_case invalid-host-json setup_invalid_json_case
[[ "${CASE_STATUS}" -eq 0 ]] || fail "invalid-host-json should succeed"
assert_contains "${CASE_STDERR}" "runtime OpenCode config" "invalid-host-json warning"
assert_contains "$(cat "${CASE_OPENCODE_HOME}/opencode.json")" '{"plugin":' "invalid-host-json should preserve invalid runtime config"

run_bootstrap_case preserve-host-context-mode setup_preserve_context_mode_case
[[ "${CASE_STATUS}" -eq 0 ]] || fail "preserve-host-context-mode should succeed"
assert_not_contains "${CASE_STDERR}" "failed to merge OpenCode runtime defaults" "preserve-host-context-mode stderr"
assert_json_check "${CASE_OPENCODE_HOME}/opencode.json" "preserve-host-context-mode should keep host definition" 'data.get("mcp", {}).get("context-mode", {}).get("command") == ["custom-context-mode"]'
assert_json_check "${CASE_OPENCODE_HOME}/opencode.json" "preserve-host-context-mode should not duplicate plugin" 'data.get("plugin", []).count("context-mode") == 1'

printf 'verify_toolbelt_opencode_runtime_contract: ok\n'
