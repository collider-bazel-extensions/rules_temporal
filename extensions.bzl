"Module extension: downloads or symlinks the Temporal CLI binary."

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# ---------------------------------------------------------------------------
# Version manifest
#
# Tarball URLs from https://github.com/temporalio/cli/releases
# Run tools/update_checksums.sh to refresh sha256 values.
# ---------------------------------------------------------------------------

_TEMPORAL_VERSIONS = {
    "1.7.0": {
        "linux_amd64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.7.0/temporal_cli_1.7.0_linux_amd64.tar.gz",
            sha256       = "8b5de72e622f4ae062d0d5d948ca398de6212d63b2f25766a1cb810a3dc2d0ed",
            strip_prefix = "",
        ),
        "linux_arm64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.7.0/temporal_cli_1.7.0_linux_arm64.tar.gz",
            sha256       = "f78d8cf0353b4e04c9024f11e66eaba372f07efe9956de0f41cf03bd31c302f3",
            strip_prefix = "",
        ),
        "darwin_amd64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.7.0/temporal_cli_1.7.0_darwin_amd64.tar.gz",
            sha256       = "a289156e464bdbb667a125b5e94abeab98a74814771ea4828731970cab4e907c",
            strip_prefix = "",
        ),
        "darwin_arm64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.7.0/temporal_cli_1.7.0_darwin_arm64.tar.gz",
            sha256       = "88a59ea7b1a51309a873e2a914360865123d5b36528d55f8d7c34c6d79007fda",
            strip_prefix = "",
        ),
    },
    # v1.6.2 retained as a fallback pin. Shas filled in v0.5; the
    # darwin entries were placeholders pre-v0.5.
    "1.6.2": {
        "linux_amd64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.6.2/temporal_cli_1.6.2_linux_amd64.tar.gz",
            sha256       = "31705ce8cb83d9144bc798fb0cf60405133b7a52ac970ccc8c6338e2fd1b1b0a",
            strip_prefix = "",
        ),
        "linux_arm64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.6.2/temporal_cli_1.6.2_linux_arm64.tar.gz",
            sha256       = "d31f4ac56f6a78f259cc09d0185a43e08eadca303b6904a38f7774c85160d9d7",
            strip_prefix = "",
        ),
        "darwin_amd64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.6.2/temporal_cli_1.6.2_darwin_amd64.tar.gz",
            sha256       = "fa34a8936a99cd3a9d1dd9de0cab56e35b72b212274c6d89de8a418422244964",
            strip_prefix = "",
        ),
        "darwin_arm64": struct(
            url          = "https://github.com/temporalio/cli/releases/download/v1.6.2/temporal_cli_1.6.2_darwin_arm64.tar.gz",
            sha256       = "a796be2acda58bc72036d6541605646b86534dd50bbffc7ce697f4ce175ab6ee",
            strip_prefix = "",
        ),
    },
}

_PLATFORMS = ["linux_amd64", "linux_arm64", "darwin_amd64", "darwin_arm64"]

# ---------------------------------------------------------------------------
# BUILD template injected into each binary repo
# ---------------------------------------------------------------------------

_BUILD_TMPL = """
load("@rules_temporal//private:binary.bzl", "temporal_binary_files")

# Bazel 8+ defaults --incompatible_disallow_empty_glob to True; the
# temporal CLI tarballs sometimes ship the binary at repo root and
# sometimes under bin/ depending on the release. allow_empty lets
# either layout work.
filegroup(
    name = "all_bin_files",
    srcs = glob(["*", "bin/*"], allow_empty = True),
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
            "\n" +
            "Either switch to hermetic mode (no host install required):\n\n" +
            "    temporal = use_extension(\"@rules_temporal//:extensions.bzl\", \"temporal\")\n" +
            "    temporal.version(versions = [\"1.7.0\"])\n" +
            "    use_repo(temporal,\n" +
            "        \"temporal_1_7_0_linux_amd64\",\n" +
            "        \"temporal_1_7_0_linux_arm64\",\n" +
            "        \"temporal_1_7_0_darwin_amd64\",\n" +
            "        \"temporal_1_7_0_darwin_arm64\",\n" +
            "    )\n" +
            "\n" +
            "Or install the host CLI (https://docs.temporal.io/cli) and pass bin_dir explicitly:\n\n" +
            "    temporal.system(versions = [\"1.7.0\"], bin_dir = \"/usr/local/bin\")\n"
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
    "versions": attr.string_list(default = ["1.7.0"]),
})

_system_tag = tag_class(attrs = {
    "versions": attr.string_list(default = ["1.7.0"]),
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
