#!/usr/bin/env bash
# hello_test.sh
#
# Smoke test for rules_temporal.
# Verifies that HelloWorkflow executes end-to-end via an ephemeral Temporal cluster.

set -euo pipefail

require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: required environment variable \$${var} is not set" >&2
        echo "       This script must be run via 'bazel test', not directly." >&2
        exit 1
    fi
}
require_env TEMPORAL_ADDRESS
require_env TEMPORAL_NAMESPACE
require_env TEMPORAL_TASK_QUEUE

TEMPORAL_BIN="$(command -v temporal 2>/dev/null || true)"
if [[ -z "$TEMPORAL_BIN" ]]; then
    # Check runfiles for the temporal binary.
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

if [[ -z "$TEMPORAL_BIN" ]]; then
    echo "ERROR: temporal binary not found in PATH or runfiles" >&2
    exit 1
fi

echo "--- hello_test ---"
echo "Server:     $TEMPORAL_ADDRESS"
echo "Namespace:  $TEMPORAL_NAMESPACE"
echo "Task queue: $TEMPORAL_TASK_QUEUE"
echo "Temporal:   $TEMPORAL_BIN"

# -------------------------------------------------------------------------
# Run HelloWorkflow and wait for result
# -------------------------------------------------------------------------

RESULT_JSON=$("$TEMPORAL_BIN" workflow execute \
    --address    "$TEMPORAL_ADDRESS" \
    --namespace  "$TEMPORAL_NAMESPACE" \
    --type       HelloWorkflow \
    --task-queue "$TEMPORAL_TASK_QUEUE" \
    --input      '"World"' \
    -o json 2>&1) || {
    echo "FAIL: workflow execute returned non-zero" >&2
    echo "$RESULT_JSON" >&2
    exit 1
}

echo "Raw result: $RESULT_JSON"

# Extract the result value.
RESULT_VAL=$(echo "$RESULT_JSON" | \
    python3 -c "
import sys, json
text = sys.stdin.read()
# Try whole-input parse first (pretty-printed JSON), then line-by-line (NDJSON).
try:
    obj = json.loads(text)
    if 'result' in obj:
        print(json.dumps(obj['result']))
        sys.exit(0)
except json.JSONDecodeError:
    pass
for line in text.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if 'result' in obj:
            print(json.dumps(obj['result']))
            sys.exit(0)
    except json.JSONDecodeError:
        pass
" 2>/dev/null || echo "")

EXPECTED='"Hello, World!"'
if [[ "$RESULT_VAL" == "$EXPECTED" ]]; then
    echo "OK: HelloWorkflow returned $RESULT_VAL"
else
    echo "FAIL: expected $EXPECTED, got '$RESULT_VAL'" >&2
    exit 1
fi

# -------------------------------------------------------------------------
# Verify namespace isolation — namespace should exist and be accessible
# -------------------------------------------------------------------------

NS_JSON=$("$TEMPORAL_BIN" operator namespace describe \
    --address "$TEMPORAL_ADDRESS" -o json 2>&1 || true)
NS_NAME=$(echo "$NS_JSON" | python3 -c "
import sys, json
text = sys.stdin.read()
def extract(obj):
    ns = obj.get('namespaceInfo', {}).get('name', '')
    if ns:
        print(ns)
        sys.exit(0)
try:
    extract(json.loads(text))
except json.JSONDecodeError:
    pass
for line in text.splitlines():
    line = line.strip()
    if not line: continue
    try:
        extract(json.loads(line))
    except: pass
" 2>/dev/null || echo "")

if [[ "$NS_NAME" == "$TEMPORAL_NAMESPACE" ]]; then
    echo "OK: namespace $TEMPORAL_NAMESPACE is isolated and accessible"
else
    echo "FAIL: namespace describe returned unexpected name: '$NS_NAME'" >&2
    exit 1
fi

echo "--- PASS ---"
