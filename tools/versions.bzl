"""Maintainer-side: temporal-operator manifest pin.

The operator publishes TWO release assets per version (CRDs and
non-CRDs are split — CRDs are large, ~338 KB, non-CRDs ~9 KB).
We concatenate them in CRDs-first order at maintainer-render
time so consumers apply ONE combined file. Concatenation
sequence ensures the temporal CRDs are in place before the
operator's Deployment + webhook configs reference them.
"""

TEMPORAL_OPERATOR_VERSIONS = {
    "v0.22.0": {
        "crds_url": "https://github.com/alexandrevilain/temporal-operator/releases/download/v0.22.0/temporal-operator.crds.yaml",
        "crds_sha256": "d0a3070f9c6ac96c21dca9527d79bef62b4b80daf29ebd6c2b7b85e6bbf111bb",
        "operator_url": "https://github.com/alexandrevilain/temporal-operator/releases/download/v0.22.0/temporal-operator.yaml",
        "operator_sha256": "56770eb7aa114513594cccbff95a231cb27ba4c572c4b897081714999e7763c1",
    },
}
