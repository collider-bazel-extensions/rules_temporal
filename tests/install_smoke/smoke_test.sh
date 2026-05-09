#!/usr/bin/env bash
# Full E2E install smoke. Strategy:
#
#   1. Apply tests/install_smoke/cluster.yaml (Namespace + Postgres
#      + TemporalCluster + TemporalNamespace).
#   2. Wait for postgres Deployment Available, then for
#      TemporalCluster status.conditions[Ready] = True. The
#      operator runs schema migrations + boots 4 services
#      (frontend, history, matching, worker) — typically ~2 min.
#   3. Wait for TemporalNamespace registered (operator runs a
#      one-shot Job that calls `temporal operator namespace
#      create`).
#   4. `kubectl port-forward` the frontend Service to localhost:7233.
#   5. Run the existing tests/workers/hello_worker.py worker (a
#      reusable py_binary from v0.1) in the background, pointed at
#      localhost:7233 + namespace smoke-ns + task queue smoke-queue.
#   6. `temporal workflow execute --type HelloWorkflow --input
#      '"world"'`. The CLI submits the workflow, the worker picks
#      it up, executes the greet_activity, returns "Hello, world!".
#   7. Assert the output contains "Hello, world!".
#
# Proves end-to-end: cert-manager + temporal-operator install +
# TemporalCluster reconciliation + TemporalNamespace registration
# + live Temporal API + worker registration + workflow execution +
# activity execution.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="temporal-smoke"
CLUSTER="smoke"
TEMPORAL_NS="smoke-ns"
TASK_QUEUE="smoke-queue"

