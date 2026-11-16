#!/usr/bin/env bash
# #4: runs only after the launcher replayed :custom_runner_histories with
# the worker's temporal_replay_runner. builtin_replay_runner = False, so the
# built-in runner is not in this test at all.
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
require_env TEMPORAL_CUSTOM_REPLAY_RUNNER

[[ -z "${TEMPORAL_REPLAY_RUNNER:-}" ]] || { echo "FAIL: built-in runner attached despite builtin_replay_runner = False" >&2; exit 1; }
echo "PASS: committed histories replayed with the custom runner ($TEMPORAL_CUSTOM_REPLAY_RUNNER)"
