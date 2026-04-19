# rules_temporal — Design Document

## Goals

`rules_temporal` provides hermetic, parallel-safe Temporal clusters for Bazel test
targets. The design is driven by three constraints:

1. **No CDN downloads required in CI.** Air-gapped and sandboxed build environments
   must work out of the box by pointing at the host-installed Temporal CLI.
2. **Full `--jobs` parallelism.** Each test must own an independent Temporal dev
   server on a unique port with a UUID namespace — no shared state between tests.
3. **Zero test-code changes.** Tests receive standard `TEMPORAL_*` environment
   variables and connect over TCP as if to any Temporal cluster.

---

## High-level architecture

```
MODULE.bazel / WORKSPACE
        │
        ▼
  extensions.bzl / repositories.bzl          ← fetch or symlink Temporal CLI binary
        │
        ▼
  temporal_binary  (private/binary.bzl)       ← platform-agnostic binary target
        │
        ▼
  temporal_build   (private/worker.bzl)       ← validated worker declaration + manifest
        │
        ├──────────────────────────────────────────────┐
        ▼                                              ▼
  temporal_test macro  (private/test.bzl)     temporal_server rule  (private/server.bzl)
    ├── <name>_inner — real test binary         long-running service binary
    └── <name>       — _temporal_launcher_test        │
              │                                        ▼
              └─────────────┐              temporal_health_check rule (private/server.bzl)
                            │                file-exists health probe
                            ▼
                       launcher.py
                    ┌──────┴──────┐
          RULES_TEMPORAL_MODE=test  RULES_TEMPORAL_MODE=server
                    │                    │
              _start_server()      _start_server()
                    │                    │
              _start_worker()      write env file
                    │                    │
              os.execve(test)      signal.pause()
                                   SIGTERM → stop
```

---

## Provider chain

```
TemporalBinaryInfo             path to the temporal CLI binary; all_files depset
  │
  └─► TemporalWorkerInfo       worker executable + runfiles; task_queue; workflow_types;
        │                      activity_types; JSON registration manifest;
        │                      carries a TemporalBinaryInfo
        │
        ├─► TemporalNamespaceConfigInfo   search attribute definitions to register
        │                                 before the worker starts; carries a
        │                                 TemporalWorkerInfo
        │
        └─► TemporalWorkflowHistoryInfo   exported history .json files for replay;
                                          carries a TemporalWorkerInfo
```

`temporal_test` and `temporal_server` both accept a `worker` label; they get the
full binary chain transitively without extra wiring. The optional `namespace_config`
and `history` labels extend the chain when present.

---

## Binary acquisition

Two modes share the same downstream interface (`TemporalBinaryInfo`):

### Downloaded tarballs (`temporal.version()`)

`_temporal_binary_repo` calls `rctx.download_and_extract` to fetch the Temporal CLI
from GitHub releases. A BUILD template is injected that produces
`temporal_binary_files`, making the layout identical to the system mode.
SHA-256 checksums are stored in `_TEMPORAL_VERSIONS`; linux_amd64 values are real;
darwin platform values are placeholders and must be replaced before
`temporal.version()` is used in production.

### System Temporal CLI (`temporal.system()`)

`_temporal_system_binary_repo` symlinks the host-installed `temporal` binary into
an external repo. Auto-detection runs at `bazel fetch` time (not at test time):

1. `command -v temporal` — `PATH` lookup.
2. Common paths: `~/.local/bin`, `/usr/local/bin`, `/usr/bin`, `/opt/homebrew/bin`.

Both modes produce a repo named `temporal_<version>_<platform>` (e.g.,
`temporal_1_6_2_linux_amd64`), so `defs.bzl` can select the right repo with a
single `select()` keyed on platform constraints.

---

## `temporal_build` rule

`temporal_build` operates at **analysis time** — it validates and captures the worker
declaration without running any process. It:

- Validates `task_queue` is non-empty.
- Validates `workflow_types` is non-empty.
- Validates no empty strings or duplicates in either type list.
- Emits a JSON manifest (`<name>_temporal_manifest.json`) containing the workspace
  name, path to the Temporal CLI, path to the worker binary, task queue, and type
  lists.

Failures surface as `bazel build` errors, never as flaky test failures.

---

## `temporal_test` macro

The macro expands into two targets:

- **`<name>_inner`** — the bare test binary built by whatever `test_rule` the
  caller supplies (`sh_test`, `go_test`, `py_test`, …). Tagged `manual` so Bazel
  never runs it directly.
- **`<name>`** — a `_temporal_launcher_test` rule that wraps the inner binary.
  This is the target users put in `bazel test`.

