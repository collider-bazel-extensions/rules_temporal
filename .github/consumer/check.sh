#!/usr/bin/env bash
# Consumer check against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do): the
# export-ignored directories are absent and @rules_temporal//... loads for a
# consumer. Same check as rules_atlas / rules_kubectl. Then (#13) the CLI
# targets run for a consumer and (#4) a consumer that never replays fetches
# no Python interpreter or wheel, while one that does replays with the
# pinned temporalio and no host pip.
# Usage: .github/consumer/check.sh <scratch dir> [<tree-ish>, default HEAD]
# (Before committing: git add -A && .github/consumer/check.sh /tmp/c "$(git write-tree)")
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_temporal"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive "${2:-HEAD}" | tar -x -C "$src"
for d in tests; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
# rules_kubectl is a non-dev dependency outside the BCR: pin it as this
# repo's MODULE.bazel does (its override applies only when it is the root).
kubectl_version="$(sed -n 's/^bazel_dep(name = "rules_kubectl", version = "\([^"]*\)".*/\1/p' "$src/MODULE.bazel")"
kubectl_commit="$(grep -A3 'module_name = "rules_kubectl"' "$src/MODULE.bazel" | sed -n 's/.*commit = "\([0-9a-f]*\)".*/\1/p')"

c="$work/consumer"
mkdir -p "$c"
touch "$c/BUILD.bazel"
if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "rules_temporal")
local_path_override(module_name = "rules_temporal", path = "$src")
bazel_dep(name = "rules_shell", version = "0.8.0")
bazel_dep(name = "rules_kubectl", version = "$kubectl_version")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "$kubectl_commit",
)
MOD
# A reused output base (local runs) could hold repos from an earlier run's
# replay step; start clean so the laziness check below means something.
(cd "$c" && bazel clean --expunge 2>/dev/null || true)
(cd "$c" && bazel query @rules_temporal//... >/dev/null)
echo "PASS: @rules_temporal//... loads; archive has no tests"

# #13: a consumer runs the hermetic CLI directly, and a consumer binary takes
# it in `data` and finds it at $(rlocationpath). PATH is cleared so a host
# `temporal` can't stand in.
cat > "$c/BUILD.bazel" <<'BUILD'
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
sh_binary(
    name = "describe",
    srcs = ["describe.sh"],
    args = ["$(rlocationpath @rules_temporal//:temporal)"],
    data = ["@rules_temporal//:temporal"],
)
BUILD
cat > "$c/describe.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PATH=/nonexistent "${RUNFILES_DIR:-$0.runfiles}/$1" --version
SH
chmod +x "$c/describe.sh"
want="temporal version 1.7.0 "
got="$(cd "$c" && bazel run --ui_event_filters=-info --noshow_progress @rules_temporal//:temporal -- --version)"
[[ "$got" == "$want"* ]] || { echo "FAIL: bazel run @rules_temporal//:temporal: $got" >&2; exit 1; }
got="$(cd "$c" && bazel run --ui_event_filters=-info --noshow_progress //:describe)"
[[ "$got" == "$want"* ]] || { echo "FAIL: //:describe via rlocationpath: $got" >&2; exit 1; }
echo "PASS: consumer runs @rules_temporal//:temporal ($got), directly and via rlocationpath"

# #4: laziness. A consumer temporal_test without `history` must not fetch a
# Python interpreter or any of @rules_temporal_pypi's wheels: only replay
# pays for them.
cat >> "$c/BUILD.bazel" <<'BUILD'

load("@rules_temporal//:defs.bzl", "temporal_build", "temporal_test", "temporal_workflow_history")

sh_binary(name = "worker", srcs = ["worker.sh"])

temporal_build(
    name           = "plain_worker",
    worker_binary  = ":worker",
    task_queue     = "q",
    workflow_types = ["HelloWorkflow"],
)

temporal_test(name = "plain_test", worker = ":plain_worker", srcs = ["body.sh"])
BUILD
printf '#!/usr/bin/env bash\nexit 0\n' > "$c/worker.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$c/body.sh"
chmod +x "$c/worker.sh" "$c/body.sh"
(cd "$c" && bazel build --ui_event_filters=-info --noshow_progress //:plain_test //:describe)
external="$(cd "$c" && bazel info output_base)/external"
fetched_python() {
    find "$external" -mindepth 1 -maxdepth 1 \
        \( -name '*python_3_*' -o -name '*rules_temporal_pypi*' -o -name '*pythons_hub*' \) \
        ! -name '*.marker' -printf '%f\n' | sort
}
lazy="$(fetched_python | grep -v pythons_hub || true)"
if [[ -n "$lazy" ]]; then
    echo "FAIL: a consumer that never replays fetched Python / wheels:" >&2
    echo "$lazy" >&2
    exit 1
fi
echo "PASS: non-replay consumer build fetched no Python interpreter or wheel" \
     "(rules_python repos present: $(find "$external" -mindepth 1 -maxdepth 1 -name 'rules_python*' ! -name '*.marker' | wc -l), toolchain hub only: $(fetched_python | tr '\n' ' '))"

# #4: replay from a consumer. The built-in runner (pip.parse in a non-root
# module, py_binary pinned to its own Python) replays a committed history
# without a server and without host temporalio; a temporal_test with
# `history` builds.
cp "$repo/tests/workers/hello_worker.py" "$c/hello_worker.py"
cp "$repo/tests/replay/testdata/hello_history.json" "$c/hello_history.json"
cat >> "$c/BUILD.bazel" <<'BUILD'

temporal_build(
    name            = "py_worker",
    worker_binary   = ":worker",
    workflow_module = "hello_worker.py",
    task_queue      = "q",
    workflow_types  = ["HelloWorkflow"],
)

temporal_workflow_history(name = "histories", worker = ":py_worker", srcs = ["hello_history.json"])

temporal_test(name = "replay_test", worker = ":py_worker", history = ":histories", srcs = ["body.sh"])
BUILD
(cd "$c" && bazel build --ui_event_filters=-info --noshow_progress //:replay_test)
got="$(cd "$c" && PYTHONNOUSERSITE=1 bazel run --ui_event_filters=-info --noshow_progress \
    @rules_temporal//private:replay_runner -- \
    "$c/hello_worker.py" "$c/hello_history.json" HelloWorkflow 2>&1 | tail -1)"
[[ "$got" == "[replay_runner] OK: "*"hello_history.json replayed (temporalio "* ]] \
    || { echo "FAIL: consumer replay: $got" >&2; exit 1; }
echo "PASS: consumer replay with the pinned SDK: $got"
