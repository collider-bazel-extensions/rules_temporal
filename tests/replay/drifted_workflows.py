"""hello_worker's workflows, changed in ways that break replay of histories
recorded by tests/workers/hello_worker.py (#4 fixtures):

  - HelloWorkflow starts a timer before its activity: the recorded history
    has the activity first.
  - MathWorkflow runs multiply before add: the recorded history scheduled
    add_activity first.
"""

from datetime import timedelta

from temporalio import activity, workflow


@activity.defn
async def greet_activity(name: str) -> str:
    return f"Hello, {name}!"


@activity.defn
async def add_activity(a: int, b: int) -> int:
    return a + b


@activity.defn
async def multiply_activity(a: int, b: int) -> int:
    return a * b


@workflow.defn
class HelloWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        await workflow.sleep(timedelta(seconds=1))
        return await workflow.execute_activity(
            greet_activity,
            name,
            schedule_to_close_timeout=timedelta(seconds=10),
        )


@workflow.defn
class MathWorkflow:
    @workflow.run
    async def run(self, a: int, b: int) -> dict:
        product = await workflow.execute_activity(
            multiply_activity, args=[a, b],
            schedule_to_close_timeout=timedelta(seconds=10),
        )
        total = await workflow.execute_activity(
            add_activity, args=[a, b],
            schedule_to_close_timeout=timedelta(seconds=10),
        )
        return {"sum": total, "product": product}