### Launcher lifecycle (test mode)

```
read TEMPORAL_MANIFEST (JSON)
  ↓
resolve runfile paths
  ↓
ensure execute bits on temporal CLI and worker binary
  ↓
allocate TCP port (socket.bind → port 0)
  ↓
generate UUID namespace (temporal-test-<12-hex>)
  ↓
start temporal server start-dev  [retry on port conflict, up to 5 attempts]
  ↓
_wait_server_ready: TCP open → gRPC cluster health (15 s timeout)
  ↓
_create_namespace
  ↓
start worker subprocess (TEMPORAL_* env vars set)
  ↓
_wait_worker_ready: poll task-queue describe until pollers appear
  ↓
_validate_registered_types (silently skipped if CLI doesn't return type info)
  ↓
_replay_histories (if temporal_workflow_history provided)   ← planned
  ↓
os.execve(test_binary, env={TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE, TEMPORAL_TASK_QUEUE})
```

Cleanup is handled by `atexit` handlers for `server_proc` and `worker_proc`.
After `os.execve` the Python process is replaced; `atexit` handlers do not fire.
Bazel removes `$TEST_TMPDIR` after each test run, cleaning up any orphaned processes.

---

## `temporal_server` rule (planned)

`temporal_server` produces a long-running executable for use as an `itest_service`
in `rules_itest` or any service manager that needs to start a Temporal cluster
independently from the test binary.

It uses the **same launcher** (`private/launcher.py`) as `temporal_test` but sets
`RULES_TEMPORAL_MODE=server` in the wrapper script. In server mode the launcher:

```
read RULES_TEMPORAL_MANIFEST (JSON — server manifest, subset of worker manifest)
  ↓
resolve runfile paths
  ↓
ensure execute bit on temporal CLI binary
  ↓
allocate TCP port  [retry on conflict]
  ↓
generate UUID namespace
  ↓
start temporal server start-dev
  ↓
_wait_server_ready: TCP open → gRPC cluster health
  ↓
_create_namespace
  ↓
write $TEST_TMPDIR/<name>.env atomically  ← readiness signal
  ↓
install SIGTERM + SIGINT handlers → server_proc.terminate() + sys.exit(0)
  ↓
signal.pause() loop   ← zero CPU
```

### Server manifest format

The server manifest is a strict subset of the worker manifest — it has no worker
fields (`worker_binary`, `task_queue`, `workflow_types`, `activity_types`):

```json
{
  "workspace":    "<workspace_name>",
  "temporal_bin": "<runfile path to temporal CLI>"
}
```

The wrapper script sets `RULES_TEMPORAL_MANIFEST` (not `TEMPORAL_MANIFEST`) to
avoid collision with the existing test-mode env var. The launcher reads whichever
is set.

### Readiness protocol

`temporal_server` writes connection details to `$TEST_TMPDIR/<name>.env` as the
**last step** of setup, after the server is up and the namespace is created:

```
TEMPORAL_ADDRESS=127.0.0.1:54321
TEMPORAL_NAMESPACE=temporal-test-abc123def456
```

The file is written atomically (written to `<name>.env.tmp` then renamed) so
readers never observe a partial write. Its presence is a reliable proxy for
"the cluster is fully initialised and the namespace is ready for use."

`TEMPORAL_TASK_QUEUE` is intentionally absent — it is worker-specific. A single
`temporal_server` can host multiple workers on different task queues. Each worker
`itest_service` injects its own `TEMPORAL_TASK_QUEUE` from its `temporal_build`
manifest.

### Shutdown

`temporal_server` registers handlers for `SIGTERM` (sent by `rules_itest`'s service
manager after the test) and `SIGINT` (for interactive `bazel run` sessions). Both
handlers call `server_proc.terminate()`, wait for it, then `sys.exit(0)`.
`signal.pause()` is used for the blocking wait, consuming no CPU.

### HOME / TMPDIR sandbox handling

Bazel's linux-sandbox does not inherit `HOME` or `TMPDIR`. The Temporal CLI
requires a writable `HOME` for its config/cache dirs. In server mode, as in test
mode, `HOME` and `TMPDIR` are set to `$TEST_TMPDIR` for all CLI subprocesses
(`_wait_server_ready` passes `tmp_dir=test_tmpdir` to every CLI call). The server
subprocess itself inherits these from `os.environ` before `Popen` is called.

---

## `temporal_health_check` rule (planned)

