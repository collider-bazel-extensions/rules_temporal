"""
rules_temporal public API.

Load everything you need from this file:

    load("@rules_temporal//:defs.bzl",
        "temporal_test",
        "temporal_build",
        "temporal_binary",
        "temporal_server",
        "temporal_health_check",
        "temporal_namespace_config",
        "temporal_workflow_history",
        "TemporalBinaryInfo",
        "TemporalWorkerInfo",
        "TemporalNamespaceConfigInfo",
        "TemporalWorkflowHistoryInfo",
    )
"""

load("//private:binary.bzl",
    _temporal_binary    = "temporal_binary",
    _TemporalBinaryInfo = "TemporalBinaryInfo",
)
load("//private:worker.bzl",
    _temporal_build     = "temporal_build",
    _TemporalWorkerInfo = "TemporalWorkerInfo",
)
load("//private:test.bzl",
    _temporal_test = "temporal_test",
)
load("//private:server.bzl",
    _temporal_server       = "temporal_server",
    _temporal_health_check = "temporal_health_check",
)
load("//private:namespace_config.bzl",
    _temporal_namespace_config    = "temporal_namespace_config",
    _TemporalNamespaceConfigInfo  = "TemporalNamespaceConfigInfo",
)
load("//private:history.bzl",
    _temporal_workflow_history   = "temporal_workflow_history",
    _TemporalWorkflowHistoryInfo = "TemporalWorkflowHistoryInfo",
)

# Re-export rules
temporal_binary        = _temporal_binary
temporal_build         = _temporal_build
temporal_test          = _temporal_test
temporal_server        = _temporal_server
temporal_health_check  = _temporal_health_check
temporal_namespace_config   = _temporal_namespace_config
temporal_workflow_history   = _temporal_workflow_history

# Re-export providers
TemporalBinaryInfo          = _TemporalBinaryInfo
TemporalWorkerInfo          = _TemporalWorkerInfo
TemporalNamespaceConfigInfo = _TemporalNamespaceConfigInfo
TemporalWorkflowHistoryInfo = _TemporalWorkflowHistoryInfo
