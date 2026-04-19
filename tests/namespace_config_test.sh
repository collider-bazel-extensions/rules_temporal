#!/usr/bin/env bash
# namespace_config_test.sh
#
# Verifies that temporal_namespace_config registers custom search attributes
# in the namespace before the test binary runs.
#
# The temporal_test target that wraps this script is configured with:
#   namespace_config = ":test_namespace_config"
# which declares:
#   TestCustomerId → Keyword
#   TestOrderTotal → Double

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

# Locate the Temporal CLI binary.
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
if [[ -z "$TEMPORAL_BIN" ]]; then
    echo "ERROR: temporal binary not found in PATH or runfiles" >&2
    exit 1
fi

echo "--- namespace_config_test ---"
echo "Server:    $TEMPORAL_ADDRESS"
echo "Namespace: $TEMPORAL_NAMESPACE"

# -------------------------------------------------------------------------
# Verify search attributes were registered at server startup.
#
# In Temporal server 1.24+, custom search attributes are registered via
# 'temporal server start-dev --search-attribute Name=Type' (not via
# 'temporal operator search-attribute create').  The launcher passes these
# flags automatically when namespace_config is provided.
#
# Verification: start a workflow with the custom attribute set.
# The server rejects the attribute for unregistered names, so a successful
# execute proves registration worked.
# -------------------------------------------------------------------------

EXEC_OUT=$("$TEMPORAL_BIN" workflow execute \
    --address          "$TEMPORAL_ADDRESS" \
    --namespace        "$TEMPORAL_NAMESPACE" \
    --type             HelloWorkflow \
    --task-queue       "$TEMPORAL_TASK_QUEUE" \
    --input            '"NSConfigTest"' \
    --search-attribute 'TestCustomerId="customer-001"' \
    --search-attribute 'TestOrderTotal=99.99' \
    -o json 2>&1) || {
    echo "FAIL: workflow with custom search attributes returned non-zero" >&2
    echo "$EXEC_OUT" >&2
    exit 1
}
echo "OK: workflow started successfully with TestCustomerId and TestOrderTotal set"

# Confirm the workflow produced the expected result.
RESULT_VAL=$(echo "$EXEC_OUT" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    obj = json.loads(text)
    if 'result' in obj:
        print(json.dumps(obj['result']))
        sys.exit(0)
except json.JSONDecodeError:
    pass
for line in text.splitlines():
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if 'result' in obj:
            print(json.dumps(obj['result']))
            sys.exit(0)
    except json.JSONDecodeError: pass
" 2>/dev/null || echo "")
if [[ "$RESULT_VAL" == '"Hello, NSConfigTest!"' ]]; then
    echo "OK: HelloWorkflow returned expected result"
else
    echo "FAIL: unexpected result: '$RESULT_VAL'" >&2
    exit 1
fi

echo "--- PASS ---"
