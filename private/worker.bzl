"temporal_build rule and TemporalWorkerInfo provider."

load("//private:binary.bzl", "TemporalBinaryInfo")

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

TemporalWorkerInfo = provider(
    doc = """\
Carries a Temporal worker declaration: the worker executable, its task queue,
and the workflow/activity type names it registers.  Produced by temporal_build
and consumed by the temporal_test launcher.
""",
    fields = {
        "binary_info":     "TemporalBinaryInfo: the Temporal CLI binary.",
        "worker_binary":   "File: the worker executable.",
        "worker_runfiles": "depset: runfiles required by the worker binary.",
        "task_queue":      "string: task queue this worker polls.",
        "workflow_types":  "list of strings: registered workflow type names.",
        "activity_types":  "list of strings: registered activity type names.",
        "workflow_module": "File or None: the .py file containing the workflow classes (used by replay_runner.py for SDK-based history replay).",
        "manifest":        "File: JSON registration manifest (build artifact).",
    },
)

# ---------------------------------------------------------------------------
# Implementation helpers
# ---------------------------------------------------------------------------

def _validate_type_list(name, values, ctx_label):
    """Fail fast if a type-name list has empty strings or duplicates."""
    seen = {}
    for v in values:
        if not v:
            fail("{}: {} contains an empty string. All type names must be non-empty.".format(
                ctx_label, name))
        if v in seen:
            fail("{}: {} contains duplicate type name '{}'. Each name must appear once.".format(
                ctx_label, name, v))
        seen[v] = True

# ---------------------------------------------------------------------------
# Rule
# ---------------------------------------------------------------------------

def _temporal_build_impl(ctx):
    label = str(ctx.label)

    # -- Analysis-time validation --------------------------------------------
    task_queue = ctx.attr.task_queue
    if not task_queue:
        fail("{}: task_queue must be a non-empty string.".format(label))

    workflow_types = ctx.attr.workflow_types
    if not workflow_types:
        fail("{}: workflow_types must be a non-empty list. " +
             "List every workflow type name your worker registers.".format(label))

    activity_types = ctx.attr.activity_types
    _validate_type_list("workflow_types", workflow_types, label)
    _validate_type_list("activity_types", activity_types, label)

    binary_info = ctx.attr.temporal[TemporalBinaryInfo]

    # Worker binary and its runfiles.
    worker_bin = ctx.executable.worker_binary
    worker_rf  = ctx.attr.worker_binary[DefaultInfo].default_runfiles
    worker_runfiles = worker_rf.files if worker_rf else depset()

    # -- Generate registration manifest (build artifact) --------------------
    # Serialise to JSON manually — Starlark has no json.encode in Bazel 6.
    wf_list = "[{}]".format(", ".join(['"{}"'.format(t) for t in workflow_types]))
    ac_list = "[{}]".format(", ".join(['"{}"'.format(t) for t in activity_types]))
    manifest_content = """\
{{
  "workspace":       "{workspace}",
  "temporal_bin":    "{temporal_bin}",
  "worker_binary":   "{worker_bin}",
  "task_queue":      "{task_queue}",
  "workflow_types":  {wf_list},
  "activity_types":  {ac_list}
}}
""".format(
        workspace    = ctx.workspace_name,
        temporal_bin = binary_info.temporal.short_path,
        worker_bin   = worker_bin.short_path,
        task_queue   = task_queue,
        wf_list      = wf_list,
        ac_list      = ac_list,
    )

    manifest = ctx.actions.declare_file(ctx.label.name + "_temporal_manifest.json")
    ctx.actions.write(output = manifest, content = manifest_content)

    all_files = depset(
        [manifest, worker_bin],
        transitive = [binary_info.all_files, worker_runfiles],
    )

    workflow_module = ctx.file.workflow_module if ctx.attr.workflow_module else None
    if workflow_module:
        all_files = depset(
            [manifest, worker_bin, workflow_module],
            transitive = [binary_info.all_files, worker_runfiles],
        )

    return [
        DefaultInfo(files = all_files),
        TemporalWorkerInfo(
            binary_info     = binary_info,
            worker_binary   = worker_bin,
            worker_runfiles = worker_runfiles,
            task_queue      = task_queue,
            workflow_types  = workflow_types,
            activity_types  = activity_types,
            workflow_module = workflow_module,
            manifest        = manifest,
        ),
    ]

temporal_build = rule(
    implementation = _temporal_build_impl,
    doc = """\
Declares a Temporal worker binary with its registered workflow and activity types.

Validates at analysis time that:
  - task_queue is non-empty
  - workflow_types is non-empty (a worker with no workflows is useless)
  - No duplicate names within workflow_types or activity_types
  - No empty strings in either list

Produces a JSON registration manifest consumed by the temporal_test launcher,
which verifies at test time that the running worker's actual pollers match the
declared types.

Example:

    temporal_build(
        name = "my_worker",
        worker_binary = ":my_worker_bin",   # go_binary / py_binary / sh_binary
        task_queue = "my-task-queue",
        workflow_types = ["MyWorkflow", "OtherWorkflow"],
        activity_types = ["FetchData", "StoreResult"],
    )
""",
    attrs = {
        "activity_types": attr.string_list(
            default = [],
            doc = "Activity type names registered by this worker. May be empty.",
        ),
        "task_queue": attr.string(
            mandatory = True,
            doc = "Name of the Temporal task queue this worker polls.",
        ),
        "temporal": attr.label(
            default = Label("//:temporal_default"),
            providers = [TemporalBinaryInfo],
            doc = "temporal_binary target. Defaults to //:temporal_default.",
        ),
        "worker_binary": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "The worker executable (go_binary, py_binary, sh_binary, etc.).",
        ),
        "workflow_module": attr.label(
            allow_single_file = [".py"],
            doc = "Optional. The .py file containing the workflow class " +
                  "definitions (the same names listed in `workflow_types`). " +
                  "When set, `temporal_test(history = ...)` can replay " +
                  "history files via the SDK Replayer — the launcher " +
                  "subprocess-execs `private/replay_runner.py` with this " +
                  "module's path. When unset, `temporal_test(history = ...)` " +
                  "fails fast at runtime; pure `temporal_test` (no " +
                  "`history`) still works without this attribute.",
        ),
        "workflow_types": attr.string_list(
            mandatory = True,
            doc = "Workflow type names registered by this worker. Must be non-empty.",
        ),
    },
)
