#!/usr/bin/env python3
"""replay_runner.py — SDK-based workflow history replay.

Replaces the long-removed `temporal workflow replay --workflow-file` CLI
subcommand. Two ways in:

1. Built-in runner, `//private:replay_runner` (a py_binary on a hermetic
   interpreter with the temporalio pinned in private/requirements_lock.txt,
   #4). The launcher runs it per history file:

       replay_runner <workflow_module_path> <history_file> <class_names>

   `<workflow_module_path>` is the worker's `temporal_build.workflow_module`
   .py file, loaded by path via `importlib.util.spec_from_file_location`, so
   it can import temporalio (and its deps) and the standard library, but no
   other third-party package: the runner's world is @rules_temporal_pypi,
   not the worker's.

2. Consumer-built runner, `temporal_replay_runner(...)` (private/replay.bzl).
   A generated main calls `main_by_name()` with the workflow module's import
   name and class names baked in; argv is the custom-runner contract:

       <runner> <history_file>

   The module is imported by name from the runner's own `deps`, so its
   third-party imports and the temporalio version are the consumer's.

`<class_names>` is a comma-separated list of the workflow classes to register
with the Replayer (temporal_build.workflow_types). The Replayer walks each
event in the history JSON against the loaded workflow code; a
non-determinism error (code vs. recorded history) exits non-zero.
"""

import asyncio
import importlib
import importlib.util
import json
import os
import sys
from pathlib import Path


def _exit(code: int) -> None:
    """Exit without interpreter teardown. Once temporalio's native core has
    started, finalizing it at exit occasionally segfaults (about 1 run in
    60), which turned a replay that had printed OK into a failure. The
    verdict is already decided and written, so flush and leave."""
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


def _die(msg: str, *, hint: str = "") -> None:
    sys.stderr.write(f"[replay_runner] {msg}\n")
    if hint:
        sys.stderr.write(f"[replay_runner] {hint}\n")
    _exit(1)


_THIRD_PARTY_HINT = (
    "The built-in runner only provides temporalio (and its own deps) from "
    "@rules_temporal_pypi: the workflow module is loaded by path, not from "
    "your worker's deps. If it imports other third-party packages, or you "
    "need a different temporalio, build a runner against your deps with "
    "temporal_replay_runner(...) and set it as temporal_build's "
    "`replay_runner` (README \"History replay\")."
)


def _import_temporalio():
    # Imported lazily so a missing SDK gets this message, not a traceback.
    try:
        from temporalio.client import WorkflowHistory
        from temporalio.worker import Replayer
    except ImportError as exc:
        _die(
            f"could not import temporalio: {exc}",
            hint=("Run the replay runner through its Bazel target "
                  "(@rules_temporal//private:replay_runner, or your "
                  "temporal_replay_runner), not as a bare script: the "
                  "pinned temporalio comes from its deps, not from the "
                  "host's pip. A temporal_replay_runner's `deps` must "
                  "include a temporalio."),
        )
    return WorkflowHistory, Replayer


def _temporalio_version() -> str:
    try:
        from importlib.metadata import version
        return version("temporalio")
    except Exception:
        return "(unknown version)"


