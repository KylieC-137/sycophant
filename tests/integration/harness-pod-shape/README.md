# harness-pod-shape/

Harness pods (labeled `app.kubernetes.io/part-of=sycophant` +
`component=harness`) must conform to a strict shape enforced by the
`cluster-gvisor-pod-policy` VAP. `non-compliant-pods-rejected` runs one step
per CEL expression; `compliant-pod-admits` is the happy-path admit test.

Tenant namespaces come from the tenant-namespace fixture, whose perimeter
label makes Kyverno generate the per-tenant VAPBinding before the test pod
submits. If the VAPBinding is missing, the VAP cannot fire, and the test must
catch that as a red, not silently admit.

Belongs here: any constraint the VAP enforces on harness-labeled pods.
Doesn't belong here: PSA-driven rejections (PSA is upstream, not sycophant),
non-pod resources.
