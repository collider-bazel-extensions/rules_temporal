#!/usr/bin/env bash
# #13: //:temporal is runnable from runfiles, at the pinned version, with no
# host `temporal` (PATH is cleared below). $1 is
# `$(rlocationpath //:temporal)`.
set -euo pipefail
cli="${RUNFILES_DIR:-$0.runfiles}/$1"
[[ -x "$cli" ]] || { echo "FAIL: $1 not executable in runfiles ($cli)" >&2; exit 1; }
out="$(PATH=/nonexistent "$cli" --version)"
echo "$out"
[[ "$out" == "temporal version 1.7.0 "* ]] || { echo "FAIL: want 1.7.0, got: $out" >&2; exit 1; }
echo "PASS: //:temporal runs the hermetic CLI 1.7.0 from runfiles"
