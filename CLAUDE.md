# rules_temporal

Bazel rules for running integration tests against an ephemeral Temporal cluster.
Provides a full suite of hermetic, parallel-safe Temporal primitives with zero
external state — no shared server, no shared namespace.

## Commit requirements

- All tests must pass before any commit with code changes (`bazel test //tests/...`).
- All documentation (`CLAUDE.md`) must be updated to reflect any code changes before committing.

## Repo layout

```
rules_temporal/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: temporal binary repos (download or system)
├── repositories.bzl          # Legacy WORKSPACE equivalents of extensions.bzl
├── BUILD.bazel               # Platform config_settings, temporal_binary + temporal_cli targets
├── DESIGN.md                 # Architecture and design decisions
├── private/
│   ├── binary.bzl            # temporal_binary + temporal_cli rules, TemporalBinaryInfo
│   ├── worker.bzl            # temporal_build rule + TemporalWorkerInfo provider
│   ├── namespace_config.bzl  # temporal_namespace_config + TemporalNamespaceConfigInfo
│   ├── history.bzl           # temporal_workflow_history + TemporalWorkflowHistoryInfo
│   ├── server.bzl            # temporal_server + temporal_health_check rules
│   ├── test.bzl              # temporal_test macro + _temporal_launcher_test rule
│   ├── replay.bzl            # temporal_replay_runner macro (#4), REPLAY_PYTHON_VERSION
│   ├── replay_runner.py      # SDK replay runner (built-in py_binary + library for the macro)
│   ├── requirements.in       # temporalio pin for the built-in replay runner (#4)
│   ├── requirements_lock.txt # hash-pinned universal lock → @rules_temporal_pypi
│   ├── BUILD.bazel           # //private:replay_runner (py_binary), :replay_runner_lib
│   └── launcher.py           # Launcher: server → worker → wait → exec → teardown
│                               (also handles server mode for rules_itest integration)
├── toolchain/
│   ├── toolchain.bzl         # Toolchain type + register helpers
│   └── BUILD.bazel
├── tools/
│   └── update_replay_requirements.sh  # regenerates private/requirements_lock.txt (uv)
└── tests/
    ├── BUILD.bazel
    ├── hello_test.sh              # HelloWorkflow, EchoWorkflow, MathWorkflow smoke test
    ├── namespace_config_test.sh   # Custom search attribute registration test
    ├── temporal_replay_test.sh    # Workflow history export/inspection test
    ├── temporal_server_test.sh    # temporal_server lifecycle test
    ├── temporal_health_check_test.sh  # temporal_health_check script behavior test
    ├── launcher_unit_test.py      # #10: readiness timeouts (py_test, no server)
    ├── ready_timeout/             # #10: temporal_test with a never-ready worker, worker_ready_timeout = 3
    ├── replay/                    # #4: committed-history replay, drift, runner errors, temporal_replay_runner
    │   └── testdata/              # histories recorded from hello_worker.py (+ a truncated one)
    └── workers/
        └── hello_worker.py       # Python worker: Hello/Echo/Math/Counter workflows
                                  # (py_binary with @rules_temporal_pypi's temporalio)
```

## Key concepts

### Providers (chain)

```
TemporalBinaryInfo
  └─ TemporalWorkerInfo   (carries a TemporalBinaryInfo + registration manifest)
       ├─ consumed by temporal_test (_temporal_launcher_test)
       ├─ TemporalNamespaceConfigInfo  (wraps TemporalWorkerInfo + search_attributes)
       └─ TemporalWorkflowHistoryInfo  (wraps TemporalWorkerInfo + history_files depset)
```

### `temporal_test` isolation model

Every `temporal_test` target gets:
- Its own `temporal server start-dev` process on a dynamically allocated free port
- A UUID-based namespace (`temporal-test-<12-hex-chars>`) created at runtime — never reused
- Env vars injected: `TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE`, `TEMPORAL_TASK_QUEUE`
- A dedicated worker process (started and stopped by the launcher)

No shared state between tests → full `--jobs` parallelism is safe.

### Launcher modes

The launcher (`private/launcher.py`) supports two modes selected by `RULES_TEMPORAL_MODE`:

