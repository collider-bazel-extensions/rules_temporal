workspace(name = "rules_temporal")

# Bzlmod users (MODULE.bazel) do not need this file.
#
# Legacy WORKSPACE usage:
#
#   load("@rules_temporal//:repositories.bzl", "temporal_system_dependencies")
#   temporal_system_dependencies(versions = ["1.6.2"])

load("//:repositories.bzl", "temporal_system_dependencies")

temporal_system_dependencies(
    versions = ["1.6.2"],
    # bin_dir auto-detected via PATH if omitted.
)
