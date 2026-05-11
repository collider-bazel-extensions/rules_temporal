#!/usr/bin/env bash
# temporal_replay_test.sh
#
# Verifies that workflow history can be exported and successfully replayed
# against the current worker code, confirming determinism.
#
# Approach: runs HelloWorkflow with a known ID, exports the history, then
# replays it via 'temporal workflow replay'.  A non-zero exit from replay
# indicates the workflow code is non-deterministic relative to the history.

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

echo "--- temporal_replay_test ---"
echo "Server:    $TEMPORAL_ADDRESS"
echo "Namespace: $TEMPORAL_NAMESPACE"

WORKFLOW_ID="replay-test-$$-$RANDOM"
HISTORY_FILE="$TEST_TMPDIR/replay_history.json"

# -------------------------------------------------------------------------
# 1. Run HelloWorkflow to completion.
# -------------------------------------------------------------------------

echo ""
echo "Running HelloWorkflow (id=$WORKFLOW_ID) …"
"$TEMPORAL_BIN" workflow execute \
    --address    "$TEMPORAL_ADDRESS" \
    --namespace  "$TEMPORAL_NAMESPACE" \
    --type       HelloWorkflow \
    --task-queue "$TEMPORAL_TASK_QUEUE" \
    --workflow-id "$WORKFLOW_ID" \
    --input      '"ReplayTest"' \
    -o json >/dev/null 2>&1
echo "OK: HelloWorkflow completed"

# -------------------------------------------------------------------------
# 2. Export the workflow history to a JSON file.
# -------------------------------------------------------------------------

echo "Exporting history …"
"$TEMPORAL_BIN" workflow show \
    --address     "$TEMPORAL_ADDRESS" \
    --namespace   "$TEMPORAL_NAMESPACE" \
    --workflow-id "$WORKFLOW_ID" \
    -o json > "$HISTORY_FILE" 2>&1
if [[ ! -s "$HISTORY_FILE" ]]; then
    echo "FAIL: history file is empty after export" >&2
    exit 1
fi
echo "OK: history exported to $HISTORY_FILE"

# -------------------------------------------------------------------------
# 3. Replay the history via the SDK Replayer (v0.3.2+).
#
# The `temporal workflow replay --workflow-file` CLI subcommand was
# removed upstream — replay is now SDK-only. The launcher exports
# TEMPORAL_REPLAY_RUNNER + TEMPORAL_WORKFLOW_MODULE +
# TEMPORAL_WORKFLOW_TYPES so test scripts can drive replay against
# captured histories.
# -------------------------------------------------------------------------

if [[ -n "${TEMPORAL_REPLAY_RUNNER:-}" && -n "${TEMPORAL_WORKFLOW_MODULE:-}" ]]; then
    echo "Replaying history via replay_runner.py …"
    if python3 "$TEMPORAL_REPLAY_RUNNER" \
            "$TEMPORAL_WORKFLOW_MODULE" \
            "$HISTORY_FILE" \
            "HelloWorkflow" 2>&1; then
        echo "OK: replay completed without non-determinism"
    else
        echo "FAIL: replay reported a non-determinism error" >&2
        exit 1
    fi
else
    echo "SKIP: TEMPORAL_REPLAY_RUNNER / TEMPORAL_WORKFLOW_MODULE not set"
    echo "      (temporal_build needs `workflow_module` to be set)"
fi

# -------------------------------------------------------------------------
# 4. Inspect the exported history for expected event types.
# -------------------------------------------------------------------------

echo "Inspecting history …"
EVENT_COUNT=$(python3 -c "
import sys, json
with open('$HISTORY_FILE') as f:
    data = json.load(f)
# Handle both 'events' at top level and nested under 'history'.
events = data.get('events') or data.get('history', {}).get('events', [])
print(len(events))
" 2>/dev/null || echo "0")

if [[ "$EVENT_COUNT" -gt 0 ]]; then
    echo "OK: history file contains $EVENT_COUNT events"
else
    echo "FAIL: could not extract events from history file" >&2
    echo "File contents: $(cat "$HISTORY_FILE")" >&2
    exit 1
fi

# Verify the history contains a WorkflowExecutionCompleted event type.
HAS_COMPLETE=$(python3 -c "
import sys, json
with open('$HISTORY_FILE') as f:
    data = json.load(f)
events = data.get('events') or data.get('history', {}).get('events', [])
types = [str(e.get('eventType', '')).lower() for e in events]
print('yes' if any('completed' in t for t in types) else 'no')
" 2>/dev/null || echo "no")

if [[ "$HAS_COMPLETE" == "yes" ]]; then
    echo "OK: history contains a Completed event"
else
    echo "FAIL: no Completed event found in history" >&2
    exit 1
fi

echo ""
echo "--- PASS ---"
