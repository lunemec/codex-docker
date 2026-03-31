#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"

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

canonical_path() {
  local path="$1"

  if [[ -d "${path}" ]]; then
    (
      cd "${path}" >/dev/null 2>&1
      pwd -P
    )
    return 0
  fi

  if command -v realpath >/dev/null 2>&1; then
    if realpath -m / >/dev/null 2>&1; then
      realpath -m "${path}"
    else
      realpath "${path}"
    fi
    return 0
  fi

  printf '%s\n' "${path}"
}

write_fake_docker() {
  local path="$1"

  cat >"${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG:?}"

case "${1:-}" in
  info|run)
    exit 0
    ;;
esac

printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 1
EOF
}

run_toolbelt_case() {
  local scenario="$1"
  local kimaki_mode="$2"
  shift 2

  local scenario_root="${TMP_ROOT}/${scenario}"
  local fakebin="${scenario_root}/bin"
  local workdir="${scenario_root}/cwd"
  local home_dir="${scenario_root}/home"
  local stdout_path="${scenario_root}/stdout.log"
  local stderr_path="${scenario_root}/stderr.log"
  local kimaki_src_override=""

  mkdir -p "${fakebin}" "${workdir}" "${home_dir}"
  mkdir -p "${home_dir}/.config/opencode"

  case "${kimaki_mode}" in
    default)
      mkdir -p "${home_dir}/.kimaki"
      ;;
    override)
      mkdir -p "${home_dir}/.kimaki"
      kimaki_src_override="${scenario_root}/kimaki-custom"
      mkdir -p "${kimaki_src_override}"
      ;;
    missing)
      ;;
    *)
      fail "unknown kimaki mode: ${kimaki_mode}"
      ;;
  esac

  write_fake_docker "${fakebin}/docker"
  chmod +x "${fakebin}/docker"

  set +e
  (
    cd "${workdir}"
    export PATH="${fakebin}:${PATH}"
    export HOME="${home_dir}"
    export FAKE_DOCKER_LOG="${scenario_root}/docker.log"
    if [[ -n "${kimaki_src_override}" ]]; then
      export CODEX_KIMAKI_CONFIG_SRC="${kimaki_src_override}"
    fi
    bash "${REPO_ROOT}/scripts/toolbelt.sh" "$@" >"${stdout_path}" 2>"${stderr_path}"
  )
  CASE_STATUS=$?
  set -e

  CASE_STDOUT="$(cat "${stdout_path}")"
  CASE_STDERR="$(cat "${stderr_path}")"
  if [[ -f "${scenario_root}/docker.log" ]]; then
    CASE_DOCKER_LOG="$(cat "${scenario_root}/docker.log")"
  else
    CASE_DOCKER_LOG=""
  fi
}

trap cleanup EXIT

run_toolbelt_case default-mount default -kimaki
[[ "${CASE_STATUS}" -eq 0 ]] || fail "default-mount should succeed"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/default-mount/cwd"):/workspace" "default workspace mount"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/default-mount/home/.config/opencode"):/run/secrets/opencode-config:ro" "default implied opencode mount"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/default-mount/home/.kimaki"):/root/.kimaki" "default kimaki mount"
assert_not_contains "${CASE_DOCKER_LOG}" "$(canonical_path "${TMP_ROOT}/default-mount/home/.kimaki"):/root/.kimaki:ro" "default kimaki mount mode"
assert_not_contains "${CASE_DOCKER_LOG}" "/root/.config/opencode" "default should not bind host opencode home directly"

run_toolbelt_case env-override override -kimaki
[[ "${CASE_STATUS}" -eq 0 ]] || fail "env-override should succeed"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/env-override/home/.config/opencode"):/run/secrets/opencode-config:ro" "override implied opencode mount"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/env-override/kimaki-custom"):/root/.kimaki" "override kimaki mount"
assert_not_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/env-override/home/.kimaki"):/root/.kimaki" "override should replace default kimaki source"

run_toolbelt_case missing-source missing -kimaki
[[ "${CASE_STATUS}" -ne 0 ]] || fail "missing-source should fail"
assert_contains "${CASE_STDERR}" "requested -kimaki/--kimaki but Kimaki data directory is not available:" "missing-source stderr"
assert_not_contains "${CASE_DOCKER_LOG}" "run" "missing-source docker launch"

printf 'verify_toolbelt_kimaki_contract: ok\n'
