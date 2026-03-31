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
  local opencode_mode="$2"
  local kimaki_mode="$3"
  shift 3

  local scenario_root="${TMP_ROOT}/${scenario}"
  local fakebin="${scenario_root}/bin"
  local workdir="${scenario_root}/cwd"
  local home_dir="${scenario_root}/home"
  local stdout_path="${scenario_root}/stdout.log"
  local stderr_path="${scenario_root}/stderr.log"
  local opencode_src_override=""

  mkdir -p "${fakebin}" "${workdir}" "${home_dir}" "${home_dir}/.config"

  case "${opencode_mode}" in
    default)
      mkdir -p "${home_dir}/.config/opencode"
      ;;
    override)
      mkdir -p "${home_dir}/.config/opencode"
      opencode_src_override="${scenario_root}/opencode-custom"
      mkdir -p "${opencode_src_override}"
      ;;
    missing)
      ;;
    *)
      fail "unknown opencode mode: ${opencode_mode}"
      ;;
  esac

  case "${kimaki_mode}" in
    present)
      mkdir -p "${home_dir}/.kimaki"
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
    if [[ -n "${opencode_src_override}" ]]; then
      export CODEX_OPENCODE_CONFIG_SRC="${opencode_src_override}"
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

run_toolbelt_case auto-default default missing
[[ "${CASE_STATUS}" -eq 0 ]] || fail "auto-default should succeed"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/auto-default/cwd"):/workspace" "default workspace mount"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/auto-default/home/.config/opencode"):/run/secrets/opencode-config:ro" "default auto opencode mount"
assert_not_contains "${CASE_DOCKER_LOG}" "/root/.config/opencode" "default should not bind host opencode home directly"

run_toolbelt_case auto-env-override override missing
[[ "${CASE_STATUS}" -eq 0 ]] || fail "auto-env-override should succeed"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/auto-env-override/opencode-custom"):/run/secrets/opencode-config:ro" "override auto opencode mount"
assert_not_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/auto-env-override/home/.config/opencode"):/run/secrets/opencode-config:ro" "override should replace default opencode source"

run_toolbelt_case auto-missing missing missing
[[ "${CASE_STATUS}" -eq 0 ]] || fail "auto-missing should succeed"
assert_not_contains "${CASE_DOCKER_LOG}" "/run/secrets/opencode-config" "auto-missing should skip opencode mount"

run_toolbelt_case explicit-default default missing -opencode
[[ "${CASE_STATUS}" -eq 0 ]] || fail "explicit-default should succeed"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/explicit-default/home/.config/opencode"):/run/secrets/opencode-config:ro" "explicit opencode mount"

run_toolbelt_case missing-source missing missing -opencode
[[ "${CASE_STATUS}" -ne 0 ]] || fail "missing-source should fail"
assert_contains "${CASE_STDERR}" "requested -opencode/--opencode but OpenCode config directory is not available:" "missing-source stderr"
assert_not_contains "${CASE_DOCKER_LOG}" "run" "missing-source docker launch"

run_toolbelt_case kimaki-implies default present -kimaki
[[ "${CASE_STATUS}" -eq 0 ]] || fail "kimaki-implies should succeed"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/kimaki-implies/home/.config/opencode"):/run/secrets/opencode-config:ro" "kimaki implied opencode mount"
assert_contains "${CASE_DOCKER_LOG}" "-v $(canonical_path "${TMP_ROOT}/kimaki-implies/home/.kimaki"):/root/.kimaki" "kimaki mount"

run_toolbelt_case kimaki-missing-opencode missing present -kimaki
[[ "${CASE_STATUS}" -ne 0 ]] || fail "kimaki-missing-opencode should fail"
assert_contains "${CASE_STDERR}" "requested -opencode/--opencode (implicitly via -kimaki/--kimaki) but OpenCode config directory is not available:" "kimaki missing opencode stderr"
assert_not_contains "${CASE_DOCKER_LOG}" "run" "kimaki missing opencode docker launch"

printf 'verify_toolbelt_opencode_contract: ok\n'
