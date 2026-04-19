"""
Minimal Temporal worker for rules_temporal smoke tests.

Registers multiple workflows to exercise different patterns:
  - HelloWorkflow:   simple request/response with a single activity
  - EchoWorkflow:    returns its input unchanged (no activity)
  - MathWorkflow:    two activity calls (add + multiply), structured result
  - CounterWorkflow: signal-driven counter with a query handler

Reads connection details from env vars injected by the rules_temporal launcher:

  TEMPORAL_ADDRESS    — gRPC address (host:port)
  TEMPORAL_NAMESPACE  — isolated test namespace
  TEMPORAL_TASK_QUEUE — task queue to poll
"""

import asyncio
import os
import sys
from datetime import timedelta

from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.worker import Worker


# ---------------------------------------------------------------------------
# Activities
# ---------------------------------------------------------------------------

@activity.defn
async def greet_activity(name: str) -> str:
    return f"Hello, {name}!"


@activity.defn
async def add_activity(a: int, b: int) -> int:
    return a + b


@activity.defn
async def multiply_activity(a: int, b: int) -> int:
    return a * b


# ---------------------------------------------------------------------------
# Workflows
# ---------------------------------------------------------------------------

@workflow.defn
class HelloWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        return await workflow.execute_activity(
            greet_activity,
            name,
            schedule_to_close_timeout=timedelta(seconds=10),
        )


@workflow.defn
class EchoWorkflow:
    """Returns its input string unchanged."""
    @workflow.run
    async def run(self, message: str) -> str:
        return message


@workflow.defn
class MathWorkflow:
    """Runs two activities and returns a dict with sum and product."""
    @workflow.run
    async def run(self, a: int, b: int) -> dict:
        total   = await workflow.execute_activity(
            add_activity, args=[a, b],
            schedule_to_close_timeout=timedelta(seconds=10),
        )
        product = await workflow.execute_activity(
            multiply_activity, args=[a, b],
            schedule_to_close_timeout=timedelta(seconds=10),
        )
        return {"sum": total, "product": product}


@workflow.defn
class CounterWorkflow:
    """Signal-driven counter; completes when 'finish' signal is received."""

    def __init__(self) -> None:
        self._count  = 0
        self._done   = False

    @workflow.run
    async def run(self) -> int:
        await workflow.wait_condition(lambda: self._done)
        return self._count

    @workflow.signal
    def increment(self) -> None:
        self._count += 1

    @workflow.signal
    def finish(self) -> None:
        self._done = True

    @workflow.query
    def get_count(self) -> int:
        return self._count


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def _main() -> None:
    address    = os.environ.get("TEMPORAL_ADDRESS")
    namespace  = os.environ.get("TEMPORAL_NAMESPACE")
    task_queue = os.environ.get("TEMPORAL_TASK_QUEUE")

    for var, val in [
        ("TEMPORAL_ADDRESS",    address),
        ("TEMPORAL_NAMESPACE",  namespace),
        ("TEMPORAL_TASK_QUEUE", task_queue),
    ]:
        if not val:
            print(f"[hello_worker] ERROR: ${var} is not set", file=sys.stderr)
            sys.exit(1)

    client = await Client.connect(address, namespace=namespace)
    async with Worker(
        client,
        task_queue  = task_queue,
        workflows   = [HelloWorkflow, EchoWorkflow, MathWorkflow, CounterWorkflow],
        activities  = [greet_activity, add_activity, multiply_activity],
    ):
        print(f"[hello_worker] polling {task_queue!r} in namespace {namespace!r}",
              flush=True)
        # Run until the launcher kills us.
        await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(_main())
