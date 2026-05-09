#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
HEALTH_BIN="${RUNFILES_DIR}/_main/tests/install_smoke/cert_manager_install_health_bin.sh"
[[ -x "$HEALTH_BIN" ]] || { echo "wrapper: cert_manager_install_health_bin not at $HEALTH_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || exit 1

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

exec "$HEALTH_BIN"
