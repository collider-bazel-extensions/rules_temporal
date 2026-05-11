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
    # falls back to `python3 private/replay_runner.py <module> <history>
    # <classes>`.
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
  "history_files":         {history_files}
}}
""".format(
        workspace            = _json_str(workspace),
        temporal_bin         = _json_str(worker_info.binary_info.temporal.short_path),
        worker_binary        = _json_str(worker_info.worker_binary.short_path),
        task_queue           = _json_str(worker_info.task_queue),
        workflow_types       = _json_str_list(worker_info.workflow_types),
        activity_types       = _json_str_list(worker_info.activity_types),
        workflow_module      = _json_str(workflow_module_path),
        replay_runner        = _json_str(ctx.file.replay_runner.short_path),
        custom_replay_runner = _json_str(custom_replay_runner_path),
        search_attributes    = _json_str_dict(search_attrs),
        history_files        = _json_str_list(history_files),
    )

    manifest = ctx.actions.declare_file(ctx.label.name + "_test_manifest.json")
    ctx.actions.write(output = manifest, content = manifest_content)

    # Collect all files the launcher needs at runtime.
    files = [ctx.file.launcher, ctx.file.replay_runner, manifest]
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
    ])

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
        "replay_runner": attr.label(
            default = Label("//private:replay_runner.py"),
            allow_single_file = True,
            executable = False,
            doc = "The SDK-based replay shim. Invoked by the launcher when " +
                  "the consumer attaches a temporal_workflow_history.",
        ),
        "namespace_config": attr.label(
            default   = None,
            providers = [TemporalNamespaceConfigInfo],
            doc = "Optional temporal_namespace_config target for custom search attributes.",
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

    # 2. Wrap it with the Temporal launcher.
    _temporal_launcher_test(
        name             = name,
        worker           = worker,
        test_binary      = ":" + inner_name,
        size             = size,
        timeout          = timeout,
        tags             = tags,
        namespace_config = namespace_config,
        history          = history,
    )
