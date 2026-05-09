"""
rules_temporal public API.

Two families of primitives:

  Test-time (v0.1/v0.2 — boots a transient Temporal locally):
    temporal_test, temporal_build, temporal_binary,
    temporal_server, temporal_health_check,
    temporal_namespace_config, temporal_workflow_history

  Install-time (v0.3 — deploys temporal-operator to a real cluster):
    temporal_install, temporal_install_health_check

Load:

    load("@rules_temporal//:defs.bzl",
        # test-time
        "temporal_test", "temporal_build", "temporal_binary",
        "temporal_server", "temporal_health_check",
        "temporal_namespace_config", "temporal_workflow_history",
        "TemporalBinaryInfo", "TemporalWorkerInfo",
        "TemporalNamespaceConfigInfo", "TemporalWorkflowHistoryInfo",
        # install-time
        "temporal_install", "temporal_install_health_check",
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
load("//private:install.bzl",
    _temporal_install              = "temporal_install",
    _temporal_install_health_check = "temporal_install_health_check",
)

# Re-export rules
temporal_binary        = _temporal_binary
temporal_build         = _temporal_build
temporal_test          = _temporal_test
temporal_server        = _temporal_server
temporal_health_check  = _temporal_health_check
temporal_namespace_config    = _temporal_namespace_config
temporal_workflow_history    = _temporal_workflow_history
temporal_install             = _temporal_install
temporal_install_health_check = _temporal_install_health_check

# Re-export providers
TemporalBinaryInfo          = _TemporalBinaryInfo
TemporalWorkerInfo          = _TemporalWorkerInfo
TemporalNamespaceConfigInfo = _TemporalNamespaceConfigInfo
TemporalWorkflowHistoryInfo = _TemporalWorkflowHistoryInfo
