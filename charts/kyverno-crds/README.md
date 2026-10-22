# kyverno-crds

Vendored Kyverno CRDs. Sibling of the upstream `kyverno` chart.

## Why a separate chart

When `sycophant-quickstart` bundles Kyverno, `helm uninstall sycophant-quickstart`
would delete every CRD Kyverno owns — cascading into every `ClusterPolicy`,
`PolicyException`, etc. in the cluster. Splitting CRDs into a sibling chart
puts them in their own helm release so `helm uninstall` of the quickstart
leaves them registered. Operator policies survive. Matches the Linkerd /
Karpenter sibling-CRDs pattern.

The CRDs are also placed in helm's `crds/` directory, which is install-only
and never deleted by `helm uninstall` even of this chart — double-belted
retention.

## Install

```sh
helm install kyverno-crds charts/kyverno-crds
```

Run before `helm install kyverno ...`. The quickstart meta-chart handles the
ordering automatically via its `dependencies:` block.

## Bump procedure

When bumping the Kyverno minor version:

1. `helm repo update kyverno`
2. `helm pull kyverno/kyverno --version <new> --untar --untardir /tmp/`
3. Render with CRDs on and split one file per CRD, named `<plural>.<group>.yaml`:
   ```sh
   helm template kyverno /tmp/kyverno \
     --set crds.install=true --set openreports.installCrds=false
   ```
   The CRDs come from two subcharts, both gated on `crds.install`: `crds`
   (kyverno.io, reports.kyverno.io, wgpolicyk8s.io) and the separate
   `kyverno-api` dependency (policies.kyverno.io). Both must be rendered.
4. Strip the five helm release labels the render stamps on every CRD —
   `app.kubernetes.io/{instance,managed-by,part-of,version}` and
   `helm.sh/chart`. They name the upstream release, not this one, and this
   chart owns the objects.
5. Strip every `description` field (see below). Everything else is verbatim.
6. Bump `Chart.yaml` `appVersion` and (semver-appropriate) `version`, and the
   version named in `values.yaml`.
7. Diff the `crds/` tree against the previous version. Eyeball schema changes
   for breaking field renames; flag in the chart's CHANGELOG.

`crds.install` stays `false` on the engine release so a Kyverno reinstall
cannot cascade-delete the CRDs this chart owns.

## Why descriptions are stripped

A helm release is stored in a Secret, and Kubernetes caps a Secret at 1 MiB.
The full upstream CRD set is 5.6 MB of YAML, and `helm install` of this chart
fails outright above that cap — the CEL policy types and their `Namespaced*`
variants are what pushed it over. Descriptions are about two thirds of that
text and carry no validation behaviour: they are the help text `kubectl
explain` prints. Dropping them takes the tree to 1.9 MB and changes nothing
the apiserver enforces. The cost is that `kubectl explain` on a Kyverno type
prints field names without prose; read the upstream docs instead.

Strip line-wise rather than by re-serialising the document, so the remaining
bytes stay identical to what upstream rendered and step 7's diff still means
something. Verify by parsing both the original and the stripped file and
asserting they are equal once descriptions are removed from the original.
