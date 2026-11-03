#!/usr/bin/env bash
# #10: temporal_test honours worker_ready_timeout. Runs :never_ready_test
# (worker_ready_timeout = 3, worker never connects) and checks it fails
# after 3 s, naming the task queue, without running its test body.
set -euo pipefail

inner="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
out="$TEST_TMPDIR/inner.log"
start=$(date +%s)
rc=0
"$inner" >"$out" 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))
cat "$out"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $rc -ne 0 ]] || fail "inner test passed; want a failure"
grep -q "Ready timeouts: server 30.0s, worker 3.0s (task queue 'never-ready-462')" "$out" \
    || fail "launcher did not log the configured timeouts"
grep -q "Worker not ready within 3.0s" "$out" || fail "no 'Worker not ready within 3.0s'"
grep -q "task_queue='never-ready-462'" "$out" || fail "task queue not named"
! grep -q "TEST BODY RAN" "$out" || fail "the test body ran"
[[ $elapsed -lt 25 ]] || fail "took ${elapsed}s; the 3 s worker timeout was not used"
echo "PASS: worker_ready_timeout = 3 failed the test after ${elapsed}s"
