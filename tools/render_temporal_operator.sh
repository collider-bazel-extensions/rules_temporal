#!/usr/bin/env bash
# Maintainer flow:
#   1. Edit tools/versions.bzl::TEMPORAL_OPERATOR_VERSIONS — add the
#      target version's URLs + sha256 for both crds.yaml and the
#      non-CRDs operator.yaml.
#   2. tools/render_temporal_operator.sh <version>  (e.g. v0.22.0)
#
# Bazel-free: curl + sha-check + concat (CRDs first, then operator)
# + commit. Mirrors rules_tekton's release.yaml pattern but with
# two upstream files concatenated to one local manifest. The
# concat order matters: CRDs must apply before the operator's
# Deployment + webhook configs reference them.
set -euo pipefail

VERSION="${1:?usage: tools/render_temporal_operator.sh <version>}"

_extract() {
  local key="$1"
  awk -v v="\"$VERSION\":" -v k="\"$key\":" '
      $0 ~ v { in_block=1; next }
      in_block && index($0, k) { gsub(/[",]/,""); print $2; exit }
  ' tools/versions.bzl
}

crds_url=$(_extract crds_url)
crds_sha=$(_extract crds_sha256)
operator_url=$(_extract operator_url)
operator_sha=$(_extract operator_sha256)

[[ -n "$crds_url" && -n "$crds_sha" && -n "$operator_url" && -n "$operator_sha" ]] || {
  echo "render_temporal_operator: version '$VERSION' not in tools/versions.bzl" >&2
  exit 1
}

tmp_crds=$(mktemp)
tmp_op=$(mktemp)
trap 'rm -f "$tmp_crds" "$tmp_op"' EXIT

echo "render_temporal_operator: fetching $crds_url"
curl -sLfo "$tmp_crds" "$crds_url"
echo "$crds_sha  $tmp_crds" | sha256sum -c >/dev/null

echo "render_temporal_operator: fetching $operator_url"
curl -sLfo "$tmp_op" "$operator_url"
echo "$operator_sha  $tmp_op" | sha256sum -c >/dev/null

dest="private/manifests/temporal_operator.yaml"
cat "$tmp_crds" "$tmp_op" > "$dest"

echo "render_temporal_operator: wrote $dest"
echo "  version: $VERSION"
echo "  sha256:  $(sha256sum "$dest" | awk '{print $1}')"
echo "  lines:   $(wc -l < "$dest")"
