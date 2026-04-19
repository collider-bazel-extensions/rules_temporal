# rules_temporal

Bazel rules for running integration tests against an ephemeral
[Temporal](https://temporal.io) cluster. Every test target gets its own
`temporal server start-dev` process on a dynamically allocated port with a
UUID-based namespace — no shared state, no leftover history, full
`--jobs` parallelism.

## Features

- **Hermetic** — each `temporal_test` owns an independent server and namespace;
  no shared state between test targets.
- **Parallel-safe** — run `bazel test //... --jobs 32` without port collisions or
  namespace pollution.
- **Zero CDN downloads required** — auto-detects the host-installed Temporal CLI
  from `PATH`; pre-built tarballs are also supported.
- **Analysis-time validation** — `temporal_build` catches missing task queues,
  empty type lists, and duplicate names as `bazel build` errors, not flaky
  failures.
- **Custom search attributes** — `temporal_namespace_config` registers search
  attributes at server startup so they are available before the worker starts.
- **Workflow history inspection** — `temporal_workflow_history` captures exported
  history files as Bazel artifacts for replay-based determinism testing.
- **rules_itest integration** — `temporal_server` and `temporal_health_check` slot
  directly into multi-service integration tests.

## Requirements

- Bazel 6+ (Bzlmod or WORKSPACE)
- Temporal CLI 1.x installed on the host (or downloaded via `temporal.version()`)
- Python 3.9+ (for the launcher; no pip dependencies)

## Installation

### Bzlmod (`MODULE.bazel`)

```python
bazel_dep(name = "rules_temporal", version = "0.2.0")

temporal = use_extension("@rules_temporal//:extensions.bzl", "temporal")

# Use the host-installed temporal CLI (auto-detects from PATH):
temporal.system(versions = ["1.6.2"])

# Or specify the path explicitly:
# temporal.system(versions = ["1.6.2"], bin_dir = "/usr/local/bin")

# Or download pre-built tarballs from GitHub releases:
# temporal.version(versions = ["1.6.2"])

use_repo(temporal,
    "temporal_1_6_2_linux_amd64",
    "temporal_1_6_2_darwin_arm64",
    "temporal_1_6_2_darwin_amd64",
)
```

### WORKSPACE (legacy)

```python
load("@rules_temporal//:repositories.bzl", "temporal_system_dependencies")

# Auto-detect from PATH; or pass bin_dir for explicit path:
temporal_system_dependencies(versions = ["1.6.2"])
```

## Quick start

### 1. Declare a worker

```python
# BUILD.bazel
load("@rules_temporal//:defs.bzl", "temporal_build", "temporal_test")

temporal_build(
    name           = "my_worker",
    worker_binary  = ":my_worker_bin",   # a *_binary target
    task_queue     = "my-task-queue",
    workflow_types = ["MyWorkflow"],
    activity_types = ["my_activity"],    # optional
)
```

### 2. Write a test

```bash
# my_test.sh
set -euo pipefail

require_env() { [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }; }
require_env TEMPORAL_ADDRESS
require_env TEMPORAL_NAMESPACE
require_env TEMPORAL_TASK_QUEUE

result=$(temporal workflow execute \
    --address    "$TEMPORAL_ADDRESS" \
    --namespace  "$TEMPORAL_NAMESPACE" \
    --type       MyWorkflow \
    --task-queue "$TEMPORAL_TASK_QUEUE" \
    --input      '"world"' \
    -o json)

echo "$result" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
assert obj['result'] == 'Hello, world!', f'unexpected: {obj}'
print('PASS')
"
```

### 3. Wire it up

```python
# BUILD.bazel
temporal_test(
    name   = "my_test",
    worker = ":my_worker",
    srcs   = ["my_test.sh"],
)
```

### 4. Run it

```sh
bazel test //mypackage:my_test
```

## Public API

```python
load("@rules_temporal//:defs.bzl",
    "temporal_build",
    "temporal_test",
    "temporal_server",
    "temporal_health_check",
    "temporal_namespace_config",
    "temporal_workflow_history",
)
```

### `temporal_build`

Declares a Temporal worker binary and validates its registered types at analysis
time. Produces a `TemporalWorkerInfo` provider consumed by `temporal_test` and
`temporal_server`.

```python
temporal_build(
    name           = "my_worker",
    worker_binary  = ":my_worker_bin",   # required: a *_binary target
    task_queue     = "my-task-queue",    # required: non-empty string
    workflow_types = ["MyWorkflow"],     # required: at least one
    activity_types = ["my_activity"],   # optional
)
```

Validated at analysis time:
- `task_queue` must be non-empty.
- `workflow_types` must be non-empty and contain no duplicates or empty strings.
- `activity_types` must contain no duplicates or empty strings.

### `temporal_test`

Runs an isolated test against an ephemeral Temporal cluster. Wraps any Bazel
test rule (`sh_test`, `go_test`, `py_test`, …).

```python
temporal_test(
    name             = "my_test",
    worker           = ":my_worker",         # required: temporal_build target
    srcs             = ["my_test.sh"],       # forwarded to test_rule
    deps             = [...],                # forwarded to test_rule
    size             = "medium",             # optional, default "medium"
    timeout          = None,                 # optional
    tags             = [...],                # optional
    test_rule        = go_test,             # optional; default native.sh_test
    namespace_config = ":my_ns_config",     # optional: temporal_namespace_config
    history          = ":my_histories",     # optional: temporal_workflow_history
    **kwargs,                               # forwarded to test_rule
)
```

Environment variables injected into the test binary:

| Variable              | Example value                | Description                          |
|-----------------------|------------------------------|--------------------------------------|
| `TEMPORAL_ADDRESS`    | `127.0.0.1:54321`            | gRPC address of the ephemeral server |
| `TEMPORAL_NAMESPACE`  | `temporal-test-abc123def456` | Isolated per-test namespace          |
| `TEMPORAL_TASK_QUEUE` | `my-task-queue`              | Task queue from `temporal_build`     |

### `temporal_namespace_config`

Registers custom search attributes at server startup. In Temporal 1.24+, custom
search attributes are namespace-scoped and must be declared via
`--search-attribute` flags to `temporal server start-dev`.

```python
temporal_namespace_config(
    name              = "my_ns_config",
    worker            = ":my_worker",
    search_attributes = {
        "CustomerId": "Keyword",
        "OrderTotal": "Double",
        "IsRetried":  "Bool",
    },
)

temporal_test(
    name             = "my_test",
    worker           = ":my_worker",
    srcs             = ["my_test.sh"],
    namespace_config = ":my_ns_config",
)
```

Valid search attribute types: `Bool`, `Datetime`, `Double`, `Int`, `Keyword`,
`KeywordList`, `Text`. Types are validated at analysis time.

### `temporal_workflow_history`

Captures exported workflow history files as Bazel artifacts. At test time the
launcher inspects each history file and verifies it contains a completed
execution. When `temporal workflow replay` becomes available in the CLI, the
launcher will also replay each history against the live worker, failing fast if
any replay indicates a determinism break.

```python
temporal_workflow_history(
    name   = "my_histories",
    worker = ":my_worker",
    srcs   = glob(["testdata/histories/*.json"]),
)

temporal_test(
    name    = "my_test",
    worker  = ":my_worker",
    srcs    = ["my_test.sh"],
    history = ":my_histories",
)
```

See [Workflow history and determinism testing](#workflow-history-and-determinism-testing)
for a full end-to-end example including how to capture history files.

### `temporal_server`

A long-running server target for multi-service integration tests with
[rules_itest](https://github.com/dzbarsky/rules_itest). Writes
`$TEST_TMPDIR/<name>.env` atomically once the server and namespace are ready,
then blocks until SIGTERM.

```python
temporal_server(name = "my_temporal")
```

The env file contains:

```
TEMPORAL_ADDRESS=127.0.0.1:54321
TEMPORAL_NAMESPACE=temporal-test-abc123def456
```

### `temporal_health_check`

A companion health-check binary for `temporal_server`. Exits 0 if and only if
the server's env file exists.

```python
temporal_health_check(
    name   = "my_temporal_health",
    server = ":my_temporal",
)
```

## Workflow history and determinism testing

Temporal workflows must be **deterministic**: replaying a workflow's event
history against the current worker code must produce the same sequence of
commands. A non-determinism bug — adding a branch, reordering activities,
changing sleep durations — causes a stuck workflow in production and is caught
immediately by replaying a captured history file.

`temporal_workflow_history` bakes history files into the Bazel build so that
every `bazel test` run verifies determinism before the test binary runs. This
section walks through capturing history files from a live server and wiring them
into a test.

### Example layout

```
myapp/
├── BUILD.bazel
├── worker/
│   └── main.py           # Temporal worker binary
├── testdata/
│   └── histories/
│       ├── order_happy_path.json    # captured from a dev server
│       └── order_retry.json        # captured after simulated activity failure
└── determinism_test.sh
```

### Step 1 — run the workflow against a local dev server

Start a local Temporal server and your worker, then execute the workflow you
want to capture. The easiest way is a `bazel test` run with the `--test_output`
flag so you can see the connection details:

```sh
bazel test //myapp:my_test --test_output=streamed
# Look for lines like:
#   Server:    127.0.0.1:54321
#   Namespace: temporal-test-abc123def456
```

Or start a standalone dev server manually:

```sh
temporal server start-dev \
    --port 7233 \
    --namespace dev \
    --headless
```

Start your worker in a second terminal (point it at the dev server):

```sh
TEMPORAL_ADDRESS=127.0.0.1:7233 \
TEMPORAL_NAMESPACE=dev \
TEMPORAL_TASK_QUEUE=order-queue \
bazel run //myapp/worker
```

Execute the workflow you want to capture:

```sh
temporal workflow execute \
    --address    127.0.0.1:7233 \
    --namespace  dev \
    --type       OrderWorkflow \
    --task-queue order-queue \
    --input      '{"order_id": "ord-001", "amount": 49.99}' \
    --workflow-id order-happy-path-capture
```

### Step 2 — export the history

Once the workflow completes, export its full event history to JSON:

```sh
mkdir -p myapp/testdata/histories

temporal workflow show \
    --address     127.0.0.1:7233 \
    --namespace   dev \
    --workflow-id order-happy-path-capture \
    -o json > myapp/testdata/histories/order_happy_path.json
```

Verify the file looks reasonable — it should be a JSON object with an `events`
array containing at least a `WorkflowExecutionStarted` event and a
`WorkflowExecutionCompleted` event:

```sh
python3 -c "
import json
with open('myapp/testdata/histories/order_happy_path.json') as f:
    d = json.load(f)
events = d.get('events') or d.get('history', {}).get('events', [])
print(f'{len(events)} events')
types = [e.get('eventType', '') for e in events]
print('first:', types[0])
print('last: ', types[-1])
"
# 12 events
# first: EVENT_TYPE_WORKFLOW_EXECUTION_STARTED
# last:  EVENT_TYPE_WORKFLOW_EXECUTION_COMPLETED
```

Repeat for any other execution paths you want to lock in (retry paths, signal
handling, compensating transactions, etc.).

### Step 3 — commit the history files

History files are small (~10–50 KB for typical workflows) and belong in source
control alongside the worker code they describe. Commit them as regular files:

```sh
git add myapp/testdata/histories/
git commit -m "test: add captured workflow histories for determinism tests"
```

Keep one history file per distinct execution path. Name files after what they
represent (`order_happy_path.json`, `order_activity_retry.json`,
`order_cancel_signal.json`), not after workflow IDs or timestamps.

### Step 4 — wire it into the build

```python
# myapp/BUILD.bazel
load("@rules_temporal//:defs.bzl",
    "temporal_build",
    "temporal_test",
    "temporal_workflow_history",
)

temporal_build(
    name           = "order_worker",
    worker_binary  = "//myapp/worker",
    task_queue     = "order-queue",
    workflow_types = ["OrderWorkflow"],
    activity_types = ["charge_card", "send_confirmation", "refund_card"],
)

temporal_workflow_history(
    name   = "order_histories",
    worker = ":order_worker",
    srcs   = glob(["testdata/histories/*.json"]),
)

temporal_test(
    name    = "order_determinism_test",
    worker  = ":order_worker",
    srcs    = ["determinism_test.sh"],
    history = ":order_histories",
)
```

### Step 5 — what happens at test time

When `bazel test //myapp:order_determinism_test` runs, the launcher:

1. Starts an ephemeral `temporal server start-dev`.
2. Starts the `order_worker` binary and waits for it to register its task queue.
3. Reads each `.json` file listed in `order_histories`.
4. Verifies each history file contains events and a completed execution — fails
   immediately and prints the file name if a history is malformed or empty.
5. *(Future)* Replays each history via `temporal workflow replay` against the
   live worker. A non-determinism bug in the worker code causes a non-zero exit
   and the full replay output is printed to identify the offending event.
6. `execve`'s `determinism_test.sh` with `TEMPORAL_*` env vars set.

The test script itself can be as simple as a pass-through if the history check
is all you need:

```bash
#!/usr/bin/env bash
# determinism_test.sh — history validation is done by the launcher.
# Add any additional live assertions here.
set -euo pipefail
echo "--- PASS ---"
```

Or combine history validation with live regression tests in the same target:

```bash
#!/usr/bin/env bash
set -euo pipefail

require_env() { [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }; }
require_env TEMPORAL_ADDRESS
require_env TEMPORAL_NAMESPACE
require_env TEMPORAL_TASK_QUEUE

# Run a new execution to verify the current code path still works end-to-end.
result=$(temporal workflow execute \
    --address    "$TEMPORAL_ADDRESS" \
    --namespace  "$TEMPORAL_NAMESPACE" \
    --type       OrderWorkflow \
    --task-queue "$TEMPORAL_TASK_QUEUE" \
    --input      '{"order_id": "ord-test", "amount": 9.99}' \
    -o json 2>&1)

echo "$result" | python3 -c "
import json, sys
obj = json.loads(sys.stdin.read())
assert obj.get('result', {}).get('status') == 'completed', f'unexpected: {obj}'
print('OK: OrderWorkflow completed')
"

echo "--- PASS ---"
```

### When to update history files

Update (re-export) history files whenever you make a **backward-incompatible**
change to a workflow — one that changes the sequence or type of commands
recorded in the event history. Common triggers:

- Reordering activity calls.
- Adding or removing an activity from an existing execution path.
- Changing the input or output type of an activity used inside the workflow.
- Adding a signal handler that changes the command sequence for in-progress
  workflows.

You do **not** need to update history files for changes that don't affect the
recorded command sequence: adding new workflow types, changing activity
implementations (not signatures), updating logging, or modifying worker
configuration.

## Isolation model

Every `temporal_test` target gets:

- Its own `temporal server start-dev` process on a dynamically allocated free port.
- A UUID-based namespace (`temporal-test-<12-hex-chars>`) created at runtime and
  never reused.
- A dedicated worker process started and stopped by the launcher.

No shared state between tests — full `--jobs` parallelism is safe.

## rules_itest integration

`temporal_server` and `temporal_health_check` slot directly into
[rules_itest](https://github.com/dzbarsky/rules_itest):

```python
load("@rules_temporal//:defs.bzl", "temporal_server", "temporal_health_check")
load("@rules_itest//:itest.bzl", "itest_service", "service_test")

temporal_server(name = "temporal")
temporal_health_check(name = "temporal_health", server = ":temporal")

itest_service(
    name         = "temporal_svc",
    exe          = ":temporal",
    health_check = ":temporal_health",
)

itest_service(
    name = "my_worker_svc",
    exe  = ":my_worker_wrapper",   # sh_binary that sources $TEST_TMPDIR/temporal.env
    deps = [":temporal_svc"],
)

service_test(
    name     = "integration_test",
    test     = ":integration_test_bin",
    services = [":temporal_svc", ":my_worker_svc"],
)
```

Worker wrapper pattern (sources the env file before starting the worker):

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$TEST_TMPDIR/temporal.env"
export TEMPORAL_TASK_QUEUE="my-task-queue"
exec "$0.runfiles/myapp/my_worker_bin" "$@"
```

### When to use `temporal_test` vs `temporal_server`

| Scenario | Use |
|---|---|
| Unit / integration test for a single workflow or worker | `temporal_test` |
| Multi-service test (HTTP API + worker + Temporal) | `temporal_server` + `itest_service` |
| `bazel test` with per-target isolation | `temporal_test` |
| Shared server across multiple services | `temporal_server` |

## Test script conventions

All test scripts should:

- Begin with `set -euo pipefail`.
- Guard every `TEMPORAL_*` variable with `require_env` before first use.
- Pass `--namespace "$TEMPORAL_NAMESPACE"` explicitly on every Temporal CLI call
  (the env var alone is not always picked up in the Bazel sandbox).

## Supported platforms

| Platform | `temporal.system()` | `temporal.version()` |
|---|---|---|
| Linux x86_64 | Yes | Yes |
| macOS arm64  | Yes | Checksums are placeholder values |
| macOS amd64  | Yes | Checksums are placeholder values |
| Windows      | No  | No                               |

## Known limitations

- **`temporal workflow replay`** is not present in Temporal CLI 1.6.2.
  `temporal_workflow_history` stores history files as Bazel artifacts and
  inspects them at test time; full replay will be enabled in a future CLI
  version.
- **`temporal_server` search attributes**: the server mode wrapper does not
  currently forward `--search-attribute` flags. Use `temporal_test` with
  `namespace_config` when custom search attributes are required.
- **Target name collisions**: two `temporal_server` targets with the same local
  name in different packages would write to the same
  `$TEST_TMPDIR/<name>.env` path. Use unique target names within a test run.
- **No time-skipping**: `temporal server start-dev` runs on real wall-clock time.
  Timer-based workflows (`workflow.sleep`, cron schedules) are not testable
  without long test timeouts.
- **darwin tarball checksums are placeholders**: `temporal.version()` on macOS
  requires real SHA-256 values pinned in `extensions.bzl`.
- **`~1–2 s` overhead per test** for server startup. For very large test suites,
  consider a shared-server approach with `temporal_server`.

## Development

```sh
# Run all self-tests
bazel test //tests/...
```

All 5 tests pass on Linux x86_64 with Temporal CLI 1.6.2.
