#!/usr/bin/env python3
"""replay_runner.py — subprocess-invoked SDK-based workflow history replay.

Replaces the long-removed `temporal workflow replay --workflow-file` CLI
subcommand. Invoked by launcher.py per history file:

    python3 replay_runner.py <workflow_module_path> <history_file> <class_names>

Where `<class_names>` is a comma-separated list of workflow class names
to register with the Replayer (these are the classes declared by the
worker's `temporal_build.workflow_types`).

Dynamic-loads the user's workflow module from its file path via
`importlib.util.spec_from_file_location`. The Replayer then walks each
event in the history JSON against the loaded workflow code; any
non-determinism error (current code-vs-recorded-history divergence)
surfaces as a non-zero exit.

Hermeticity profile: requires system python3 + system-pip-installed
`temporalio`. Same contract `temporal_test`'s launcher already
imposes today (the user's worker .py imports temporalio for the
worker-mode case).
"""

import asyncio
import importlib.util
import json
import sys
from pathlib import Path


def _die(msg: str, *, hint: str = "") -> None:
    sys.stderr.write(f"[replay_runner] {msg}\n")
    if hint:
        sys.stderr.write(f"[replay_runner] {hint}\n")
    sys.exit(1)


def _load_workflow_module(path: str):
    """Dynamic-load a single .py file as a module via importlib.util."""
    p = Path(path)
    if not p.is_file():
        _die(
            f"workflow module not found at {path}",
            hint="Check the `workflow_module` attribute on temporal_build.",
        )
    spec = importlib.util.spec_from_file_location("user_workflow", str(p))
    if not spec or not spec.loader:
        _die(f"could not build import spec for {path}")
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as exc:
        _die(
            f"failed to import {path}: {type(exc).__name__}: {exc}",
            hint=("replay_runner imports the workflow module via "
                  "importlib.util — package-relative imports won't "
                  "resolve. If your worker uses package-shaped imports, "
                  "wire the test's `history` attr to a flat workflow "
                  "module instead, or BYO replay test."),
        )
    return mod


def _resolve_workflow_classes(mod, names: list[str]) -> list:
    out = []
    for name in names:
        cls = getattr(mod, name, None)
        if cls is None:
            _die(
                f"workflow class {name!r} not defined in module",
                hint=("Check the `workflow_types` list on temporal_build "
                      "— every name must be a top-level class in the "
                      "`workflow_module`."),
            )
        out.append(cls)
    return out


async def _replay(workflows: list, history_path: str) -> None:
    # Import temporalio lazily so the early "module not found" path
    # gives a clearer error than the importlib chain would otherwise.
    try:
        from temporalio.client import WorkflowHistory
        from temporalio.worker import Replayer
    except ImportError as exc:
        _die(
            f"could not import temporalio: {exc}",
            hint=("replay_runner requires the `temporalio` Python SDK "
                  "installed in the system python3. Run "
                  "`pip install temporalio` (or "
                  "`sudo pip install --break-system-packages temporalio` "
                  "on Debian/Ubuntu / GitHub `ubuntu-latest`)."),
        )

    with open(history_path) as f:
        history_data = json.load(f)
    history = WorkflowHistory.from_json("replay", history_data)
    replayer = Replayer(workflows=workflows)
    await replayer.replay_workflow(history)


def main() -> None:
    if len(sys.argv) != 4:
        _die(
            "usage: replay_runner.py <workflow_module> <history_file> <class_names>",
        )
    workflow_module_path, history_file, class_names_csv = sys.argv[1:4]
    class_names = [n for n in class_names_csv.split(",") if n]
    if not class_names:
        _die("class_names argument is empty — pass at least one workflow class name")

    mod = _load_workflow_module(workflow_module_path)
    workflows = _resolve_workflow_classes(mod, class_names)
    asyncio.run(_replay(workflows, history_file))


if __name__ == "__main__":
    main()
