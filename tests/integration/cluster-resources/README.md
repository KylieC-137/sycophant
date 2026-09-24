# cluster-resources/

Chart-shipped cluster-scoped resource shape checks. Each test asserts a
single cluster-scoped object (RuntimeClass, ClusterPolicy, etc.) exists
with its expected fields. Separate from `harness-pod-shape/` (which is
Pod admission) and `tenant-resource-protection/` (which is per-tenant).

| Test                                    | What it proves                                                          |
|-----------------------------------------|------------------------------------------------------------------------|
| runtimeclass-gvisor-handler/            | `RuntimeClass/gvisor` declares `handler: runsc` (real gVisor)          |
| cluster-chart-always-renders-kyverno/   | The chart renders with no policyEngine set and always emits the Kyverno policies |
| cluster-chart-requires-kyverno-crds/    | Rendering without the Kyverno CRDs hard-fails naming the missing CRD    |
| provision-marker-vap-identity-only/     | The provision-marker VAP admits only an issuer-prefixed username        |
| provision-generates-namespace-and-quota/ | The provision generate policy emits the tenant Namespace + capacity ResourceQuota |
| provision-generates-rolebinding/        | The generator emits the tenant-deployer RoleBinding binding the deployer SA to the tenant-operator ClusterRole |
| suspend-marker-scales-to-zero/          | The suspend mutate scales the tenant Deployments to zero               |
| delete-cleanuppolicy-reaps-namespace/   | Delete is a legacy CleanupPolicy reaping the Namespace, no PV-Retain    |
| keepalive-restricted-to-policy-values/  | Keepalive is constrained to 0, 30, 60, 90                             |
| background-controller-holds-namespace-create/ | The Kyverno bg-controller role grants create on Namespaces + ResourceQuotas |
| lifecycle-artifacts-omit-saas-vocab/    | Rendered artifacts carry no SaaS identity (organization, customer)      |

Belongs here: chainsaw assertions on cluster-scoped resources shipped by
the chart (sycophant-cluster, sycophant-gvisor, kyverno-crds). Doesn't
belong here: pod admission (`harness-pod-shape/`), tenant lifecycle
(`tenant-resource-protection/`, `tenant-namespace-creation/`), or SA
impersonation (`sa-permission-bounds/`).
