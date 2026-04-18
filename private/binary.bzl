"temporal_binary rule and TemporalBinaryInfo provider."

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

TemporalBinaryInfo = provider(
    doc = "Carries the path to the Temporal CLI binary.",
    fields = {
        "temporal":  "File: the temporal CLI binary",
        "version":   "string: declared CLI version, e.g. '1.6.2'",
        "all_files": "depset: all files required at runtime",
    },
)

# ---------------------------------------------------------------------------
# Helper injected into each binary repo's BUILD
# ---------------------------------------------------------------------------

def _temporal_binary_files_impl(ctx):
    bins = {f.basename: f for f in ctx.files.bins}

    temporal_bin = bins.get("temporal")
    if not temporal_bin:
        fail(
            "Expected binary 'temporal' not found in Temporal CLI archive.\n" +
            "Contents: {}\n".format(bins.keys()) +
            "Check that the downloaded tarball contains a 'temporal' binary.\n"
        )

    all_files = depset([temporal_bin])

    return [
        DefaultInfo(files = all_files),
        TemporalBinaryInfo(
            temporal  = temporal_bin,
            version   = ctx.attr.version,
            all_files = all_files,
        ),
    ]

temporal_binary_files = rule(
    implementation = _temporal_binary_files_impl,
    doc = "Injected into each binary repo's BUILD. Wraps the temporal binary into a provider.",
    attrs = {
        "version": attr.string(mandatory = True, doc = "Temporal CLI version string."),
        "bins": attr.label_list(
            default = [":all_bin_files"],
            allow_files = True,
            doc = "The bin/ filegroup from the downloaded or symlinked archive.",
        ),
    },
)

# ---------------------------------------------------------------------------
# temporal_binary — user-facing rule that selects the right repo
# ---------------------------------------------------------------------------

def _temporal_binary_impl(ctx):
    bin_info = ctx.attr.binary[TemporalBinaryInfo]
    return [
        DefaultInfo(files = bin_info.all_files),
        bin_info,
    ]

temporal_binary = rule(
    implementation = _temporal_binary_impl,
    doc = """\
Selects the correct Temporal CLI binary for the current platform.

Typically consumed via the default //:temporal_default target or via
temporal_test's `temporal` attribute. You only need this rule directly
when building a custom rule that needs the Temporal CLI binary.
""",
    attrs = {
        "binary": attr.label(
            mandatory = True,
            providers = [TemporalBinaryInfo],
            doc = "The platform-specific binary target (set via select() in BUILD.bazel).",
        ),
        "version": attr.string(
            default = "",
            doc = "Temporal CLI version. Informational only.",
        ),
    },
)