| Mode | Env var | Behaviour |
|------|---------|-----------|
| `test` (default) | `TEMPORAL_MANIFEST` | server → search attrs → worker → wait → validate → replay → execve |
| `server` | `RULES_TEMPORAL_MANIFEST` | server → write env file atomically → signal.pause() |

Test mode is used by `temporal_test`. Server mode is used by `temporal_server` for
`rules_itest` integration.

### Port allocation

`_allocate_port()` uses `socket.bind(('127.0.0.1', 0))` to get a free port.
The socket is closed just before `temporal server start-dev` starts; up to 5 retries
handle the rare TOCTOU race. Retries only happen on port-binding conflicts (detected
by scanning the server log for "address already in use"). Any other error causes
immediate failure with the full server log printed.

### Search attributes (Temporal 1.24+)

In Temporal server 1.24+, custom search attributes are namespace-scoped. They must
be registered at **server startup** via `temporal server start-dev --search-attribute`.
The launcher passes `--search-attribute Name=Type` flags when `namespace_config` is
provided. The post-startup `temporal operator search-attribute create` command is
NOT used (it creates cluster-level attributes that are not namespace-mapped in 1.24+).

### Sandbox HOME/TMPDIR

Bazel's linux-sandbox does not inherit HOME or TMPDIR. The Temporal CLI requires a
writable HOME for its config/cache dirs. The launcher sets `HOME` and `TMPDIR` to
`$TEST_TMPDIR` for all CLI subprocesses (server readiness checks, worker polling,
type validation) AND in the env passed to the test binary via `os.execve`.
`env.setdefault` is used so that if the test environment already provides HOME, it
is not overridden.

NOTE: The worker subprocess does NOT get HOME/TMPDIR overrides. A consumer's worker
binary may need its original HOME to find user-installed packages (e.g.
`~/.local/lib/python3.x` for `temporalio`). This repo's own fixture worker doesn't:
it takes `temporalio` from `@rules_temporal_pypi`.

### Hermetic history replay (#4, v0.8.0)

- The built-in runner is `//private:replay_runner`, a `py_binary` with
  `python_version = "3.12"` and `deps = ["@rules_temporal_pypi//temporalio"]`.
  `MODULE.bazel` has a non-dev `rules_python` 1.7.0, `python.toolchain(3.12)` and
  `pip.parse(hub_name = "rules_temporal_pypi", ...)` over
  `private/requirements_lock.txt` (wheels only). Pinned: **temporalio 1.36.1**,
  CPython 3.12 (3.12.12 under rules_python 1.7.0). Lock covers linux
  x86_64/aarch64 + macOS x86_64/arm64. Keep the 3.12 in MODULE.bazel,
  `private/replay.bzl` (`REPLAY_PYTHON_VERSION`) and
  `tools/update_replay_requirements.sh` in step.
- The launcher runs the runner from runfiles (`<runner> <module> <history>
  <classes>`), never via `python3`. Nothing comes from the host's pip.
- **Laziness:** `_temporal_launcher_test.builtin_replay_runner` has no default;
  the `temporal_test` macro sets it only when `history` is set or
  `builtin_replay_runner = True`. A test without it never fetches the interpreter or
  wheels. Don't give that attribute a default. `.github/consumer/check.sh` fails if
  a non-replay consumer build fetches `python_3_*` / `rules_temporal_pypi*`.
- The worker's `replay_runner` (custom runner) wins. `temporal_replay_runner`
  (`private/replay.bzl`) builds one against consumer deps: generated main →
  `replay_runner.main_by_name(<import name>, [classes])`, deps + `//private:replay_runner_lib`.
- The built-in runner loads `workflow_module` by path: only temporalio, its deps and
  stdlib resolve.
- Bump the pin: edit `private/requirements.in`, run `tools/update_replay_requirements.sh`
  (needs uv), update the version in README / DESIGN / this file.

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

`temporal_namespace_config` validates search attribute types at analysis time:
- Valid types: `Bool`, `Datetime`, `Double`, `Int`, `Keyword`, `KeywordList`, `Text`

Failures surface as `bazel build` errors, not as flaky test failures.

### Combined test manifest