`temporal_health_check` generates a companion health-check binary for a
`temporal_server` target. When invoked it exits 0 if and only if
`$TEST_TMPDIR/<server-name>.env` exists, and exits non-zero otherwise.
The env file name is derived from `ctx.attr.server.label.name`, the same convention
used by `temporal_server`.

```bash
#!/usr/bin/env bash
set -euo pipefail
env_file="${TEST_TMPDIR}/<server-name>.env"
if [[ -f "$env_file" ]]; then
  exit 0
fi
echo "[rules_temporal] temporal_server env file not yet present: $env_file" >&2
exit 1
```

---

## `rules_itest` integration

`rules_itest` models integration tests as a service manager that starts declared
services in dependency order, runs the test binary, then stops all services.
`temporal_server` and `temporal_health_check` map directly onto the `itest_service`
primitive.

### Worker wiring

In server mode the worker is a separate `itest_service` that depends on
`temporal_server`. The worker binary needs `TEMPORAL_ADDRESS` and
`TEMPORAL_NAMESPACE` at startup; it sources `$TEST_TMPDIR/<server-name>.env`. A
thin wrapper shell script achieves this:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$TEST_TMPDIR/db.env"          # or the appropriate <server-name>.env
export TEMPORAL_TASK_QUEUE="my-task-queue"
exec "$0.runfiles/myapp/worker_bin" "$@"
```

The wrapper is declared as an `sh_binary` with the worker binary in `data`, and
referenced as the `exe` of its `itest_service`.

### Lifecycle under rules_itest

```
rules_itest service manager
  ├── starts :temporal_svc    (temporal_server: allocate port → server start → namespace → write env file)
  │     polls :temporal_health  (exits 0 when $TEST_TMPDIR/temporal_svc.env exists)
  ├── starts :worker_svc      (worker binary wrapper: sources env file → starts worker)
  │     polls worker health    (custom health check or task-queue describe)
  └── runs test binary
        sources $TEST_TMPDIR/temporal_svc.env
        runs workflows, asserts results
  └── sends SIGTERM to all services
        :temporal_svc → server_proc.terminate()
        :worker_svc   → worker process terminated by rules_itest
```

### Example BUILD snippet

```python
load("@rules_temporal//:defs.bzl", "temporal_server", "temporal_health_check")
load("@rules_itest//:itest.bzl", "itest_service", "service_test")

temporal_server(
    name = "temporal_svc",
)

temporal_health_check(
    name = "temporal_health",
    server = ":temporal_svc",
)

itest_service(
    name = "temporal_svc_wrapper",
    exe = ":temporal_svc",
    health_check = ":temporal_health",
)

itest_service(
    name = "worker_svc",
    exe = ":my_worker_wrapper",   # sh_binary that sources the env file
    deps = [":temporal_svc_wrapper"],
)

service_test(
    name = "integration_test",
    test = ":integration_test_bin",
    services = [":temporal_svc_wrapper", ":worker_svc"],
)
```

---

## `temporal_test` vs `temporal_server` — when to use which

| Scenario | Use |
|---|---|
| Unit / integration test for a single workflow or worker | `temporal_test` |
| Multi-service integration test (e.g. HTTP API + worker + Temporal) | `temporal_server` + `itest_service` |
| `bazel test` with full isolation per test target | `temporal_test` |
| `rules_itest` with shared server across multiple services | `temporal_server` |

`temporal_test` is **not** reimplemented on top of `temporal_server`. The two use
cases are orthogonal and the tight server+worker+exec coupling in `temporal_test`
is its key value for single-test scenarios.

---

## Launcher refactor (`private/launcher.py`)

The current `main()` is monolithic. The refactor splits it into named entry points
dispatched by `RULES_TEMPORAL_MODE`:

| Function | Env var value | Behaviour |
|---|---|---|
| `main_test(m)` | `test` (default) | Current behaviour: server → worker → exec test binary |
| `main_server(m)` | `server` | Server only → write env file → `signal.pause()` |
| `main()` | — | Load manifest; dispatch on `RULES_TEMPORAL_MODE` |

`main_test` is the existing `main()` body extracted verbatim. `main_server` shares
all helper functions (`_allocate_port`, `_wait_server_ready`, `_create_namespace`,
`_is_port_conflict`, retry loop) — no duplication.

---

## Port allocation

`_allocate_port()` binds `('127.0.0.1', 0)` to get a free port. The socket is
closed just before `temporal server start-dev` starts. Up to five retries handle the
rare TOCTOU race; only port-binding conflicts trigger a retry (detected by scanning
the server log for "address already in use"). Any other error causes immediate
failure with the full server log printed.

---

## Namespace isolation

Each `temporal_test` or `temporal_server` instance generates a UUID namespace
(`temporal-test-<12 hex chars>`) at runtime. This guarantees:

- No workflow history bleeds between tests even if they use the same task queue name.
- Tests are safe to run in parallel with `--jobs`.

In server mode, the namespace is created once at startup and shared by all consumers
of that server instance for the duration of the test run. This is the correct model
for a shared-server itest scenario.

---

## Analysis-time validation (`temporal_build`)

`temporal_build` validates at Bazel analysis time (not at test run time):

- `task_queue` must be non-empty.
- `workflow_types` must be non-empty.
- No empty strings in `workflow_types` or `activity_types`.
- No duplicate names within either list.

A separate runtime check (`_validate_registered_types`) fires after the worker is
ready and compares declared types against the server's registration data. This check
is silently skipped if the CLI returns no type info (older CLI versions or versioning
disabled).

---

## `temporal_namespace_config` rule (planned)

The `postgres_schema` analogue for Temporal. Custom search attributes are
namespace-level DDL — they must be registered before any workflow can index or
filter on them. Currently a project that needs custom search attributes must
register them inside the test binary or worker startup code, coupling
infrastructure setup to application code.

`temporal_namespace_config` captures this declaration at the Bazel level:

```python
temporal_namespace_config(
    name = "my_namespace_config",
    worker = ":my_worker",
    search_attributes = {
        "CustomerId":  "Keyword",
        "OrderTotal":  "Double",
        "IsRetried":   "Bool",
    },
)

