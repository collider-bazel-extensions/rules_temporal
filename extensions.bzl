"Module extension: downloads or symlinks the Temporal CLI binary."

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# ---------------------------------------------------------------------------
# Version manifest
#
# Tarball URLs from https://github.com/temporalio/cli/releases
# Run tools/update_checksums.sh to refresh sha256 values.
# ---------------------------------------------------------------------------

_TEMPORAL_VERSIONS = {
    "1.6.2": {
        "linux_amd64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.6.2/temporal_cli_1.6.2_linux_amd64.tar.gz",
            sha256       = "31705ce8cb83d9144bc798fb0cf60405133b7a52ac970ccc8c6338e2fd1b1b0a",
            strip_prefix = "",
        ),
        "darwin_arm64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.6.2/temporal_cli_1.6.2_darwin_arm64.tar.gz",
            sha256       = "",  # TODO: pin real sha256
            strip_prefix = "",
        ),
        "darwin_amd64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.6.2/temporal_cli_1.6.2_darwin_amd64.tar.gz",
            sha256       = "",  # TODO: pin real sha256
            strip_prefix = "",
        ),
    },
}

_PLATFORMS = ["linux_amd64", "darwin_arm64", "darwin_amd64"]

# ---------------------------------------------------------------------------
# BUILD template injected into each binary repo
# ---------------------------------------------------------------------------

_BUILD_TMPL = """
load("@rules_temporal//private:binary.bzl", "temporal_binary_files")

filegroup(
    name = "all_bin_files",
    srcs = glob(["*", "bin/*"]),
)

temporal_binary_files(
    name = "temporal_bins",
    version = "{version}",
    bins = [":all_bin_files"],
    visibility = ["//visibility:public"],
)
"""

# ---------------------------------------------------------------------------
# Repository rule: downloaded tarball
# ---------------------------------------------------------------------------

def _temporal_binary_repo_impl(rctx):
    rctx.download_and_extract(
        url          = rctx.attr.url,
        sha256       = rctx.attr.sha256,
        stripPrefix  = rctx.attr.strip_prefix,
    )
    rctx.file("BUILD.bazel", _BUILD_TMPL.format(version = rctx.attr.version))

_temporal_binary_repo = repository_rule(
    implementation = _temporal_binary_repo_impl,
    attrs = {
        "platform":      attr.string(mandatory = True),
        "sha256":        attr.string(mandatory = True),
        "strip_prefix":  attr.string(default = ""),
        "url":           attr.string(mandatory = True),
        "version":       attr.string(mandatory = True),
    },
)

# ---------------------------------------------------------------------------
# Repository rule: system-installed Temporal CLI
# ---------------------------------------------------------------------------

def _temporal_system_binary_repo_impl(rctx):
    bin_dir = rctx.attr.bin_dir

    # Auto-detect bin_dir if not provided.
    if not bin_dir:
        res = rctx.execute(["sh", "-c", "command -v temporal 2>/dev/null || true"])
        path = res.stdout.strip()
        if path:
            bin_dir = path.rsplit("/", 1)[0]
        else:
            for candidate in [
                "/usr/bin",
                "/usr/local/bin",
                "/usr/local/temporal/bin",
                "/opt/homebrew/bin",
                "/opt/local/bin",
                "/home/linuxbrew/.linuxbrew/bin",
            ]:
                res = rctx.execute(["test", "-x", candidate + "/temporal"])
                if res.return_code == 0:
                    bin_dir = candidate
                    break

        # Also check ~/.local/bin (common user install location).
        if not bin_dir:
            res = rctx.execute(["sh", "-c",
                "test -x \"$HOME/.local/bin/temporal\" && " +
                "echo \"$HOME/.local/bin\" || true"])
            path = res.stdout.strip()
            if path:
                bin_dir = path

    if not bin_dir:
        fail(
            "\nrules_temporal: temporal.system() — could not locate the temporal CLI.\n" +
            "Install it from https://docs.temporal.io/cli or pass bin_dir explicitly:\n\n" +
            "    pg.system(versions = [\"1.6.2\"], bin_dir = \"/usr/local/bin\")\n"
        )

    # Verify temporal binary exists and is executable.
    temporal_path = bin_dir + "/temporal"
    res = rctx.execute(["test", "-x", temporal_path])
    if res.return_code != 0:
        fail(
            "\nrules_temporal: temporal.system() — binary not found or not executable:\n" +
            "  {}\n".format(temporal_path) +
            "Install the Temporal CLI: https://docs.temporal.io/cli\n"
        )

    # Version check.
    res = rctx.execute([temporal_path, "--version"])
    version_out = (res.stdout + res.stderr).strip()
    if not version_out:
        fail(
            "\nrules_temporal: temporal.system() — '{}' produced no output for " +
            "--version. Is it a valid Temporal CLI binary?\n".format(temporal_path)
        )

    rctx.execute(["mkdir", "-p", "bin"])
    rctx.symlink(temporal_path, "bin/temporal")
    rctx.file("BUILD.bazel", _BUILD_TMPL.format(version = rctx.attr.version))

_temporal_system_binary_repo = repository_rule(
    implementation = _temporal_system_binary_repo_impl,
    attrs = {
        "bin_dir": attr.string(default = ""),
        "version": attr.string(mandatory = True),
    },
)

# ---------------------------------------------------------------------------
# Module extension
# ---------------------------------------------------------------------------

_version_tag = tag_class(attrs = {
    "versions": attr.string_list(default = ["1.6.2"]),
})

_system_tag = tag_class(attrs = {
    "versions": attr.string_list(default = ["1.6.2"]),
    "bin_dir":  attr.string(default = ""),
})

def _temporal_extension_impl(module_ctx):
    system_cfg = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.system:
            for v in tag.versions:
                system_cfg[v] = {"bin_dir": tag.bin_dir}

    download_versions = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.version:
            for v in tag.versions:
                if v not in system_cfg:
                    download_versions[v] = True

    # Validate all versions.
    for v in list(system_cfg.keys()) + list(download_versions.keys()):
        if v not in _TEMPORAL_VERSIONS:
            fail("Unsupported Temporal CLI version: {}. Supported: {}".format(
                v, ", ".join(_TEMPORAL_VERSIONS.keys())))

    # Create system repos.
    for version, cfg in system_cfg.items():
        for platform in _PLATFORMS:
            _temporal_system_binary_repo(
                name    = "temporal_{}_{}".format(version.replace(".", "_"), platform),
                version = version,
                bin_dir = cfg["bin_dir"],
            )

    # Create download repos.
    for version in download_versions.keys():
        for platform in _PLATFORMS:
            spec = _TEMPORAL_VERSIONS[version][platform]
            if not spec.sha256:
                fail(
                    "SHA-256 checksum for temporal {} {} is not pinned. ".format(version, platform) +
                    "Run tools/update_checksums.sh or use temporal.system() instead."
                )
            _temporal_binary_repo(
                name         = "temporal_{}_{}".format(version.replace(".", "_"), platform),
                version      = version,
                platform     = platform,
                url          = spec.url,
                sha256       = spec.sha256,
                strip_prefix = spec.strip_prefix,
            )

temporal = module_extension(
    implementation = _temporal_extension_impl,
    tag_classes = {
        "version": _version_tag,
        "system":  _system_tag,
    },
)
