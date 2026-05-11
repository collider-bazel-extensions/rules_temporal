#!/usr/bin/env python3
"""
rules_temporal launcher.

Mode is selected via RULES_TEMPORAL_MODE env var:
  - unset / "test" → start server + worker, exec test binary
  - "server"       → start server only, write env file, block

Manifest env vars:
  - TEMPORAL_MANIFEST       (test mode, set by temporal_test wrapper)
  - RULES_TEMPORAL_MANIFEST (server mode, set by temporal_server wrapper)

Never imported; always exec'd by the wrapper shell script.
"""

import atexit
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _log(msg: str) -> None:
    print(f"[rules_temporal] {msg}", file=sys.stderr, flush=True)


def _find_runfile(rel_path: str, workspace: str = "") -> str:
    """Resolve a runfile path relative to the runfiles root.

    Bazel conventions:
      - External repo:  '../repo_name/path'  →  '<root>/repo_name/path'
      - Workspace file: 'path/to/file'       →  '<root>/<workspace>/path'
    """
    runfiles_dir = os.environ.get("RUNFILES_DIR") or (sys.argv[0] + ".runfiles")

    candidates = []
    if rel_path.startswith("../"):
        candidates.append(os.path.join(runfiles_dir, rel_path[3:]))
    else:
        if workspace:
            candidates.append(os.path.join(runfiles_dir, workspace, rel_path))
        candidates.append(os.path.join(runfiles_dir, rel_path))

    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate

    # Fallback: RUNFILES_MANIFEST_FILE
    manifest_file = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_file and os.path.exists(manifest_file):
        with open(manifest_file) as f:
            for line in f:
                key, _, val = line.strip().partition(" ")
                if key == rel_path or (rel_path.startswith("../") and key == rel_path[3:]):
                    return val

    raise FileNotFoundError(
        f"Runfile not found: {rel_path!r} (tried: {candidates})"
    )


def _ensure_executable(path: str) -> None:
    """Ensure the execute bit is set for the owner."""
    st = os.stat(path)
    if not (st.st_mode & 0o100):
        os.chmod(path, st.st_mode | 0o111)


