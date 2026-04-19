#!/usr/bin/env bash
# temporal_server_test.sh
#
# Verifies temporal_server lifecycle:
#   - starts the server and writes the env file
#   - env file contains TEMPORAL_ADDRESS and TEMPORAL_NAMESPACE
#   - server is actually reachable via gRPC health check
#   - SIGTERM causes a clean (exit 0) shutdown
#
# $1: rootpath of the temporal_server binary (relative to TEST_SRCDIR)

set -euo pipefail

SERVER_BIN="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
# Env file name is derived from the temporal_server target name.
ENV_FILE="$TEST_TMPDIR/temporal_server_test_svc.env"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "--- temporal_server_test ---"

# Start the server in the background.  It inherits TEST_SRCDIR and TEST_TMPDIR
# from this test process, which is what the wrapper script needs.
"$SERVER_BIN" &
SERVER_PID=$!

# Wait up to 30 s for the env file to appear.  temporal_server writes it only
# after the dev server is up and the namespace has been created.
echo "Waiting for env file: $ENV_FILE"
for i in $(seq 1 150); do
    [[ -f "$ENV_FILE" ]] && break
    sleep 0.2
done
if [[ ! -f "$ENV_FILE" ]]; then
    echo "FAIL: env file never appeared after 30 s" >&2
    exit 1
fi
echo "OK: env file appeared"

# Verify env file has all required variables.
# shellcheck disable=SC1090
source "$ENV_FILE"
for var in TEMPORAL_ADDRESS TEMPORAL_NAMESPACE; do
    if [[ -z "${!var:-}" ]]; then
        echo "FAIL: $var is missing from env file" >&2
        exit 1
    fi
    echo "OK: $var=${!var}"
done

# Locate the Temporal CLI for the gRPC health check.
TEMPORAL_BIN="$(command -v temporal 2>/dev/null || true)"
if [[ -z "$TEMPORAL_BIN" ]]; then
    RUNFILES_ROOT="${TEST_SRCDIR:-${RUNFILES_DIR:-}}"
    for candidate in \
        "$RUNFILES_ROOT/temporal_1_6_2_linux_amd64/bin/temporal" \
        "$RUNFILES_ROOT/temporal_1_6_2_darwin_arm64/bin/temporal" \
        "$RUNFILES_ROOT/temporal_1_6_2_darwin_amd64/bin/temporal"; do
        if [[ -x "$candidate" ]]; then
            TEMPORAL_BIN="$candidate"
            break
        fi
    done
fi

if [[ -n "$TEMPORAL_BIN" ]]; then
    # Set HOME so the temporal CLI can locate its config directory inside
    # the Bazel sandbox (which does not inherit the user's HOME).
    HOME="${TEST_TMPDIR:-/tmp}" \
    "$TEMPORAL_BIN" operator cluster health \
        --address "$TEMPORAL_ADDRESS" -o json >/dev/null
    echo "OK: gRPC health check passed"
else
    echo "SKIP: temporal binary not found for gRPC health check"
fi

# Send SIGTERM and wait for temporal_server to stop cleanly.
kill -TERM "$SERVER_PID"
set +e
wait "$SERVER_PID"
EXIT_CODE=$?
set -e
SERVER_PID=""  # prevent double-kill in trap

if [[ "$EXIT_CODE" != "0" ]]; then
    echo "FAIL: temporal_server exited with code $EXIT_CODE after SIGTERM (expected 0)" >&2
    exit 1
fi
echo "OK: temporal_server exited cleanly (exit 0) after SIGTERM"

echo "--- PASS ---"
