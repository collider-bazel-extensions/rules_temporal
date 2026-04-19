"temporal_workflow_history rule and TemporalWorkflowHistoryInfo provider."

load("//private:worker.bzl", "TemporalWorkerInfo")

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

TemporalWorkflowHistoryInfo = provider(
    doc = """\
Carries exported workflow history files for replay testing.
Produced by temporal_workflow_history; consumed by temporal_test.
""",
    fields = {
        "history_files": "depset of .json workflow history files, in listed order.",
        "worker_info":   "TemporalWorkerInfo: the worker to replay histories against.",
    },
)

# ---------------------------------------------------------------------------
# Rule
# ---------------------------------------------------------------------------

def _temporal_workflow_history_impl(ctx):
    worker_info   = ctx.attr.worker[TemporalWorkerInfo]
    history_files = depset(ctx.files.srcs, order = "preorder")

    return [
        DefaultInfo(files = history_files),
        TemporalWorkflowHistoryInfo(
            history_files = history_files,
            worker_info   = worker_info,
        ),
    ]

temporal_workflow_history = rule(
    implementation = _temporal_workflow_history_impl,
    doc = """\
Declares exported workflow history files to replay against the running worker
before the test binary executes.  Each file is replayed via
'temporal workflow replay'; a non-determinism error causes an immediate failure.

History files are exported from a live cluster via:
    temporal workflow show --workflow-id <id> -o json > history.json

Then committed as test fixtures and referenced here:

    temporal_workflow_history(
        name   = "my_history",
        worker = ":my_worker",
        srcs   = glob(["testdata/histories/*.json"]),
    )

    temporal_test(
        name    = "my_test",
        worker  = ":my_worker",
        history = ":my_history",
        srcs    = ["my_test.sh"],
    )

Files are replayed in the order listed in srcs.  A non-zero exit from
'temporal workflow replay' causes the launcher to fail immediately and print
the full replay output to help identify the non-determinism.
""",
    attrs = {
        "srcs": attr.label_list(
            mandatory  = True,
            allow_files = [".json"],
            doc = ".json workflow history files exported via 'temporal workflow show -o json'.",
        ),
        "worker": attr.label(
            mandatory = True,
            providers = [TemporalWorkerInfo],
            doc = "The temporal_build target whose worker code is replayed against.",
        ),
    },
)