_resolve() {
  local rel="$1"
  for cand in \
    "${RUNFILES_DIR:-}/_main/$rel" \
    "$(dirname "$0").runfiles/_main/$rel" \
    "$rel"; do
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

CLUSTER_YAML="$(_resolve tests/install_smoke/cluster.yaml)" \
    || { echo "smoke: cluster.yaml not in runfiles" >&2; exit 1; }
# v0.3 install smoke runs the worker host-side via system `python3`
# rather than the rules_python `py_binary` shape — bazel's hermetic
# Python interpreter doesn't see system `pip install` packages, so
# the py_binary form would fail to import `temporalio`. Resolving
# the .py source out of runfiles (it ships as the py_binary's
# `srcs`) and invoking `python3` against it sidesteps the toolchain
# entirely; consumers only need `pip install temporalio` on the
# host.
WORKER_PY="$(_resolve tests/workers/hello_worker.py)" \
    || { echo "smoke: tests/workers/hello_worker.py not in runfiles" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || {
  echo "smoke: \`python3\` not on PATH (host-side worker requires it + 'pip install temporalio')" >&2
  exit 1
}

command -v temporal >/dev/null 2>&1 || {
  echo "smoke: \`temporal\` not on PATH. Install from https://temporal.io/setup/install-temporal-cli" >&2
  exit 1
}

echo "smoke: applying $CLUSTER_YAML"
"${KCTL[@]}" apply --server-side -f "$CLUSTER_YAML" >/dev/null

echo "smoke: waiting for postgres Deployment to be Available"
"${KCTL[@]}" -n "$NS" wait deploy/postgres --for=condition=Available --timeout=180s

echo "smoke: waiting for TemporalCluster/$CLUSTER to reach Ready condition"
deadline=$(( $(date +%s) + 360 ))
ready=""
while (( $(date +%s) < deadline )); do
  ready=$("${KCTL[@]}" -n "$NS" get temporalcluster "$CLUSTER" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$ready" == "True" ]] && break
  sleep 5
done
if [[ "$ready" != "True" ]]; then
  echo "smoke: FAIL — TemporalCluster never reached Ready (status=${ready:-<unset>})" >&2
  "${KCTL[@]}" -n "$NS" get temporalcluster "$CLUSTER" -o yaml >&2 || true
  exit 1
fi

# The operator creates Deployments named like <cluster>-<service>.
# Wait for the frontend Deployment specifically — that's what we
# port-forward.
frontend_deploy="${CLUSTER}-frontend"
echo "smoke: waiting for $frontend_deploy Deployment to be Available"
"${KCTL[@]}" -n "$NS" wait "deploy/$frontend_deploy" --for=condition=Available --timeout=240s

echo "smoke: waiting for TemporalNamespace/$TEMPORAL_NS to be registered"
deadline=$(( $(date +%s) + 240 ))
ns_ready=""
while (( $(date +%s) < deadline )); do
  ns_ready=$("${KCTL[@]}" -n "$NS" get temporalnamespace "$TEMPORAL_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$ns_ready" == "True" ]] && break
  sleep 5
done
if [[ "$ns_ready" != "True" ]]; then
  echo "smoke: FAIL — TemporalNamespace never reached Ready (status=${ns_ready:-<unset>})" >&2
  "${KCTL[@]}" -n "$NS" get temporalnamespace "$TEMPORAL_NS" -o yaml >&2 || true
  exit 1
fi

# Port-forward Frontend gRPC to localhost.
echo "smoke: port-forwarding $frontend_deploy → localhost:7233"
"${KCTL[@]}" -n "$NS" port-forward "deploy/$frontend_deploy" 7233:7233 >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" "${WORKER_PID:-0}" >/dev/null 2>&1 || true' EXIT

# Wait for port-forward.
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
  if (echo > /dev/tcp/localhost/7233) >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! (echo > /dev/tcp/localhost/7233) >/dev/null 2>&1; then
  echo "smoke: FAIL — port-forward never listened on localhost:7233" >&2
  cat /tmp/pf.log >&2 || true
  exit 1
fi

# Start the hello worker in the background, pointed at the
# port-forwarded Frontend.
echo "smoke: starting hello_worker.py via system python3"
TEMPORAL_ADDRESS=localhost:7233 \
TEMPORAL_NAMESPACE="$TEMPORAL_NS" \
TEMPORAL_TASK_QUEUE="$TASK_QUEUE" \
    python3 "$WORKER_PY" >/tmp/worker.log 2>&1 &
WORKER_PID=$!

# Wait for the worker to print its readiness line. Without this,
# any import / connect failure leaves `temporal workflow execute`
# hanging until the test timeout (an opaque 30-min stall) — bail
# fast with the worker log instead.
echo "smoke: waiting for worker to register"
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
  if grep -q "polling '$TASK_QUEUE'" /tmp/worker.log 2>/dev/null; then
    break
  fi
  if ! kill -0 "$WORKER_PID" 2>/dev/null; then
    echo "smoke: FAIL — hello_worker_bin exited before polling task queue" >&2
    echo "---- worker logs ----" >&2
    cat /tmp/worker.log >&2 || true
    exit 1
  fi
  sleep 1
done
if ! grep -q "polling '$TASK_QUEUE'" /tmp/worker.log 2>/dev/null; then
  echo "smoke: FAIL — worker never reported polling within 30s" >&2
  echo "---- worker logs ----" >&2
  cat /tmp/worker.log >&2 || true
  exit 1
fi

# Submit + execute a workflow synchronously. The CLI returns the
# workflow result on stdout once the worker completes it.
echo "smoke: executing HelloWorkflow"
result=$(temporal workflow execute \
    --address localhost:7233 \
    --namespace "$TEMPORAL_NS" \
    --task-queue "$TASK_QUEUE" \
    --type HelloWorkflow \
    --workflow-id smoke-hello-1 \
    --input '"world"' 2>&1 || true)

if ! grep -q 'Hello, world!' <<<"$result"; then
  echo "smoke: FAIL — expected 'Hello, world!' in workflow result, got:" >&2
  echo "$result" >&2
  echo "---- worker logs ----" >&2
  cat /tmp/worker.log >&2 || true
  exit 1
fi

echo "smoke: OK — operator install + TemporalCluster reconciliation + TemporalNamespace registration + worker + workflow execution all live"
echo "  workflow result excerpt: $(grep -o 'Hello, world!' <<<"$result" | head -1)"
