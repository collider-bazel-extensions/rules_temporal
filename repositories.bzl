"""
Legacy WORKSPACE support.

Bzlmod users (MODULE.bazel) do not need this file.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

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

def _temporal_system_binary_repo_impl(rctx):
    bin_dir = rctx.attr.bin_dir

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
            ]:
                res = rctx.execute(["test", "-x", candidate + "/temporal"])
                if res.return_code == 0:
                    bin_dir = candidate
                    break

        if not bin_dir:
            res = rctx.execute(["sh", "-c",
                "test -x \"$HOME/.local/bin/temporal\" && " +
                "echo \"$HOME/.local/bin\" || true"])
            path = res.stdout.strip()
            if path:
                bin_dir = path

    if not bin_dir:
        fail(
            "\nrules_temporal: temporal_system_dependencies() — could not locate temporal CLI.\n" +
            "Install from https://docs.temporal.io/cli or pass bin_dir explicitly.\n"
        )

    temporal_path = bin_dir + "/temporal"
    res = rctx.execute(["test", "-x", temporal_path])
    if res.return_code != 0:
        fail(
            "\nrules_temporal: required binary not found or not executable:\n" +
            "  {}\n".format(temporal_path)
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

def temporal_system_dependencies(versions = None, bin_dir = ""):
    """Create external repos backed by a system-installed Temporal CLI.

    Use this instead of temporal_dependencies() when CDN access is unavailable
    or when you want to use the host-installed temporal binary.

    Args:
        versions: list of version strings. Default ["1.6.2"].
        bin_dir:  directory containing the temporal binary. Auto-detected if empty.
    """
    versions = versions or ["1.6.2"]
    for version in versions:
        for platform in _PLATFORMS:
            name = "temporal_{}_{}".format(version.replace(".", "_"), platform)
            if not native.existing_rule(name):
                _temporal_system_binary_repo(
                    name    = name,
                    version = version,
                    bin_dir = bin_dir,
                )

def temporal_dependencies(versions = None):
    """Download pre-built Temporal CLI tarballs from GitHub releases.

    Args:
        versions: list of version strings. Default ["1.6.2"].
    """
    versions = versions or ["1.6.2"]
    for version in versions:
        for platform in _PLATFORMS:
            spec = _TEMPORAL_VERSIONS[version][platform]
            name = "temporal_{}_{}".format(version.replace(".", "_"), platform)
            if not native.existing_rule(name):
                if not spec.sha256:
                    fail(
                        "SHA-256 for temporal {} {} is not pinned. ".format(version, platform) +
                        "Use temporal_system_dependencies() or pin the checksum."
                    )
                http_archive(
                    name               = name,
                    urls               = [spec.url],
                    sha256             = spec.sha256,
                    strip_prefix       = spec.strip_prefix,
                    build_file_content = _BUILD_TMPL.format(version = version),
                )
