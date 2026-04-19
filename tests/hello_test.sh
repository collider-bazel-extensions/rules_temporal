#!/usr/bin/env bash
# hello_test.sh
#
# Smoke test for rules_temporal.
# Verifies that HelloWorkflow, EchoWorkflow, and MathWorkflow execute
# end-to-end via an ephemeral Temporal cluster.

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
# Helper: extract 'result' field from temporal workflow execute JSON output
# -------------------------------------------------------------------------

extract_result() {
    local json="$1"
    python3 -c "
import sys, json
text = '''$json'''
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
" 2>/dev/null || echo ""
}

# -------------------------------------------------------------------------
# Test 1: HelloWorkflow
# -------------------------------------------------------------------------

RESULT_JSON=$("$TEMPORAL_BIN" workflow execute \
    --address    "$TEMPORAL_ADDRESS" \
    --namespace  "$TEMPORAL_NAMESPACE" \
    --type       HelloWorkflow \
    --task-queue "$TEMPORAL_TASK_QUEUE" \
    --input      '"World"' \
    -o json 2>&1) || {
    echo "FAIL: HelloWorkflow execute returned non-zero" >&2
    echo "$RESULT_JSON" >&2
    exit 1
}

echo "HelloWorkflow raw result: $RESULT_JSON"
RESULT_VAL=$(extract_result "$RESULT_JSON")
EXPECTED='"Hello, World!"'
if [[ "$RESULT_VAL" == "$EXPECTED" ]]; then
    echo "OK: HelloWorkflow returned $RESULT_VAL"
else
    echo "FAIL: HelloWorkflow: expected $EXPECTED, got '$RESULT_VAL'" >&2
    exit 1
fi

# -------------------------------------------------------------------------
# Test 2: EchoWorkflow — returns input unchanged
# -------------------------------------------------------------------------

ECHO_JSON=$("$TEMPORAL_BIN" workflow execute \
    --address    "$TEMPORAL_ADDRESS" \
    --namespace  "$TEMPORAL_NAMESPACE" \
    --type       EchoWorkflow \
    --task-queue "$TEMPORAL_TASK_QUEUE" \
    --input      '"ping"' \
    -o json 2>&1) || {
    echo "FAIL: EchoWorkflow execute returned non-zero" >&2
    echo "$ECHO_JSON" >&2
    exit 1
}

echo "EchoWorkflow raw result: $ECHO_JSON"
ECHO_VAL=$(extract_result "$ECHO_JSON")
EXPECTED_ECHO='"ping"'
if [[ "$ECHO_VAL" == "$EXPECTED_ECHO" ]]; then
    echo "OK: EchoWorkflow returned $ECHO_VAL"
else
    echo "FAIL: EchoWorkflow: expected $EXPECTED_ECHO, got '$ECHO_VAL'" >&2
    exit 1
fi

# -------------------------------------------------------------------------
# Test 3: MathWorkflow — add and multiply two numbers
# -------------------------------------------------------------------------

MATH_JSON=$("$TEMPORAL_BIN" workflow execute \
    --address    "$TEMPORAL_ADDRESS" \
    --namespace  "$TEMPORAL_NAMESPACE" \
    --type       MathWorkflow \
    --task-queue "$TEMPORAL_TASK_QUEUE" \
    --input      '3' \
    --input      '4' \
    -o json 2>&1) || {
    echo "FAIL: MathWorkflow execute returned non-zero" >&2
    echo "$MATH_JSON" >&2
    exit 1
}

echo "MathWorkflow raw result: $MATH_JSON"
MATH_VAL=$(extract_result "$MATH_JSON")
# Accept either field ordering.
MATH_OK=$(python3 -c "
import sys, json
val = json.loads('$MATH_VAL')
ok = isinstance(val, dict) and val.get('sum') == 7 and val.get('product') == 12
print('yes' if ok else 'no')
" 2>/dev/null || echo "no")

if [[ "$MATH_OK" == "yes" ]]; then
    echo "OK: MathWorkflow returned $MATH_VAL"
else
    echo "FAIL: MathWorkflow: expected {\"sum\":7,\"product\":12}, got '$MATH_VAL'" >&2
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