def _load_workflow_module(path: str):
    """Load a single .py file as a module, by path."""
    p = Path(path)
    if not p.is_file():
        _die(
            f"workflow module not found at {path}",
            hint="Check the `workflow_module` attribute on temporal_build.",
        )
    # Load it under its own name with its directory on sys.path: temporalio's
    # workflow sandbox re-imports the workflow's module by name, which fails
    # for a module that only exists in this process's sys.modules
    # ("No module named 'user_workflow'" in temporalio >= 1.2x).
    sys.path.insert(0, str(p.parent.resolve()))
    spec = importlib.util.spec_from_file_location(p.stem, str(p))
    if not spec or not spec.loader:
        _die(f"could not build import spec for {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[p.stem] = mod
    try:
        spec.loader.exec_module(mod)
    except ImportError as exc:
        _die(
            f"failed to import {path}: {type(exc).__name__}: {exc}",
            hint=("Package-relative imports don't resolve for a module "
                  "loaded by path. " + _THIRD_PARTY_HINT),
        )
    except Exception as exc:
        _die(f"failed to import {path}: {type(exc).__name__}: {exc}")
    return mod


def _import_workflow_module(name: str):
    """Import the workflow module by its import name (consumer-built runner)."""
    try:
        return importlib.import_module(name)
    except ImportError as exc:
        _die(
            f"failed to import workflow module {name!r}: "
            f"{type(exc).__name__}: {exc}",
            hint=("Check temporal_replay_runner's `workflow_module` (an "
                  "import name like \"pkg.workflows\") and that the "
                  "py_library providing it, and its third-party deps, are "
                  "in `deps`."),
        )
    except Exception as exc:
        _die(f"failed to import workflow module {name!r}: "
             f"{type(exc).__name__}: {exc}")


def _resolve_workflow_classes(mod, names: list) -> list:
    out = []
    for name in names:
        cls = getattr(mod, name, None)
        if cls is None:
            _die(
                f"workflow class {name!r} not defined in module "
                f"{getattr(mod, '__name__', mod)!r}",
                hint=("Check the `workflow_types` list on temporal_build "
                      "(or temporal_replay_runner): every name must be a "
                      "top-level class in the workflow module."),
            )
        out.append(cls)
    return out


_EXPORT_HINT = ("Export histories with `temporal workflow show "
                "--workflow-id <id> -o json > history.json`.")


def _load_history(WorkflowHistory, history_path: str):
    try:
        with open(history_path) as f:
            history_data = json.load(f)
    except FileNotFoundError:
        _die(f"history file not found: {history_path}")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        _die(f"history file {history_path} is not valid JSON: {exc}",
             hint=_EXPORT_HINT)
    try:
        return WorkflowHistory.from_json("replay", history_data)
    except Exception as exc:
        _die(f"history file {history_path} is not a workflow history: "
             f"{type(exc).__name__}: {exc}",
             hint=_EXPORT_HINT)


def _replay(workflows: list, history_path: str) -> None:
    WorkflowHistory, Replayer = _import_temporalio()
    history = _load_history(WorkflowHistory, history_path)
    version = _temporalio_version()
    try:
        asyncio.run(Replayer(workflows=workflows).replay_workflow(history))
    except Exception as exc:
        _die(
            f"replay of {history_path} failed: {type(exc).__name__}: {exc}",
            hint=("The workflow code no longer matches the recorded history "
                  "(non-determinism), or the history belongs to another "
                  f"workflow. Replayed with temporalio {version}."),
        )
    print(f"[replay_runner] OK: {history_path} replayed "
          f"(temporalio {version})", file=sys.stderr)
    _exit(0)


def _class_names(csv: str) -> list:
    names = [n for n in csv.split(",") if n]
    if not names:
        _die("class_names argument is empty: pass at least one workflow "
             "class name")
    return names


def main() -> None:
    """Built-in runner: <workflow_module_path> <history_file> <class_names>."""
    if len(sys.argv) != 4:
        _die("usage: replay_runner <workflow_module_path> <history_file> "
             "<class_names>")
    workflow_module_path, history_file, class_names_csv = sys.argv[1:4]
    class_names = _class_names(class_names_csv)
    _import_temporalio()
    mod = _load_workflow_module(workflow_module_path)
    _replay(_resolve_workflow_classes(mod, class_names), history_file)


def main_by_name(module_name: str, class_names: list) -> None:
    """Consumer-built runner (temporal_replay_runner): <history_file>."""
    if len(sys.argv) != 2:
        _die("usage: <replay runner> <history_file>")
    _import_temporalio()
    mod = _import_workflow_module(module_name)
    _replay(_resolve_workflow_classes(mod, class_names), sys.argv[1])


if __name__ == "__main__":
    main()
