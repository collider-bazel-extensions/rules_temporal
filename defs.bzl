"""
rules_temporal public API.

Load everything you need from this file:

    load("@rules_temporal//:defs.bzl",
        "temporal_test",
        "temporal_build",
        "temporal_binary",
        "TemporalBinaryInfo",
        "TemporalWorkerInfo",
    )
"""

load("//private:binary.bzl",
    _temporal_binary    = "temporal_binary",
    _TemporalBinaryInfo = "TemporalBinaryInfo",
)
load("//private:worker.bzl",
    _temporal_build    = "temporal_build",
    _TemporalWorkerInfo = "TemporalWorkerInfo",
)
load("//private:test.bzl",
    _temporal_test = "temporal_test",
)

# Re-export rules
temporal_binary = _temporal_binary
temporal_build  = _temporal_build
temporal_test   = _temporal_test

# Re-export providers
TemporalBinaryInfo  = _TemporalBinaryInfo
TemporalWorkerInfo  = _TemporalWorkerInfo