temporal_test(
    name = "my_test",
    namespace_config = ":my_namespace_config",
    ...
)
```

The launcher runs `temporal operator search-attribute create` for each declared
attribute after `_create_namespace` and before starting the worker:

```
_create_namespace()
  ↓
_register_search_attributes()   ← new step
  ↓
start worker subprocess
```

Valid Temporal search attribute types: `Text`, `Keyword`, `Int`, `Double`,
`Bool`, `Datetime`, `KeywordList`.

### Provider

`TemporalNamespaceConfigInfo` carries the attribute map and a reference to the
`TemporalWorkerInfo` it extends. The launcher reads `search_attributes` from the
manifest JSON at test time; the rule validates the type strings at analysis time.

---

## `temporal_workflow_history` rule (planned)

The `pg_seed_data` analogue for Temporal. Temporal supports exporting complete
workflow execution history as JSON via `temporal workflow show -o json`. The CLI
can then **replay** that history against the current worker code to verify
determinism has not been broken:

```
temporal workflow replay --workflow-file history.json
```

This is a core Temporal testing practice for catching non-determinism bugs before
deploying a worker change. `temporal_workflow_history` captures history files as
Bazel artifacts and causes the launcher to replay them after the worker is ready,
failing fast before the test binary runs if any replay fails.

```python
temporal_workflow_history(
    name = "my_history",
    worker = ":my_worker",
    srcs = glob(["testdata/histories/*.json"]),
)

temporal_test(
    name = "my_test",
    history = ":my_history",
    ...
)
```

### Launcher step

```
_wait_worker_ready()
  ↓
_replay_histories(temporal_bin, address, namespace, history_files)
    for each .json file:
        temporal workflow replay --address ... --namespace ... --workflow-file <path>
        fail immediately on non-zero exit, print replay output
  ↓
