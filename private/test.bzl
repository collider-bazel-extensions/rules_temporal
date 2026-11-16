"temporal_test macro and _temporal_launcher_test rule."

load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//private:binary.bzl", "TemporalBinaryInfo")
load("//private:worker.bzl", "TemporalWorkerInfo")
load("//private:namespace_config.bzl", "TemporalNamespaceConfigInfo")
load("//private:history.bzl", "TemporalWorkflowHistoryInfo")

# ---------------------------------------------------------------------------
# JSON serialization helpers (no json.encode in Bazel < 6)
# ---------------------------------------------------------------------------

def _json_str(s):
    """Serialize a string as a JSON string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def _json_str_list(lst):
    """Serialize a list of strings as a JSON array."""
    return "[" + ", ".join([_json_str(s) for s in lst]) + "]"

def _json_str_dict(d):
    """Serialize a dict of string→string as a JSON object."""
    return "{" + ", ".join([_json_str(k) + ": " + _json_str(v) for k, v in d.items()]) + "}"

def ready_timeout_seconds(label, attr_name, value):
    """Validate a readiness timeout attribute: a positive number of seconds.

    Returned as written (e.g. "180", "2.5"); the launcher parses it.
    """
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: {} = {}: expected a positive number of seconds.".format(
            label, attr_name, repr(value)))
    return raw

# ---------------------------------------------------------------------------
# Internal rule: launcher + runfiles assembly
# ---------------------------------------------------------------------------

def _temporal_launcher_impl(ctx):
    worker_info = ctx.attr.worker[TemporalWorkerInfo]
    workspace   = ctx.workspace_name

    # Collect optional namespace config.
    search_attrs = {}
    if ctx.attr.namespace_config:
        ns_info      = ctx.attr.namespace_config[TemporalNamespaceConfigInfo]
        search_attrs = ns_info.search_attributes

    # Collect optional workflow history files.
    history_files    = []
    history_runfiles = ctx.runfiles()
    if ctx.attr.history:
        hist_info     = ctx.attr.history[TemporalWorkflowHistoryInfo]
        history_files = [f.short_path for f in hist_info.history_files.to_list()]
        history_runfiles = ctx.runfiles(transitive_files = hist_info.history_files)

    # Generate a combined manifest for this specific test target.
    # This lets the launcher pick up search_attributes, history_files,
    # and the workflow_module / custom_replay_runner paths without
    # touching the temporal_build manifest.
    workflow_module_path = (
        worker_info.workflow_module.short_path
        if worker_info.workflow_module else ""
    )
    # custom_replay_runner takes precedence over the built-in Python
    # path. If set, the launcher subprocess-execs it as
    # `<custom_replay_runner> <history_file>`. If unset, the launcher
    # falls back to the built-in py_binary (#4):
    # `<replay_runner> <module> <history> <classes>`.
    #
    # The built-in runner is only a dependency when the macro attached it
    # (history set, or builtin_replay_runner = True): analysing it fetches
    # the hermetic interpreter and the pinned wheels, which a test that
    # never replays must not pay for.
    builtin_runner = ctx.attr.builtin_replay_runner
    builtin_runner_path = (
        builtin_runner[DefaultInfo].files_to_run.executable.short_path
        if builtin_runner else ""
    )
    custom_replay_runner_path = (
        worker_info.replay_runner.short_path
        if worker_info.replay_runner else ""
    )
    manifest_content = """\
{{
  "workspace":             {workspace},
  "temporal_bin":          {temporal_bin},
  "worker_binary":         {worker_binary},
  "task_queue":            {task_queue},
  "workflow_types":        {workflow_types},
  "activity_types":        {activity_types},
  "workflow_module":       {workflow_module},
  "replay_runner":         {replay_runner},
  "custom_replay_runner":  {custom_replay_runner},
  "search_attributes":     {search_attributes},
  "history_files":         {history_files},
  "worker_ready_timeout":  {worker_ready_timeout},
  "server_ready_timeout":  {server_ready_timeout}
}}
""".format(
        workspace            = _json_str(workspace),
        temporal_bin         = _json_str(worker_info.binary_info.temporal.short_path),
        worker_binary        = _json_str(worker_info.worker_binary.short_path),
        task_queue           = _json_str(worker_info.task_queue),
        workflow_types       = _json_str_list(worker_info.workflow_types),
        activity_types       = _json_str_list(worker_info.activity_types),
        workflow_module      = _json_str(workflow_module_path),
        replay_runner        = _json_str(builtin_runner_path),
        custom_replay_runner = _json_str(custom_replay_runner_path),
        search_attributes    = _json_str_dict(search_attrs),
        history_files        = _json_str_list(history_files),
        worker_ready_timeout = _json_str(ready_timeout_seconds(
            ctx.label, "worker_ready_timeout", ctx.attr.worker_ready_timeout)),
        server_ready_timeout = _json_str(ready_timeout_seconds(
            ctx.label, "server_ready_timeout", ctx.attr.server_ready_timeout)),
    )

    manifest = ctx.actions.declare_file(ctx.label.name + "_test_manifest.json")
    ctx.actions.write(output = manifest, content = manifest_content)

    # Collect all files the launcher needs at runtime.
    files = [ctx.file.launcher, manifest]
    if worker_info.workflow_module:
        files.append(worker_info.workflow_module)
    if worker_info.replay_runner:
        files.append(worker_info.replay_runner)
    runfiles = ctx.runfiles(
        files            = files,
        transitive_files = worker_info.binary_info.all_files,
    ).merge_all([
        ctx.runfiles(transitive_files = worker_info.worker_runfiles),
        ctx.runfiles(transitive_files = worker_info.replay_runner_runfiles),
        ctx.attr.test_binary.default_runfiles,
        history_runfiles,
    ] + ([builtin_runner[DefaultInfo].default_runfiles] if builtin_runner else []))

    # Wrapper script: sets env vars and execs the launcher.
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
            manifest  = manifest.short_path,
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
        "history": attr.label(
            default   = None,
            providers = [TemporalWorkflowHistoryInfo],
            doc = "Optional temporal_workflow_history target for pre-committed history replay.",
        ),
        "launcher": attr.label(
            default = Label("//private:launcher.py"),
            allow_single_file = True,
            executable = False,
            doc = "The Python launcher script.",
        ),
        "builtin_replay_runner": attr.label(
            default = None,
            executable = True,
            cfg = "target",
            doc = "The built-in SDK replay runner (//private:replay_runner), " +
                  "set by the temporal_test macro only when the test " +
                  "replays. Unset: no Python toolchain or wheels are " +
                  "fetched for this test.",
        ),
        "namespace_config": attr.label(
            default   = None,
            providers = [TemporalNamespaceConfigInfo],
            doc = "Optional temporal_namespace_config target for custom search attributes.",
        ),
        "server_ready_timeout": attr.string(
            default = "30",
            doc = "Seconds the launcher waits for the Temporal dev server " +
                  "to accept gRPC connections. A positive number.",
        ),
        "worker_ready_timeout": attr.string(
            default = "30",
            doc = "Seconds the launcher waits for the worker to poll its " +
                  "task queue before failing the test. A positive number.",
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
        namespace_config = None,
        history = None,
        worker_ready_timeout = 30,
        server_ready_timeout = 30,
        builtin_replay_runner = None,
        **kwargs):
    """Macro: runs a test against an ephemeral Temporal cluster.

    Wraps any *_test rule (default: sh_test) with a launcher that:
      1. Starts temporal server start-dev on a free port
      2. Creates a unique, isolated namespace for this test run
      3. Registers custom search attributes (if namespace_config is given)
      4. Starts the declared worker binary
      5. Waits until the worker is polling the task queue
      6. Validates declared workflow/activity types match the running worker
      7. Replays committed workflow histories (if history is given)
      8. Exports TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE, TEMPORAL_TASK_QUEUE
      9. exec's the wrapped test binary
     10. Tears down the worker and server on exit

    Args:
        name:             Target name.
        worker:           Label of a temporal_build target (required).
        srcs:             Test source files (forwarded to test_rule).
        deps:             Test dependencies (forwarded to test_rule).
        size:             Bazel test size. Default "medium".
        timeout:          Bazel test timeout override.
        tags:             Extra tags.
        test_rule:        The *_test rule for the inner test binary.
                          Defaults to native.sh_test.
        namespace_config: Optional label of a temporal_namespace_config target.
        history:          Optional label of a temporal_workflow_history target.
        worker_ready_timeout: Seconds (int, float or string) to wait for the
                          worker to poll its task queue. Default 30. On
                          timeout the test fails naming the task queue.
                          Keep it below the test's own `timeout`.
        server_ready_timeout: Seconds (int, float or string) to wait for the
                          Temporal dev server to become ready. Default 30.
        builtin_replay_runner: Whether to attach the built-in replay runner
                          (hermetic Python + pinned temporalio, #4). None
                          (default): only when `history` is set. True: also
                          without `history`, for a test that captures a
                          history at runtime and runs $TEMPORAL_REPLAY_RUNNER.
                          False: never; for workers whose temporal_build has
                          its own `replay_runner`, so Python and the wheels
                          are not fetched. A worker's `replay_runner` is used
                          over the built-in one either way.
        **kwargs:         Remaining kwargs forwarded to test_rule.
    """
    srcs  = srcs  or []
    deps  = deps  or []
    tags  = tags  or []
    # Bazel 8+ removed `native.sh_test`, so the default has to load
    # from rules_shell. Consumers can override `test_rule = ...` to
    # point at another *_test rule (py_test, go_test, etc.) if they
    # don't want rules_shell as a transitive dep.
    _test_rule = test_rule or sh_test

    # 1. Build the inner test binary (no Temporal awareness).
    inner_name = name + "_inner"
    _test_rule(
        name  = inner_name,
        srcs  = srcs,
        deps  = deps,
        tags  = tags + ["manual"],
        **kwargs
    )

    # 2. Wrap it with the Temporal launcher. The built-in replay runner is
    #    attached only when this test replays (#4): building it fetches a
    #    Python interpreter and the pinned temporalio wheels.
    if builtin_replay_runner == None:
        builtin_replay_runner = history != None
    if builtin_replay_runner not in (True, False):
        fail("temporal_test {}: builtin_replay_runner = {}: expected None, True or False.".format(
            name,
            repr(builtin_replay_runner),
        ))
    _temporal_launcher_test(
        name             = name,
        worker           = worker,
        test_binary      = ":" + inner_name,
        size             = size,
        timeout          = timeout,
        tags             = tags,
        namespace_config = namespace_config,
        history          = history,
        worker_ready_timeout = str(worker_ready_timeout),
        server_ready_timeout = str(server_ready_timeout),
        builtin_replay_runner = Label("//private:replay_runner") if builtin_replay_runner else None,
    )
