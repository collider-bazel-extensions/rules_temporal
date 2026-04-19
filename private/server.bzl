"temporal_server rule and temporal_health_check rule."

load("//private:binary.bzl", "TemporalBinaryInfo")

# ---------------------------------------------------------------------------
# temporal_server
# ---------------------------------------------------------------------------

def _temporal_server_impl(ctx):
    binary_info = ctx.attr.temporal[TemporalBinaryInfo]
    workspace   = ctx.workspace_name

    # Server manifest: only the fields needed for server-mode startup.
    # No worker fields (task_queue, workflow_types, etc.) — those are
    # worker concerns and are irrelevant to a standalone Temporal server.
    manifest_content = """\
{{
  "workspace":    "{workspace}",
  "temporal_bin": "{temporal_bin}"
}}
""".format(
        workspace    = workspace,
        temporal_bin = binary_info.temporal.short_path,
    )

    manifest = ctx.actions.declare_file(ctx.label.name + "_server_manifest.json")
    ctx.actions.write(output = manifest, content = manifest_content)

    env_file_name = ctx.label.name + ".env"

    wrapper = ctx.actions.declare_file(ctx.label.name + "_temporal_server.sh")
    ctx.actions.write(
        output  = wrapper,
        content = """\
#!/usr/bin/env bash
set -euo pipefail
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  echo "[rules_temporal] Neither TEST_SRCDIR nor RUNFILES_DIR is set" >&2
  exit 1
fi
export RULES_TEMPORAL_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest}"
export RULES_TEMPORAL_MODE=server
export RULES_TEMPORAL_OUTPUT_ENV_FILE="${{TEST_TMPDIR:-/tmp}}/{env_file_name}"
exec python3 "$RUNFILES_ROOT/{workspace}/{launcher}" "$@"
""".format(
            workspace     = workspace,
            manifest      = manifest.short_path,
            launcher      = ctx.file.launcher.short_path,
            env_file_name = env_file_name,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files             = [ctx.file.launcher, manifest],
        transitive_files  = binary_info.all_files,
    ).merge(ctx.runfiles(files = [wrapper]))

    return [DefaultInfo(executable = wrapper, runfiles = runfiles)]


temporal_server = rule(
    implementation = _temporal_server_impl,
    executable     = True,
    doc = """\
Produces a long-running executable that starts an ephemeral Temporal dev
server.  Designed for use with rules_itest or any service manager that runs
services alongside integration tests.

Once the server is fully ready (TCP port open, gRPC healthy, namespace
created), writes $TEST_TMPDIR/<name>.env atomically with:

    TEMPORAL_ADDRESS=127.0.0.1:<port>
    TEMPORAL_NAMESPACE=temporal-test-<12-hex>

Stops cleanly on SIGTERM (rules_itest) or SIGINT (bazel run).

Example:

    temporal_server(name = "db_svc")
    temporal_health_check(name = "db_health", server = ":db_svc")
""",
    attrs = {
        "launcher": attr.label(
            default         = Label("//private:launcher.py"),
            allow_single_file = True,
            doc = "The Python launcher script.",
        ),
        "temporal": attr.label(
            default   = Label("//:temporal_default"),
            providers = [TemporalBinaryInfo],
            doc       = "temporal_binary target. Defaults to //:temporal_default.",
        ),
    },
)

# ---------------------------------------------------------------------------
# temporal_health_check
# ---------------------------------------------------------------------------

def _temporal_health_check_impl(ctx):
    server_name  = ctx.attr.server.label.name
    env_file     = server_name + ".env"

    script = ctx.actions.declare_file(ctx.label.name + "_health_check.sh")
    ctx.actions.write(
        output  = script,
        content = """\
#!/usr/bin/env bash
set -euo pipefail
env_file="${{TEST_TMPDIR:-/tmp}}/{env_file}"
if [[ -f "$env_file" ]]; then
  exit 0
fi
echo "[rules_temporal] temporal_server env file not yet present: $env_file" >&2
exit 1
""".format(env_file = env_file),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles   = ctx.runfiles(files = [script]),
    )]


temporal_health_check = rule(
    implementation = _temporal_health_check_impl,
    executable     = True,
    doc = """\
Generates a health-check binary for a temporal_server target.

Exits 0 if and only if $TEST_TMPDIR/<server-name>.env exists; exits non-zero
otherwise.  Pass this as the health_check attribute of an itest_service.

Example:

    temporal_health_check(
        name   = "db_health",
        server = ":db_svc",
    )
""",
    attrs = {
        "server": attr.label(
            mandatory = True,
            doc = "The temporal_server target this check monitors.",
        ),
    },
)