`_temporal_launcher_test` generates a combined manifest (`<name>_test_manifest.json`)
that includes all fields from `TemporalWorkerInfo` plus optional `search_attributes`
and `history_files`. This allows `temporal_test` to integrate namespace_config and
history without modifying the `temporal_build` manifest.

```json
{
  "workspace":         "<workspace_name>",
  "temporal_bin":      "<runfile path>",
  "worker_binary":     "<runfile path>",
  "task_queue":        "<task queue>",
  "workflow_types":    ["WorkflowA"],
  "activity_types":    ["activityA"],
  "search_attributes": {"MyAttr": "Keyword"},
  "history_files":     ["tests/testdata/history.json"]
}
```

### `temporal_server` readiness protocol

`temporal_server` writes `$TEST_TMPDIR/<name>.env` atomically (via temp file +
`os.replace`) once the server is fully ready:

```
TEMPORAL_ADDRESS=127.0.0.1:<port>
TEMPORAL_NAMESPACE=temporal-test-<12-hex>
```

`temporal_health_check` exits 0 iff this file exists. Used as the `health_check`
attribute of an `itest_service` in rules_itest.

## Supported Temporal CLI versions

- 1.7.0 (`temporal.version()`; also tested with host-installed)

The auto-detection logic works with any version of the Temporal CLI in PATH.

## Public API

```python
load("@rules_temporal//:defs.bzl",
    "temporal_build",
    "temporal_test",
    "temporal_server",
    "temporal_health_check",
    "temporal_namespace_config",
    "temporal_workflow_history",
    "temporal_replay_runner",
    "temporal_cli",
)

# Runnable CLI (#13): //:temporal (default), //:temporal_cli_<version>.
# `bazel run @rules_temporal//:temporal -- --version`; as a runfile,
# $(rlocationpath @rules_temporal//:temporal).
temporal_cli(name = "my_cli", binary = ":my_temporal_binary")

# Declare a worker binary with its registered types.
temporal_build(
    name           = "my_worker",
    worker_binary  = ":my_worker_bin",   # required: a *_binary target
    task_queue     = "my-task-queue",    # required: non-empty string
    workflow_types = ["MyWorkflow"],     # required: at least one
    activity_types = ["my_activity"],   # optional
)

# Run an isolated test against an ephemeral Temporal cluster.
temporal_test(
    name             = "my_test",
    worker           = ":my_worker",         # required
    srcs             = ["my_test.sh"],       # forwarded to test_rule
    deps             = [...],                # forwarded to test_rule
    size             = "medium",             # optional, default "medium"
    timeout          = None,                 # optional
    tags             = [...],                # optional
    test_rule        = go_test,             # optional; default native.sh_test
    namespace_config = ":my_ns_config",     # optional
    history          = ":my_histories",     # optional
    worker_ready_timeout = 30,              # optional: seconds the launcher waits for pollers
    server_ready_timeout = 30,              # optional: seconds it waits for start-dev
    builtin_replay_runner = None,           # optional (#4): None = iff history; True; False
    **kwargs,
)
# temporal_server(name = ..., server_ready_timeout = "30") likewise (a string).
# Bad values fail analysis (ready_timeout_seconds in test.bzl); the launcher's
# _ready_timeout keeps 30 s for a manifest without the key (#10).

# Declare custom search attributes (registered at server startup).
temporal_namespace_config(
    name              = "my_ns_config",
    worker            = ":my_worker",
    search_attributes = {
        "CustomerId": "Keyword",
        "OrderTotal": "Double",
    },
)

# Declare committed workflow history files for replay testing.
temporal_workflow_history(
    name   = "my_histories",
    worker = ":my_worker",
    srcs   = glob(["testdata/*.json"]),
)

# #4: a replay runner built against the consumer's own deps / temporalio, for
# temporal_build(replay_runner = ...). The module is imported by name.
temporal_replay_runner(
    name            = "my_replay_runner",
    workflow_module = "myapp.workflows",
    workflow_types  = ["MyWorkflow"],
    deps            = [":workflows"],      # must bring a temporalio
)

