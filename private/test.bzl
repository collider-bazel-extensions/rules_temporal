"temporal_test macro and _temporal_launcher_test rule."

load("//private:binary.bzl", "TemporalBinaryInfo")
load("//private:worker.bzl", "TemporalWorkerInfo")

# ---------------------------------------------------------------------------
# Internal rule: launcher + runfiles assembly
# ---------------------------------------------------------------------------

def _temporal_launcher_impl(ctx):
    worker_info = ctx.attr.worker[TemporalWorkerInfo]

    # Collect all files the launcher needs at runtime.
    runfiles = ctx.runfiles(
        files = [ctx.file.launcher, worker_info.manifest],
        transitive_files = worker_info.binary_info.all_files,
    ).merge_all([
        ctx.runfiles(transitive_files = worker_info.worker_runfiles),
        ctx.attr.test_binary.default_runfiles,
    ])

    # Wrapper script: sets env vars and execs the launcher.
    workspace = ctx.workspace_name
    wrapper = ctx.actions.declare_file(ctx.label.name + "_temporal_wrapper.sh")
    ctx.actions.write(
        output    = wrapper,
        content   = """\
#!/usr/bin/env bash
set -euo pipefail
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  echo "[rules_temporal] Neither TEST_SRCDIR nor RUNFILES_DIR is set" >&2
  exit 1
fi
export TEMPORAL_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest}"
export TEMPORAL_TEST_BINARY="$RUNFILES_ROOT/{workspace}/{test_bin}"
exec python3 "$RUNFILES_ROOT/{workspace}/{launcher}" "$@"
""".format(
            workspace = workspace,
            manifest  = worker_info.manifest.short_path,
            launcher  = ctx.file.launcher.short_path,
            test_bin  = ctx.attr.test_binary.files_to_run.executable.short_path,
        ),
        is_executable = True,
    )

    runfiles = runfiles.merge(ctx.runfiles(files = [wrapper]))

    return [
        DefaultInfo(
            executable = wrapper,
            runfiles   = runfiles,
        ),
    ]

_temporal_launcher_test = rule(
    implementation = _temporal_launcher_impl,
    test = True,
    doc  = "Internal rule. Use the temporal_test macro instead.",
    attrs = {
        "launcher": attr.label(
            default = Label("//private:launcher.py"),
            allow_single_file = True,
            executable = False,
            doc = "The Python launcher script.",
        ),
        "test_binary": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "The inner test binary to exec after the cluster is ready.",
        ),
        "worker": attr.label(
            mandatory = True,
            providers = [TemporalWorkerInfo],
            doc = "A temporal_build target.",
        ),
    },
)

# ---------------------------------------------------------------------------
# temporal_test macro
# ---------------------------------------------------------------------------

def temporal_test(
        name,
        worker,
        srcs = None,
        deps = None,
        size = "medium",
        timeout = None,
        tags = None,
        test_rule = None,
        **kwargs):
    """Macro: runs a test against an ephemeral Temporal cluster.

    Wraps any *_test rule (default: sh_test) with a launcher that:
      1. Starts temporal server start-dev on a free port
      2. Creates a unique, isolated namespace for this test run
      3. Starts the declared worker binary
      4. Waits until the worker is polling the task queue
      5. Validates declared workflow/activity types match the running worker
      6. Exports TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE, TEMPORAL_TASK_QUEUE
      7. exec's the wrapped test binary
      8. Tears down the worker and server on exit

    Args:
        name:        Target name.
        worker:      Label of a temporal_build target (required).
        srcs:        Test source files (forwarded to test_rule).
        deps:        Test dependencies (forwarded to test_rule).
        size:        Bazel test size. Default "medium".
        timeout:     Bazel test timeout override.
        tags:        Extra tags.
        test_rule:   The *_test rule for the inner test binary.
                     Defaults to native.sh_test.
        **kwargs:    Remaining kwargs forwarded to test_rule.
    """
    srcs  = srcs  or []
    deps  = deps  or []
    tags  = tags  or []
    _test_rule = test_rule or native.sh_test

    # 1. Build the inner test binary (no Temporal awareness).
    inner_name = name + "_inner"
    _test_rule(
        name  = inner_name,
        srcs  = srcs,
        deps  = deps,
        tags  = tags + ["manual"],
        **kwargs
    )

    # 2. Wrap it with the Temporal launcher.
    _temporal_launcher_test(
        name        = name,
        worker      = worker,
        test_binary = ":" + inner_name,
        size        = size,
        timeout     = timeout,
        tags        = tags,
    )
