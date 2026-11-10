#!/usr/bin/env bash
# Consumer check against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do): the
# export-ignored directories are absent and @rules_temporal//... loads for a
# consumer. Same check as rules_atlas / rules_kubectl.
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_temporal"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive HEAD | tar -x -C "$src"
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