def _allocate_port() -> tuple[int, socket.socket]:
    """Bind to 0 on loopback to get a free port. Returns (port, open_socket)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    return s.getsockname()[1], s


def _is_port_conflict(log_path: str) -> bool:
    """Return True if the server log indicates a TCP port-binding conflict."""
    if not os.path.exists(log_path):
        return False
    try:
        with open(log_path) as f:
            content = f.read()
    except OSError:
        return False
    return "address already in use" in content.lower() or "bind: address" in content.lower()


def _wait_server_ready(temporal_bin: str, host: str, port: int,
                       timeout: float = 30.0,
                       tmp_dir: str = "") -> None:
    """
    Poll until the Temporal server is accepting gRPC connections.

    Phase 1: TCP connect — fast, just checks the port is open.
    Phase 2: gRPC health check via `temporal operator cluster health`.
    """
    address = f"{host}:{port}"
    env = os.environ.copy()
    if tmp_dir:
        env["HOME"]   = tmp_dir
        env["TMPDIR"] = tmp_dir

    deadline = time.monotonic() + timeout

    # Phase 1: wait for TCP port to open.
    while time.monotonic() < deadline:
        try:
            conn = socket.create_connection((host, port), timeout=1.0)
            conn.close()
            break
        except (OSError, socket.timeout):
            time.sleep(0.2)
    else:
        raise TimeoutError(
            f"Temporal server TCP port {port} did not open within {timeout}s"
        )

    # Phase 2: wait for gRPC to be ready (cluster health).
    while time.monotonic() < deadline:
        result = subprocess.run(
            [temporal_bin, "operator", "cluster", "health",
             "--address", address, "-o", "json"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        if result.returncode == 0:
            return
        time.sleep(0.3)
    raise TimeoutError(
        f"Temporal server gRPC not ready within {timeout}s at {address}"
    )


def _wait_worker_ready(temporal_bin: str, address: str,
                       namespace: str, task_queue: str,
                       timeout: float = 30.0,
                       tmp_dir: str = "") -> list[dict]:
    """
    Poll until the worker has registered pollers on the task queue.

    Returns the list of poller dicts from 'temporal task-queue describe'.
    Raises TimeoutError if no pollers appear within the timeout.
    """
    env = os.environ.copy()
    if tmp_dir:
        env["HOME"]   = tmp_dir
        env["TMPDIR"] = tmp_dir

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            [temporal_bin, "task-queue", "describe",
             "--address", address,
             "--namespace", namespace,
             "--task-queue", task_queue,
             "-o", "json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        if result.returncode == 0:
            try:
                data = json.loads(result.stdout)
                pollers = data.get("pollers", [])
                if pollers:
                    return pollers
            except (json.JSONDecodeError, AttributeError):
                pass
        time.sleep(0.4)
    raise TimeoutError(
        f"Worker not ready within {timeout}s "
        f"(namespace={namespace!r}, task_queue={task_queue!r}). "
        "Check that the worker binary connects to TEMPORAL_ADDRESS and "
        "TEMPORAL_NAMESPACE and registers on TEMPORAL_TASK_QUEUE."
    )


def _validate_registered_types(
        temporal_bin: str, address: str, namespace: str,
        task_queue: str, declared_workflows: list[str],
        declared_activities: list[str], tmp_dir: str = "") -> None:
    """
    Query the server for registered workflow/activity types on this task queue
    and fail fast if they do not match the declared types.
    """
    env = os.environ.copy()
    if tmp_dir:
        env["HOME"]   = tmp_dir
        env["TMPDIR"] = tmp_dir
    result = subprocess.run(
        [temporal_bin, "task-queue", "describe",
         "--address", address,
         "--namespace", namespace,
         "--task-queue", task_queue,
         "-o", "json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if result.returncode != 0:
        _log("Warning: could not query task queue for type validation — skipping.")
        return

    try:
        data = json.loads(result.stdout)
        versions_by_type = data.get("versioningInfo", {}).get("typeInfoByType", {})
        if not versions_by_type:
            return

        registered_workflows  = set(versions_by_type.get("WORKFLOW", {}).keys())
        registered_activities = set(versions_by_type.get("ACTIVITY", {}).keys())
        declared_wf_set       = set(declared_workflows)
        declared_ac_set       = set(declared_activities)

        missing_wf = declared_wf_set - registered_workflows
        missing_ac = declared_ac_set - registered_activities

        errors = []
        if missing_wf:
            errors.append(
                "Workflow types declared in temporal_build but NOT registered "
                f"by the running worker: {sorted(missing_wf)}"
            )
        if missing_ac:
            errors.append(
                "Activity types declared in temporal_build but NOT registered "
                f"by the running worker: {sorted(missing_ac)}"
            )
        if errors:
            raise RuntimeError(
                "Worker registration mismatch — fail fast:\n" +
                "\n".join(f"  - {e}" for e in errors) +
                "\nFix: ensure temporal_build workflow_types/activity_types "
                "match what the worker binary registers."
            )
    except (json.JSONDecodeError, AttributeError, KeyError):
        _log("Warning: could not parse task queue response for type validation — skipping.")


def _search_attribute_flags(search_attributes: dict) -> list[str]:
    """Return --search-attribute flags for temporal server start-dev.

    In Temporal server 1.24+, custom search attributes must be registered
    at server startup via 'temporal server start-dev --search-attribute'.
    The post-startup 'temporal operator search-attribute create' command
    creates cluster-level attributes that are not mapped to namespaces in
    this server version.
    """
    flags = []
    for name, attr_type in search_attributes.items():
        flags += ["--search-attribute", f"{name}={attr_type}"]
    return flags


def _replay_histories(replay_runner: str,
                       workflow_module: str,
                       workflow_types: list[str],
                       history_files: list[str],
                       tmp_dir: str = "") -> None:
    """Replay committed workflow history files via the SDK Replayer.

    Invokes `private/replay_runner.py` once per history file as a
    subprocess. The CLI `temporal workflow replay --workflow-file`
    subcommand was removed upstream — replay is now SDK-only — so the
    runner dynamic-loads the worker's `workflow_module` (a .py file)
    and calls `temporalio.worker.Replayer.replay_workflow` against
    each history JSON.
    """
    if not history_files:
        return
    if not workflow_module:
        raise RuntimeError(
            "history replay requires the `workflow_module` attribute on "
            "temporal_build. Set it to the .py file containing your "
            "workflow class definitions (the same names listed in "
            "`workflow_types`)."
        )
    env = os.environ.copy()
    if tmp_dir:
        env["HOME"]   = tmp_dir
        env["TMPDIR"] = tmp_dir
    class_names_csv = ",".join(workflow_types)
    for history_file in history_files:
        _log(f"Replaying workflow history: {history_file}")
        result = subprocess.run(
            ["python3", replay_runner,
             workflow_module, history_file, class_names_csv],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        if result.returncode != 0:
            out = result.stdout.decode("utf-8", errors="replace")
            err = result.stderr.decode("utf-8", errors="replace")
            raise RuntimeError(
                f"Workflow history replay failed for {history_file}:\n"
                f"stdout:\n{out}\nstderr:\n{err}"
            )


def _start_server(temporal_bin: str, namespace: str,
                   test_tmpdir: str,
                   search_attributes = None) -> tuple:
    """Allocate a free port, start temporal server start-dev, wait until ready.

    The --namespace flag passed to start-dev auto-creates the namespace, so no
    separate _create_namespace call is needed.

    Custom search attributes are registered at startup via --search-attribute
    flags (required in Temporal server 1.24+; post-startup create commands
    create cluster-level attributes that are not namespace-scoped).

    Returns (server_proc, address).
    """
    host        = "127.0.0.1"
    port, reserved_sock = _allocate_port()
    server_log  = os.path.join(test_tmpdir, "temporal_server.log")
    address     = f"{host}:{port}"
    max_attempts = 5
    _proc_holder = [None]   # mutable so the atexit closure sees updates
    sa_flags = _search_attribute_flags(search_attributes or {})

    def _stop_server() -> None:
        proc = _proc_holder[0]
        if proc is not None and proc.poll() is None:
            _log("Stopping Temporal server …")
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

    atexit.register(_stop_server)

    for attempt in range(1, max_attempts + 1):
        reserved_sock.close()
        try:
            _log(f"Starting Temporal server on {address} (attempt {attempt})")
            cmd = [
                temporal_bin, "server", "start-dev",
                "--port",      str(port),
                "--headless",
                "--ip",        host,
                "--namespace", namespace,
            ] + sa_flags
            with open(server_log, "w") as log_f:
                proc = subprocess.Popen(cmd, stdout=log_f, stderr=log_f)
            _proc_holder[0] = proc
            _wait_server_ready(temporal_bin, host, port, tmp_dir=test_tmpdir)
            _log("Temporal server ready.")
            return proc, address
        except (subprocess.SubprocessError, TimeoutError) as exc:
            _log(f"Attempt {attempt} failed: {exc}")

            log_content = ""
            if os.path.exists(server_log):
                with open(server_log) as lf:
                    log_content = lf.read()

            if attempt == max_attempts:
                if log_content:
                    _log("Server log:\n" + log_content)
                sys.exit(1)

            # Only retry on port conflicts; fail immediately for all other errors.
            if log_content and not _is_port_conflict(server_log):
                _log("Non-retriable server error. Log:\n" + log_content)
                sys.exit(1)

            port, reserved_sock = _allocate_port()
            address = f"{host}:{port}"
            _proc_holder[0] = None

    sys.exit(1)  # unreachable


# ---------------------------------------------------------------------------
# Mode: test
# ---------------------------------------------------------------------------

def main_test(m: dict, workspace: str) -> None:
    temporal_bin   = _find_runfile(m["temporal_bin"],  workspace)
    worker_bin     = _find_runfile(m["worker_binary"], workspace)
    task_queue     = m["task_queue"]
    workflow_types = m.get("workflow_types", [])
    activity_types = m.get("activity_types", [])
    search_attrs   = m.get("search_attributes", {})
    history_files  = [_find_runfile(p, workspace) for p in m.get("history_files", [])]
    workflow_module_rel = m.get("workflow_module", "")
    workflow_module = _find_runfile(workflow_module_rel, workspace) if workflow_module_rel else ""
    replay_runner_rel = m.get("replay_runner", "")
    replay_runner = _find_runfile(replay_runner_rel, workspace) if replay_runner_rel else ""

    _ensure_executable(temporal_bin)
    _ensure_executable(worker_bin)

    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp(prefix="rules_temporal_")
    namespace   = f"temporal-test-{uuid.uuid4().hex[:12]}"
    worker_log  = os.path.join(test_tmpdir, "temporal_worker.log")

    _log(f"Namespace: {namespace}")
    if search_attrs:
        _log(f"Custom search attributes: {list(search_attrs.keys())}")

    # Start Temporal dev server.
    # --namespace auto-creates the namespace; no separate create call needed.
    # Search attributes are registered at server startup via --search-attribute
    # flags (required for Temporal server 1.24+).
    _server_proc, address = _start_server(
        temporal_bin, namespace, test_tmpdir,
        search_attributes=search_attrs,
    )

    # -- Start worker --------------------------------------------------------
    worker_env = os.environ.copy()
    worker_env["TEMPORAL_ADDRESS"]    = address
    worker_env["TEMPORAL_NAMESPACE"]  = namespace
    worker_env["TEMPORAL_TASK_QUEUE"] = task_queue
    # NOTE: do NOT override HOME/TMPDIR in the worker env.  The worker process
    # needs its original HOME to find user-installed Python packages such as
    # temporalio.  HOME/TMPDIR overrides are only applied to Temporal CLI
    # subprocess calls (via tmp_dir= in the helper functions above).

    _log(f"Starting worker: {os.path.basename(worker_bin)}")
    with open(worker_log, "w") as wlog_f:
        worker_proc = subprocess.Popen(
            [worker_bin],
            env    = worker_env,
            stdout = wlog_f,
            stderr = wlog_f,
        )

    def _stop_worker() -> None:
        if worker_proc.poll() is None:
            _log("Stopping worker …")
            worker_proc.terminate()
            try:
                worker_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker_proc.kill()

    atexit.register(_stop_worker)

    # -- Wait for worker pollers ---------------------------------------------
    try:
        _log(f"Waiting for worker to poll task queue '{task_queue}' …")
        _wait_worker_ready(temporal_bin, address, namespace, task_queue,
                           tmp_dir=test_tmpdir)
        _log("Worker ready.")
    except TimeoutError as exc:
        if os.path.exists(worker_log):
            with open(worker_log) as wlf:
                _log("Worker log:\n" + wlf.read())
        _log(str(exc))
        sys.exit(1)

    # Check worker exited unexpectedly before becoming ready.
    if worker_proc.poll() is not None:
        if os.path.exists(worker_log):
            with open(worker_log) as wlf:
                _log("Worker log:\n" + wlf.read())
        _log(f"Worker exited with code {worker_proc.returncode} before test started.")
        sys.exit(1)

    # -- Validate registered types -------------------------------------------
    _validate_registered_types(
        temporal_bin, address, namespace, task_queue,
        workflow_types, activity_types,
        tmp_dir=test_tmpdir,
    )

    # -- Replay committed workflow histories (if any) ------------------------
    if history_files:
        _log(f"Replaying {len(history_files)} workflow history file(s) …")
        try:
            _replay_histories(replay_runner, workflow_module,
                              workflow_types, history_files,
                              tmp_dir=test_tmpdir)
        except RuntimeError as exc:
            _log(str(exc))
            sys.exit(1)
        _log("All history replays succeeded.")

    # -- Exec test binary ----------------------------------------------------
    test_binary = os.environ.get("TEMPORAL_TEST_BINARY")
    if not test_binary:
        sys.exit("[rules_temporal] TEMPORAL_TEST_BINARY not set")
    if not os.path.isabs(test_binary):
        test_binary = _find_runfile(test_binary, workspace)

    env = os.environ.copy()
    env["TEMPORAL_ADDRESS"]    = address
    env["TEMPORAL_NAMESPACE"]  = namespace
    env["TEMPORAL_TASK_QUEUE"] = task_queue
    # Expose the resolved replay-runner + workflow-module paths so test
    # scripts that capture a history at runtime can invoke replay
    # themselves (no need to re-resolve the launcher's runfiles).
    if replay_runner:
        env["TEMPORAL_REPLAY_RUNNER"] = replay_runner
    if workflow_module:
        env["TEMPORAL_WORKFLOW_MODULE"] = workflow_module
    if workflow_types:
        env["TEMPORAL_WORKFLOW_TYPES"] = ",".join(workflow_types)
    # Ensure HOME and TMPDIR are set so the Temporal CLI (used by the test
    # script) can find its config dirs inside the Bazel sandbox.
    if test_tmpdir:
        env.setdefault("HOME",   test_tmpdir)
        env.setdefault("TMPDIR", test_tmpdir)

    _log(f"Executing test binary: {test_binary}")
    os.execve(test_binary, [test_binary] + sys.argv[1:], env)


# ---------------------------------------------------------------------------
# Mode: server
# ---------------------------------------------------------------------------

def main_server(m: dict, workspace: str) -> None:
    temporal_bin = _find_runfile(m["temporal_bin"], workspace)
    _ensure_executable(temporal_bin)

    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp(prefix="rules_temporal_")
    namespace   = f"temporal-test-{uuid.uuid4().hex[:12]}"

    _log(f"Namespace: {namespace}")

    # Start Temporal dev server.
    # --namespace auto-creates the namespace; no separate create call needed.
    _server_proc, address = _start_server(temporal_bin, namespace, test_tmpdir)

    # Write env file atomically once server is ready.
    env_file = os.environ.get("RULES_TEMPORAL_OUTPUT_ENV_FILE")
    if not env_file:
        sys.exit("[rules_temporal] RULES_TEMPORAL_OUTPUT_ENV_FILE not set in server mode")

    env_content = (
        f"TEMPORAL_ADDRESS={address}\n"
        f"TEMPORAL_NAMESPACE={namespace}\n"
    )
    tmp_path = env_file + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(env_content)
    os.replace(tmp_path, env_file)
    _log(f"Wrote server env file: {env_file}")

    # Handle SIGTERM (rules_itest) and SIGINT (Ctrl-C / bazel run).
    def _handle_signal(signum: int, frame: object) -> None:
        _log(f"Received signal {signum}; shutting down.")
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT,  _handle_signal)

    _log("Server ready. Blocking until SIGTERM/SIGINT …")
    signal.pause()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    mode = os.environ.get("RULES_TEMPORAL_MODE", "test")

    if mode == "server":
        manifest_path = os.environ.get("RULES_TEMPORAL_MANIFEST")
        if not manifest_path:
            sys.exit("[rules_temporal] RULES_TEMPORAL_MANIFEST not set")
    else:
        manifest_path = os.environ.get("TEMPORAL_MANIFEST")
        if not manifest_path:
            sys.exit("[rules_temporal] TEMPORAL_MANIFEST not set")

    with open(manifest_path) as f:
        m = json.load(f)

    workspace = m.get("workspace", "")

    if mode == "server":
        main_server(m, workspace)
    else:
        main_test(m, workspace)


if __name__ == "__main__":
    main()
