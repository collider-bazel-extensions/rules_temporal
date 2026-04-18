# rules_temporal

Bazel rules for running integration tests against an ephemeral Temporal cluster.
Provides `temporal_build` (validates a worker binary) and `temporal_test` (runs
tests against a hermetic, parallel-safe `temporal server start-dev` instance with
zero external state — no shared server, no shared namespace).

## Repo layout

```
rules_temporal/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: temporal binary repos (download or system)
├── repositories.bzl          # Legacy WORKSPACE equivalents of extensions.bzl
├── BUILD.bazel               # Platform config_settings + temporal_binary targets
├── private/
│   ├── binary.bzl            # temporal_binary rule + TemporalBinaryInfo provider
│   ├── worker.bzl            # temporal_build rule + TemporalWorkerInfo provider
│   ├── test.bzl              # temporal_test macro + _temporal_launcher_test rule
│   └── launcher.py           # Test launcher: server → worker → wait → exec → teardown
├── toolchain/
│   ├── toolchain.bzl         # Toolchain type + register helpers
│   └── BUILD.bazel
└── tests/
    ├── BUILD.bazel
    ├── hello_test.sh         # End-to-end smoke test (HelloWorkflow)
    └── workers/
        └── hello_worker.py   # Minimal Python worker for smoke tests
```

## Key concepts

### Providers (chain)

```
TemporalBinaryInfo
  └─ TemporalWorkerInfo   (carries a TemporalBinaryInfo + registration manifest)
       └─ consumed by _temporal_launcher_test
```

### `temporal_test` isolation model

Every `temporal_test` target gets:
- Its own `temporal server start-dev` process on a dynamically allocated free port
- A UUID-based namespace (`temporal-test-<12-hex-chars>`) created at runtime — never reused
- Env vars injected: `TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE`, `TEMPORAL_TASK_QUEUE`
- A dedicated worker process (started and stopped by the launcher)

No shared state between tests → full `--jobs` parallelism is safe.

### Two-process model

The launcher manages:
1. **Temporal server** — `temporal server start-dev --headless --ip 127.0.0.1 --port <free-port> --namespace <uuid-ns>`
2. **Worker binary** — the binary from `temporal_build`, with `TEMPORAL_*` env vars injected

After both are ready, the launcher `os.execve`'s the inner test binary, replacing itself.
On exit (normal or abnormal), `atexit` handlers terminate both the server and the worker.

### Port allocation

`_allocate_port()` uses `socket.bind(('127.0.0.1', 0))` to get a free port.
The socket is closed just before `temporal server start-dev` starts; up to 5 retries
handle the rare TOCTOU race. Retries only happen on port-binding conflicts (detected
by scanning the server log for "address already in use"). Any other error causes
immediate failure with the full server log printed.

### Sandbox HOME/TMPDIR

Bazel's linux-sandbox does not inherit HOME or TMPDIR. The Temporal CLI requires a
writable HOME for its config/cache dirs. The launcher sets `HOME` and `TMPDIR` to
`$TEST_TMPDIR` for all CLI subprocesses (server readiness checks, worker polling,
type validation) AND in the env passed to the test binary via `os.execve`.
`env.setdefault` is used so that if the test environment already provides HOME, it
is not overridden.

### Binary source (distribution-independent)

`extensions.bzl` (Bzlmod) and `repositories.bzl` (WORKSPACE) both support two modes:

| Tag / function                    | Behavior                                             |
|-----------------------------------|------------------------------------------------------|
| `temporal.version()`              | Downloads a pre-built tarball from GitHub releases   |
| `temporal.system()`               | Symlinks the host-installed `temporal` CLI binary    |
| `temporal_system_dependencies()`  | WORKSPACE equivalent of `temporal.system()`          |

**Auto-detection** — when `bin_dir` is omitted (the default), the repository rule
resolves the `temporal` binary:

1. `command -v temporal` (i.e., `PATH` lookup)
2. Common paths: `~/.local/bin`, `/usr/local/bin`, `/usr/bin`, `/opt/homebrew/bin`

If the binary cannot be found, the build fails immediately with a clear error pointing
to the missing binary and a suggested install URL.

Platforms supported for downloaded tarballs: `linux_amd64`, `darwin_arm64`, `darwin_amd64`.

### Analysis-time validation (`temporal_build`)

`temporal_build` validates at Bazel analysis time (not at test run time):
- `task_queue` must be a non-empty string
- `workflow_types` must be a non-empty list
- No empty strings in `workflow_types` or `activity_types`
- No duplicate names in `workflow_types` or `activity_types`

Failures surface as `bazel build` errors, not as flaky test failures.

### Registration manifest

`temporal_build` emits a JSON file (`<name>_manifest.json`) containing the declared
worker configuration:

```json
{
  "workspace": "<workspace_name>",
  "temporal_bin": "<runfile path to temporal CLI>",
  "worker_binary": "<runfile path to worker binary>",
  "task_queue": "<task queue name>",
  "workflow_types": ["WorkflowA", "WorkflowB"],
  "activity_types": ["activityA"]
}
```

