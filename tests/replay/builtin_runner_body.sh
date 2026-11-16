#!/usr/bin/env bash
# #4: runs only after the launcher replayed :hello_histories with the
# built-in runner. Checks the runner it exposes is the hermetic executable.
set -euo pipefail

require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: required environment variable \$${var} is not set" >&2
        exit 1
    fi
}
require_env TEMPORAL_ADDRESS
require_env TEMPORAL_NAMESPACE
require_env TEMPORAL_TASK_QUEUE
require_env TEMPORAL_REPLAY_RUNNER

[[ -x "$TEMPORAL_REPLAY_RUNNER" ]] || { echo "FAIL: $TEMPORAL_REPLAY_RUNNER is not executable" >&2; exit 1; }
[[ -z "${TEMPORAL_CUSTOM_REPLAY_RUNNER:-}" ]] || { echo "FAIL: unexpected custom runner" >&2; exit 1; }
echo "PASS: committed histories replayed with the built-in runner ($TEMPORAL_REPLAY_RUNNER)"
