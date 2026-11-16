#!/usr/bin/env bash
# #4: the built-in runner (//private:replay_runner) and temporal_replay_runner
# outputs, run directly (no server). Good histories replay; drifted code,
# bad histories, bad modules and unknown classes fail with a clear message.
set -euo pipefail

r="${RUNFILES_DIR:-$TEST_SRCDIR}"
builtin="$r/$1"; hello_runner="$r/$2"; drifted_runner="$r/$3"
hello_mod="$r/$4"; drifted_mod="$r/$5"; needs_dep_mod="$r/$6"
hello_hist="$r/$7"; math_hist="$r/$8"; truncated_hist="$r/$9"
out="$TEST_TMPDIR/out.log"
n=0

fail() { echo "FAIL: $*" >&2; cat "$out" >&2; exit 1; }

# expect <0|nonzero> <grep pattern> -- <cmd...>
expect() {
    local want="$1" pattern="$2"; shift 3
    n=$((n + 1))
    local rc=0
    "$@" >"$out" 2>&1 || rc=$?
    if [[ "$want" == 0 && $rc -ne 0 ]]; then fail "case $n: exit $rc, want 0: $*"; fi
    if [[ "$want" != 0 && $rc -eq 0 ]]; then fail "case $n: exit 0, want non-zero: $*"; fi
    grep -q -- "$pattern" "$out" || fail "case $n: output lacks '$pattern': $*"
    echo "ok $n: $(head -1 "$out")"
}

# Built-in runner: <module path> <history> <classes>.
expect 0 "OK: .*hello_history.json replayed (temporalio " -- \
    "$builtin" "$hello_mod" "$hello_hist" HelloWorkflow,MathWorkflow
expect 0 "OK: .*math_history.json replayed" -- \
    "$builtin" "$hello_mod" "$math_hist" HelloWorkflow,MathWorkflow
expect 1 "replay of .*hello_history.json failed: .*Nondeterminism" -- \
    "$builtin" "$drifted_mod" "$hello_hist" HelloWorkflow,MathWorkflow
expect 1 "replay of .*math_history.json failed: .*Nondeterminism" -- \
    "$builtin" "$drifted_mod" "$math_hist" HelloWorkflow,MathWorkflow
expect 1 "history file not found: /nonexistent/history.json" -- \
    "$builtin" "$hello_mod" /nonexistent/history.json HelloWorkflow
expect 1 "is not valid JSON" -- \
    "$builtin" "$hello_mod" "$truncated_hist" HelloWorkflow
expect 1 "workflow module not found at /nonexistent/workflows.py" -- \
    "$builtin" /nonexistent/workflows.py "$hello_hist" HelloWorkflow
expect 1 "workflow class 'NoSuchWorkflow' not defined" -- \
    "$builtin" "$hello_mod" "$hello_hist" NoSuchWorkflow
expect 1 "class_names argument is empty" -- \
    "$builtin" "$hello_mod" "$hello_hist" ""
expect 1 "No module named 'rules_temporal_not_a_real_dependency'" -- \
    "$builtin" "$needs_dep_mod" "$hello_hist" HelloWorkflow
grep -q "temporal_replay_runner" "$out" || fail "third-party import hint does not name temporal_replay_runner"
expect 1 "usage: replay_runner" -- "$builtin" "$hello_hist"

# temporal_replay_runner: <history>; module and classes are baked in.
expect 0 "OK: .*hello_history.json replayed" -- "$hello_runner" "$hello_hist"
expect 0 "OK: .*math_history.json replayed" -- "$hello_runner" "$math_hist"
expect 1 "replay of .*math_history.json failed: .*Nondeterminism" -- \
    "$drifted_runner" "$math_hist"
expect 1 "is not valid JSON" -- "$hello_runner" "$truncated_hist"
expect 1 "usage: <replay runner> <history_file>" -- "$hello_runner"

echo "PASS: $n replay runner cases"