The launcher reads this manifest via `$TEMPORAL_MANIFEST` to start the worker.

## Supported Temporal CLI versions

- 1.6.2 (bundled; also tested with host-installed)

The auto-detection logic works with any version of the Temporal CLI in PATH.

## Public API

```python
load("@rules_temporal//:defs.bzl", "temporal_build", "temporal_test")

temporal_build(
    name = "my_worker",
    worker_binary = ":my_worker_bin",   # required: a *_binary target
    task_queue    = "my-task-queue",    # required: non-empty string
    workflow_types = ["MyWorkflow"],    # required: at least one
    activity_types = ["my_activity"],   # optional
)

temporal_test(
    name       = "my_test",
    worker     = ":my_worker",          # required: a temporal_build target
    srcs       = ["my_test.sh"],        # forwarded to test_rule
    deps       = [...],                 # forwarded to test_rule
    size       = "medium",              # optional, default "medium"
    timeout    = None,                  # optional
    tags       = [...],                 # optional
    test_rule  = go_test,               # optional; default native.sh_test
    **kwargs,
)
```

### Environment variables injected into the test binary

| Variable              | Example value              | Description                        |
|-----------------------|----------------------------|------------------------------------|
| `TEMPORAL_ADDRESS`    | `127.0.0.1:54321`          | gRPC address of the ephemeral server |
| `TEMPORAL_NAMESPACE`  | `temporal-test-abc123def456` | Isolated per-test namespace        |
| `TEMPORAL_TASK_QUEUE` | `test-hello-queue`         | Task queue declared in temporal_build |

### MODULE.bazel (Bzlmod)

```python
bazel_dep(name = "rules_temporal", version = "0.1.0")

temporal = use_extension("@rules_temporal//:extensions.bzl", "temporal")

# Use the host-installed temporal CLI (auto-detects from PATH):
temporal.system(versions = ["1.6.2"])

# Or specify the path explicitly:
# temporal.system(versions = ["1.6.2"], bin_dir = "/usr/local/bin")

# Or download pre-built tarballs:
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

temporal_system_dependencies(versions = ["1.6.2"])
```

## Development

### Running the self-tests

```sh
bazel test //tests/...
```

### Test results (last full run: 2026-04-18)

1 test passed in ~6 s on Linux x86_64 with Temporal CLI 1.6.2 system install.

| Test target           | What it verifies                                                | Result |
|-----------------------|-----------------------------------------------------------------|--------|
| `//tests:hello_test`  | End-to-end HelloWorkflow execution; namespace isolation         | PASSED |

### Launcher script

`private/launcher.py` is the heart of `temporal_test`. It:

1. Reads the JSON manifest written by the Bazel rule (`TEMPORAL_MANIFEST`).
2. Resolves all runfile paths (external repos use `../repo/path`; workspace files use `<workspace>/path`).
3. Ensures all binaries have the execute bit set.
4. Allocates a free TCP port via `socket.bind`.
5. Generates a UUID-based namespace for test isolation.
6. Starts `temporal server start-dev` with the allocated port and namespace.
7. Waits for readiness: TCP socket open → `temporal operator cluster health` gRPC check.
8. Retries startup on port conflicts only; fails immediately on all other errors.
9. Starts the worker subprocess with `TEMPORAL_*` env vars set.
10. Polls `temporal task-queue describe` until pollers appear (worker ready).
11. Optionally validates declared workflow/activity types against the server's registration data.
12. `os.execve`'s the wrapped test binary with `TEMPORAL_*` env vars set.
13. `atexit` handlers run `server_proc.terminate()` and `worker_proc.terminate()` on exit.

### Test script requirements

All test shell scripts must:
- Begin with `set -euo pipefail`.
- Use a `require_env VAR` guard for every `TEMPORAL_*` variable before first use.
- Not pass the namespace as both a positional argument and an env var to `temporal`
  commands — `TEMPORAL_NAMESPACE` is picked up automatically by the CLI, so just
  use `--address $TEMPORAL_ADDRESS` (the namespace is implicit).

### Style

- All `.bzl` files use 4-space indentation.
- Provider fields are documented with inline comments.
- Public rules/macros have docstrings.
- `private/` contains implementation details; only `defs.bzl` is the stable API.

## Known limitations

- Windows is not supported (no pre-built binary source; PRs welcome).
- `temporal_test` adds ~1–2 s overhead per test for server startup. For very large
  test suites, consider a shared-server mode (not yet implemented).
- Downloaded tarball SHA-256 checksums in `extensions.bzl`/`repositories.bzl` are
  placeholder values for darwin platforms. Pin real values before enabling `temporal.version()`.
- The type-registration validator (`_validate_registered_types`) only fires if the
  Temporal CLI returns `versioningInfo.typeInfoByType` in the task-queue describe
  response. This is available in Temporal CLI >= 1.1 with versioning enabled; it is
  silently skipped otherwise.
