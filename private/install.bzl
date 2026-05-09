"""Cluster-deploy primitives — `temporal_install` + `temporal_install_health_check`.

Pure glue over `rules_kubectl`'s `kubectl_apply` + a vendored
temporal-operator manifest (CRDs + non-CRDs concatenated at
maintainer-render time, see tools/render_temporal_operator.sh).
Sibling to the existing test-time primitives — those stay
unchanged in v0.3; the new install primitives use `_install_` in
their names to avoid colliding with v0.1/v0.2's
`temporal_health_check` (paired with the test-time
`temporal_server`).

**cert-manager required upstream.** The operator's manifest
includes `Certificate` + `Issuer` CRs (cert-manager.io/v1) for
its admission webhook serving cert. Apply cert-manager's
`Issuer` + `Certificate` CRDs first via
`rules_certmanager`'s `cert_manager_install`. The smoke
composes the dependency via `itest_service.deps`.

Wait shape:
  - Deployment `temporal-system/temporal-operator-controller-manager` Available
  - 4 CRDs: temporalclusters, temporalnamespaces, temporalschedules,
    temporalclusterclients (under .temporal.io)
"""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

_OPERATOR_DEPLOY = "temporal-operator-controller-manager"
_OPERATOR_CRDS = [
    "temporalclusters.temporal.io",
    "temporalnamespaces.temporal.io",
    "temporalschedules.temporal.io",
    "temporalclusterclients.temporal.io",
]

def temporal_install(
        name,
        namespace = "temporal-system",
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned temporal-operator manifest into `namespace`
    and block until the operator Deployment is Available AND the 4
    consumer-facing CRDs are registered before idling.

    Drops into `itest_service.exe`. Wait timeout 300s — the operator
    image is small (~70 MB); cold pulls clear comfortably under 5
    minutes.

    **Requires cert-manager installed upstream** — the operator's
    manifest includes a Certificate CR + Issuer CR for its admission
    webhook serving cert. Without cert-manager's CRDs the apply
    fails at validation. Wire `cert_manager_install` (from
    `rules_certmanager`) as an `itest_service` dep ahead of this.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_temporal//private/manifests:temporal_operator.yaml"],
        namespace = namespace,
        # Bundle includes a Namespace resource, so create_namespace
        # is unnecessary — apply idempotence makes setting it a
        # no-op, but explicit False keeps the surface honest.
        create_namespace = False,
        server_side = True,
        wait_for_deployments = [_OPERATOR_DEPLOY] + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(_OPERATOR_CRDS) + list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def temporal_install_health_check(
        name,
        namespace = "temporal-system",
        **kwargs):
    """Readiness probe paired with `temporal_install`. Same wait
    shape with `--timeout=0s`.

    Named `_install_health_check` (not just `_health_check`) to
    avoid colliding with the v0.1/v0.2 `temporal_health_check`
    macro, which pairs with `temporal_server` (the test-time
    Temporal launcher). Both health checks coexist; pick the one
    matching your install vs test composition.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = [_OPERATOR_DEPLOY] + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(_OPERATOR_CRDS) + list(extra_crds),
        **kwargs
    )
