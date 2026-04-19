"temporal_namespace_config rule and TemporalNamespaceConfigInfo provider."

load("//private:worker.bzl", "TemporalWorkerInfo")

_VALID_SEARCH_ATTRIBUTE_TYPES = [
    "Bool",
    "Datetime",
    "Double",
    "Int",
    "Keyword",
    "KeywordList",
    "Text",
]

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

TemporalNamespaceConfigInfo = provider(
    doc = """\
Carries custom search attribute declarations for a Temporal namespace.
Produced by temporal_namespace_config; consumed by temporal_test.
""",
    fields = {
        "search_attributes": "dict mapping search attribute name → type string.",
        "worker_info":       "TemporalWorkerInfo: the worker this config is associated with.",
    },
)

# ---------------------------------------------------------------------------
# Rule
# ---------------------------------------------------------------------------

def _temporal_namespace_config_impl(ctx):
    label = str(ctx.label)
    worker_info = ctx.attr.worker[TemporalWorkerInfo]

    # Validate attribute type strings at analysis time.
    for attr_name, attr_type in ctx.attr.search_attributes.items():
        if not attr_name:
            fail("{}: search_attributes contains an empty key.".format(label))
        if attr_type not in _VALID_SEARCH_ATTRIBUTE_TYPES:
            fail(
                "{}: search attribute '{}' has invalid type '{}'. ".format(
                    label, attr_name, attr_type) +
                "Valid types: {}.".format(", ".join(_VALID_SEARCH_ATTRIBUTE_TYPES)),
            )

    return [
        DefaultInfo(files = depset()),
        TemporalNamespaceConfigInfo(
            search_attributes = ctx.attr.search_attributes,
            worker_info       = worker_info,
        ),
    ]

temporal_namespace_config = rule(
    implementation = _temporal_namespace_config_impl,
    doc = """\
Declares custom search attributes to register in the test namespace before
the worker starts.  Validates attribute type strings at Bazel analysis time.

Passed to temporal_test via the namespace_config attribute:

    temporal_namespace_config(
        name = "my_ns_config",
        worker = ":my_worker",
        search_attributes = {
            "CustomerId": "Keyword",
            "OrderTotal":  "Double",
            "IsRetried":   "Bool",
        },
    )

    temporal_test(
        name              = "my_test",
        worker            = ":my_worker",
        namespace_config  = ":my_ns_config",
        srcs              = ["my_test.sh"],
    )

Valid search attribute types:
    Bool, Datetime, Double, Int, Keyword, KeywordList, Text
""",
    attrs = {
        "search_attributes": attr.string_dict(
            mandatory = True,
            doc = "Map of search attribute name → type string.",
        ),
        "worker": attr.label(
            mandatory = True,
            providers = [TemporalWorkerInfo],
            doc = "The temporal_build target this config is associated with.",
        ),
    },
)
