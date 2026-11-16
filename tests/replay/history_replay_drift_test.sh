#!/usr/bin/env bash
# #4: a committed history that no longer matches the workflow code fails the
# temporal_test before its body runs, with the runner's report.
set -euo pipefail

inner="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
out="$TEST_TMPDIR/inner.log"
rc=0
"$inner" >"$out" 2>&1 || rc=$?
cat "$out"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $rc -ne 0 ]] || fail "inner test passed; want a replay failure"
grep -q "Replaying workflow history (Python runner): .*hello_history.json" "$out" \
    || fail "launcher did not replay with the built-in runner"
grep -q "Workflow history replay failed for .*hello_history.json" "$out" \
    || fail "no 'Workflow history replay failed for ...hello_history.json'"
grep -q "\[replay_runner\] replay of .*hello_history.json failed" "$out" \
    || fail "runner's failure report missing"
grep -q "non-determinism" "$out" || fail "no non-determinism hint"
grep -q "Replayed with temporalio " "$out" || fail "temporalio version not reported"
! grep -q "TEST BODY RAN" "$out" || fail "the test body ran"
echo "PASS: drifted workflow code failed history replay"
