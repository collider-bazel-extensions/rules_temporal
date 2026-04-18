"""
Minimal Temporal worker for rules_temporal smoke tests.

Registers HelloWorkflow (with a GreetActivity) on the task queue declared
by TEMPORAL_TASK_QUEUE.  Reads connection details from env vars injected
by the rules_temporal launcher:

  TEMPORAL_ADDRESS    — gRPC address (host:port)
  TEMPORAL_NAMESPACE  — isolated test namespace
  TEMPORAL_TASK_QUEUE — task queue to poll
"""

import asyncio
import os
import sys

from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.worker import Worker


# ---------------------------------------------------------------------------
# Activity
# ---------------------------------------------------------------------------

@activity.defn
async def greet_activity(name: str) -> str:
    return f"Hello, {name}!"


# ---------------------------------------------------------------------------
# Workflow
# ---------------------------------------------------------------------------

@workflow.defn
class HelloWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        return await workflow.execute_activity(
            greet_activity,
            name,
            schedule_to_close_timeout=__import__("datetime").timedelta(seconds=10),
        )


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
        workflows   = [HelloWorkflow],
        activities  = [greet_activity],
    ):
        print(f"[hello_worker] polling {task_queue!r} in namespace {namespace!r}",
              flush=True)
        # Run until the launcher kills us.
        await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(_main())
