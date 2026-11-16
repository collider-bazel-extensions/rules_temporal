"""A workflow module with a third-party import that the built-in runner's
pinned world (@rules_temporal_pypi) doesn't provide (#4 fixture)."""

import rules_temporal_not_a_real_dependency  # noqa: F401
from temporalio import workflow


@workflow.defn
class HelloWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        return name
