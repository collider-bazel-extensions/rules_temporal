#!/usr/bin/env bash
# temporal_health_check_test.sh
#
# Verifies temporal_health_check behaviour independently of a running server:
#   - exits non-zero when $TEST_TMPDIR/<server-name>.env does not exist
#   - exits 0 when the file is present
#   - exits non-zero again after the file is removed
#
# $1: rootpath of the temporal_health_check binary (relative to TEST_SRCDIR)

set -euo pipefail

HEALTH_CHECK="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
# The health check targets :temporal_server_test_svc, so it looks for this file.
ENV_FILE="$TEST_TMPDIR/temporal_server_test_svc.env"

echo "--- temporal_health_check_test ---"

# Ensure the env file does not exist.
rm -f "$ENV_FILE"

# Health check should exit non-zero when the env file is absent.
if "$HEALTH_CHECK" 2>/dev/null; then
    echo "FAIL: health check should exit non-zero before env file exists" >&2
    exit 1
fi
echo "OK: health check exits non-zero when env file is absent"

# Create a minimal env file (content does not matter; existence is the signal).
cat > "$ENV_FILE" <<'EOF'
TEMPORAL_ADDRESS=127.0.0.1:55432
TEMPORAL_NAMESPACE=temporal-test-abc123def456
EOF

# Health check should now exit 0.
if ! "$HEALTH_CHECK"; then
    echo "FAIL: health check should exit 0 when env file exists" >&2
    exit 1
fi
echo "OK: health check exits 0 when env file exists"

# Remove the file again: health check should go back to failing.
rm "$ENV_FILE"
if "$HEALTH_CHECK" 2>/dev/null; then
    echo "FAIL: health check should exit non-zero after env file is removed" >&2
    exit 1
fi
echo "OK: health check exits non-zero after env file is removed"

echo "--- PASS ---"