os.execve(test_binary)
```

Replay failures are deterministic and indicate a backward-compatibility break in
the worker code. The full `temporal workflow replay` output is printed on failure
to identify the exact history event that caused the non-determinism.

### Provider

`TemporalWorkflowHistoryInfo` carries a `depset` of history `.json` files (in
listed order) and a reference to the `TemporalWorkerInfo`. Using a `depset` means
multiple `temporal_workflow_history` targets can be composed without copying lists,
consistent with the `postgres_schema` migration depset pattern.

---

## Smoke test workflow pattern gaps (planned)

The current `hello_test` exercises the simplest possible path: one activity, no
signals, no queries, no child workflows. Projects commonly rely on patterns that
the smoke test does not currently cover. The following additional workflows should
be added to `tests/workers/hello_worker.py` and exercised in `hello_test.sh`:

| Pattern | New workflow / activity | Test assertion |
|---|---|---|
| Multiple workflow types | `EchoWorkflow` (second type in `workflow_types`) | Both types registered; `EchoWorkflow` returns input unchanged |
| Signal handling | `CounterWorkflow` receives `increment` signals | Signal sent via `temporal workflow signal`; query returns updated count |
| Query handling | `CounterWorkflow` responds to `get_count` query | `temporal workflow query` returns correct value while workflow runs |
| Multiple activity types | `MathWorkflow` calls two activities (`add`, `multiply`) | Result matches expected arithmetic |

Adding these to `hello_worker.py` and `hello_test.sh` requires no new rules —
only changes to the test worker and test script. However, the `temporal_build`
declaration in `tests/BUILD.bazel` must list all registered types in
`workflow_types` and `activity_types`, which validates the multi-type registration
path end-to-end.

### Why no timer / sleep tests

Timer-based workflows (`workflow.sleep`) are excluded: `temporal server start-dev`
runs with real wall-clock time and does not support time-skipping. A `sleep(10m)`
workflow would make the test take 10 minutes. The Temporal Python SDK's
`TestWorkflowEnvironment` supports time-skipping but requires in-process test
execution, which is outside the scope of rules_temporal's shell-test model.

---

## New files required

| File | Action | Description |
|---|---|---|
| `private/server.bzl` | New | `temporal_server` rule + `temporal_health_check` rule |
| `private/namespace_config.bzl` | New | `temporal_namespace_config` rule + `TemporalNamespaceConfigInfo` provider |
| `private/history.bzl` | New | `temporal_workflow_history` rule + `TemporalWorkflowHistoryInfo` provider |
| `private/launcher.py` | Modify | Split `main()` → `main_test(m)` + `main_server(m)`; add `RULES_TEMPORAL_MODE` dispatch; add `_register_search_attributes` and `_replay_histories` steps |
| `defs.bzl` | Modify | Re-export `temporal_server`, `temporal_health_check`, `temporal_namespace_config`, `temporal_workflow_history` |
| `tests/temporal_server_test.sh` | New | Start server, wait for env file, gRPC health check, SIGTERM clean exit |
| `tests/temporal_health_check_test.sh` | New | File-absent → non-zero; file-present → zero (no server needed) |
| `tests/workers/hello_worker.py` | Modify | Add `EchoWorkflow`, `CounterWorkflow` (signals + queries), `MathWorkflow` (two activities) |
| `tests/hello_test.sh` | Modify | Exercise signals, queries, multiple workflow types |
| `tests/BUILD.bazel` | Modify | Update `temporal_build` type lists; add server/health-check targets; add history replay test |
| `CLAUDE.md` | Modify | Repo layout, public API, test results table |

---

## Test coverage

| Test target | What it verifies |
|---|---|
| `//tests:hello_test` | End-to-end HelloWorkflow; namespace isolation; signals; queries; multiple workflow types |
| `//tests:temporal_server_test` | `temporal_server` starts, env file appears, gRPC healthy, SIGTERM exits 0 |
| `//tests:temporal_health_check_test` | Health check exits non-zero without env file, 0 with it |
| `//tests:history_replay_test` | `temporal_workflow_history` replays exported history files; fails fast on determinism break |
| `//tests:namespace_config_test` | `temporal_namespace_config` registers custom search attributes before worker start |

---

## Known limitations and non-goals

- **`temporal_test` stays independent.** It is not reimplemented on top of
  `temporal_server`. The tight server+worker+exec coupling is its value.
- **Target name collision.** Two `temporal_server` targets with the same local name
  in different packages write to the same `$TEST_TMPDIR/<name>.env` path. Unique
  target names within a test run are required.
- **Worker wiring is manual.** There is no dedicated `temporal_worker_service` rule.
  Users write a thin wrapper `sh_binary` that sources the env file before starting
  the worker binary. A future `temporal_worker_service` rule could automate this.
- **Windows not supported.** No pre-built binary source for Windows; PRs welcome.
- **darwin tarball checksums are placeholders.** `temporal.version()` cannot be
  used on macOS until real SHA-256 values are pinned in `extensions.bzl`.
- **Shared namespace in server mode.** Unlike `temporal_test` (one namespace per
  test invocation), `temporal_server` creates one namespace for the entire server
  lifetime. All consumers share it. This is intentional for the itest use case but
  means tests sharing a server must not assume a clean namespace.
- **No time-skipping.** `temporal server start-dev` runs on real wall-clock time.
  Timer-based workflows (`workflow.sleep`, cron schedules) are not testable without
  very long test timeouts. Time-skipping requires the Temporal Python SDK's
  `TestWorkflowEnvironment` (in-process), which is outside the scope of
  rules_temporal's shell-test model.
- **`temporal_workflow_history` replay requires the worker to be running.** The
  `temporal workflow replay` command replays history against the worker's registered
  task queue. History files must have been exported from a cluster running the same
  workflow code (or an older compatible version). Histories from incompatible
  versions will fail replay by design.