# Long-running server for rules_itest multi-service tests.
temporal_server(name = "my_server")
temporal_health_check(name = "my_health", server = ":my_server")
```

### Environment variables injected into the test binary

| Variable              | Example value                | Description                          |
|-----------------------|------------------------------|--------------------------------------|
| `TEMPORAL_ADDRESS`    | `127.0.0.1:54321`            | gRPC address of the ephemeral server |
| `TEMPORAL_NAMESPACE`  | `temporal-test-abc123def456` | Isolated per-test namespace          |
| `TEMPORAL_TASK_QUEUE` | `test-hello-queue`           | Task queue declared in temporal_build |
| `TEMPORAL_REPLAY_RUNNER` | `<runfiles>/.../private/replay_runner` | Built-in runner executable; only when attached (history / builtin_replay_runner = True) |
| `TEMPORAL_CUSTOM_REPLAY_RUNNER` | `<runfiles>/...` | The worker's `replay_runner`, if set |
| `TEMPORAL_WORKFLOW_MODULE` / `TEMPORAL_WORKFLOW_TYPES` | | The worker's workflow_module path / comma-separated workflow_types |

### MODULE.bazel (Bzlmod)

```python
bazel_dep(name = "rules_temporal", version = "0.8.0")

temporal = use_extension("@rules_temporal//:extensions.bzl", "temporal")

# Use the host-installed temporal CLI (auto-detects from PATH):
temporal.system(versions = ["1.7.0"])

# Or specify the path explicitly:
# temporal.system(versions = ["1.7.0"], bin_dir = "/usr/local/bin")

# Or download pre-built tarballs:
# temporal.version(versions = ["1.7.0"])

use_repo(temporal,
    "temporal_1_7_0_linux_amd64",
    "temporal_1_7_0_darwin_arm64",
    "temporal_1_7_0_darwin_amd64",
)
```

### WORKSPACE (legacy)

```python
load("@rules_temporal//:repositories.bzl", "temporal_system_dependencies")

temporal_system_dependencies(versions = ["1.7.0"])
```

## Development

### Running the self-tests

```sh
bazel test //tests/...
```

All tests must pass before any commit with code changes.

### Test results (last full run: 2026-11-16)

All 12 tests pass on Linux x86_64 with Temporal CLI 1.7.0 and the pinned
temporalio 1.36.1, with no host temporalio (run locally with
`--test_env=PYTHONNOUSERSITE=1` to hide a `~/.local` install; CI's runner has none
and checks `python3 -c 'import temporalio'` fails). CI runs all of `//tests/...`,
then the replay tests again with `--nocache_test_results --test_output=all`. The
install smoke (`//tests/install_smoke:smoke_test`, manual, kind + Docker) runs in its
own CI job, also without `pip install temporalio`.

Consumer check before committing (the archive is built from a tree-ish):
`git add -A && .github/consumer/check.sh <scratch dir> "$(git write-tree)"`.

