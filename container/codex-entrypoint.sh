#!/usr/bin/env bash
set -euo pipefail

if [[ "${CODEX_BOOTSTRAP_WORKSPACE:-1}" == "1" ]]; then
  /usr/local/bin/codex-init-workspace --workspace /workspace --quiet || {
    echo "workspace bootstrap failed" >&2
    exit 1
  }
fi

exec "$@"
