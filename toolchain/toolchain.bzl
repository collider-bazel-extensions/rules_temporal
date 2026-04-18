"Temporal toolchain type and registration helpers."

load("//private:binary.bzl", "TemporalBinaryInfo")

TEMPORAL_TOOLCHAIN_TYPE = Label("//toolchain:temporal")

def _temporal_toolchain_impl(ctx):
    bin_info = ctx.attr.binary[TemporalBinaryInfo]
    return [
        platform_common.ToolchainInfo(temporal = bin_info),
        DefaultInfo(files = bin_info.all_files),
    ]

temporal_toolchain = rule(
    implementation = _temporal_toolchain_impl,
    doc = "Declares a Temporal toolchain from a temporal_binary target.",
    attrs = {
        "binary": attr.label(
            mandatory = True,
            providers = [TemporalBinaryInfo],
            doc = "temporal_binary target for this toolchain.",
        ),
    },
)

_PLATFORM_CONSTRAINTS = {
    "linux_amd64":  ["@platforms//os:linux",  "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos",  "@platforms//cpu:aarch64"],
    "darwin_amd64": ["@platforms//os:macos",  "@platforms//cpu:x86_64"],
}

def register_temporal_toolchains(versions = None, name = ""):
    """Registers temporal_toolchain targets for each supported version/platform."""
    versions = versions or ["1.6.2"]
    for version in versions:
        safe_version = version.replace(".", "_")
        for platform, constraints in _PLATFORM_CONSTRAINTS.items():
            native.toolchain(
                name = "temporal_{}_{}toolchain".format(safe_version, platform),
                toolchain_type = str(TEMPORAL_TOOLCHAIN_TYPE),
                toolchain = "@rules_temporal//:temporal_{}".format(safe_version),
                target_compatible_with = constraints,
            )