| Test target                        | What it verifies                                                              | Result |
|------------------------------------|-------------------------------------------------------------------------------|--------|
| `//tests:hello_test`               | HelloWorkflow, EchoWorkflow, MathWorkflow end-to-end; namespace isolation     | PASSED |
| `//tests:namespace_config_test`    | Custom search attributes registered at startup; usable in workflow execute    | PASSED |
| `//tests:temporal_replay_test`     | Workflow history export and replay via `$TEMPORAL_REPLAY_RUNNER` (`builtin_replay_runner = True`) | PASSED |
| `//tests:temporal_server_test`     | temporal_server writes env file, gRPC health check, clean SIGTERM shutdown    | PASSED |
| `//tests:temporal_health_check_test` | Health check exits 0/non-zero based on env file presence                    | PASSED |
| `//tests:launcher_unit_test`       | `_ready_timeout` parsing/refusals, worker wait honours the timeout and stops when the worker exits, `main_test` passes manifest timeouts (#10); `_replay_histories` runs the built-in runner directly, custom runner wins, missing-runner error (#4) | PASSED |
| `//tests/ready_timeout:worker_ready_timeout_test` | `temporal_test` with `worker_ready_timeout = 3` and a worker that never connects fails after 3 s, naming the task queue, without running the test body (#10) | PASSED |
| `//tests:temporal_cli_test`        | `//:temporal` runs from runfiles via `$(rlocationpath)` with PATH cleared (#13) | PASSED |
| `//tests/replay:replay_runner_test` | Built-in runner and `temporal_replay_runner` run directly: good histories replay; drifted code → NondeterminismError; bad history / module / class / argv messages (#4) | PASSED |
| `//tests/replay:history_replay_test` | `temporal_test(history = ...)` replays committed histories with the built-in runner before the body (#4) | PASSED |
| `//tests/replay:history_replay_drift_test` | Drifted workflow code fails the `temporal_test` with the runner's report, body not run (#4) | PASSED |
| `//tests/replay:custom_runner_replay_test` | `temporal_replay_runner` as the worker's `replay_runner`, `builtin_replay_runner = False` (#4) | PASSED |

### Launcher script

`private/launcher.py` is the heart of both `temporal_test` and `temporal_server`.

**Test mode** (`main_test`):

1. Reads the combined JSON manifest (`TEMPORAL_MANIFEST`).
2. Resolves all runfile paths.
3. Ensures all binaries have the execute bit set.
4. Allocates a free TCP port via `socket.bind`.
5. Generates a UUID-based namespace for test isolation.
6. Starts `temporal server start-dev` with `--search-attribute` flags (if namespace_config).
7. Waits for readiness: TCP socket open → `temporal operator cluster health` gRPC check.
8. Retries startup on port conflicts only; fails immediately on all other errors.
9. Starts the worker subprocess with `TEMPORAL_*` env vars (preserving original HOME/TMPDIR).
10. Polls `temporal task-queue describe` until pollers appear (worker ready).
11. Optionally validates declared workflow/activity types against the server's registration data.
12. Replays committed workflow history files via `_replay_histories` (if history provided):
    the worker's custom runner, else the built-in `//private:replay_runner` executable.
13. `os.execve`'s the wrapped test binary with `TEMPORAL_*` env vars set.
14. `atexit` handlers run `server_proc.terminate()` and `worker_proc.terminate()` on exit.

**Server mode** (`main_server`):

1–5. Same as test mode.
6. Starts `temporal server start-dev` (no worker, no search attributes in this mode).
7. Waits for readiness.
8. Writes `$RULES_TEMPORAL_OUTPUT_ENV_FILE` atomically.
9. Installs SIGTERM/SIGINT handlers that call `sys.exit(0)`.
10. Blocks on `signal.pause()` until signal arrives.

### Test script requirements

All test shell scripts must:
- Begin with `set -euo pipefail`.
- Use a `require_env VAR` guard for every `TEMPORAL_*` variable before first use.
- Use `--namespace "$TEMPORAL_NAMESPACE"` explicitly on temporal CLI calls
  (the env var alone is not always picked up by the CLI in the Bazel sandbox).

### Style

- All `.bzl` files use 4-space indentation.
- Provider fields are documented with inline comments.
- Public rules/macros have docstrings.
- `private/` contains implementation details; only `defs.bzl` is the stable API.

## Known limitations

- Windows is not supported (no pre-built binary source; PRs welcome).
- The built-in replay runner has one pinned temporalio (1.36.1) and loads the workflow
  module by path (temporalio + stdlib imports only); `temporal_replay_runner` covers the rest.
- `temporal_test` adds ~1–2 s overhead per test for server startup. For very large
  test suites, consider a shared-server mode (not yet implemented).
- Downloaded tarball SHA-256 checksums in `extensions.bzl`/`repositories.bzl` are
  placeholder values for darwin platforms. Pin real values before enabling `temporal.version()`.
- The type-registration validator (`_validate_registered_types`) only fires if the
  Temporal CLI returns `versioningInfo.typeInfoByType` in the task-queue describe
  response. This is available in Temporal CLI >= 1.1 with versioning enabled; it is
  silently skipped otherwise.
- `temporal_server` search attribute support: the server mode wrapper does not currently
  pass `--search-attribute` flags. If you need custom search attributes in a
  `temporal_server` target, add `--search-attribute` flags to the wrapper script.

## Release archive

`.gitattributes` export-ignores `tests/`, so they may load dev-only modules; nothing else may. CI's `consumer` job checks that `@rules_temporal//...` loads from the commit's `git archive` (`.github/consumer/check.sh`), that a non-replay consumer fetches no Python / wheels, and that a consumer replays with the pinned SDK (#4).
