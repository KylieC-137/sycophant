# cluster-resources/

Chart-shipped resource shape and naming checks. Most assert a single
cluster-scoped object (RuntimeClass, Kyverno policy, etc.) exists with its
expected fields; some pin the render-time name shape of chart-shipped
resources. Separate from `harness-pod-shape/` (which is Pod admission)
and `tenant-resource-protection/` (which is per-tenant).

| Test                                    | What it proves                                                          |
|-----------------------------------------|------------------------------------------------------------------------|
| runtimeclass-gvisor-handler/            | `RuntimeClass/gvisor` declares `handler: runsc` (real gVisor)          |
| cluster-chart-requires-kyverno-crds/    | Rendering without the Kyverno CRDs hard-fails naming the missing CRD    |
| provision-generates-namespace-and-quota/ | The provision generate policy emits the tenant Namespace + capacity ResourceQuota |
| suspend-command-scales-to-zero/          | The suspend mutate scales the tenant Deployments to zero               |
| background-controller-holds-namespace-create/ | The Kyverno bg-controller role grants create on Namespaces + ResourceQuotas |
| provision-tenant-command-materializes-installer/ | LIVE: an admitted tenant provision command materializes the uid-named SA+Job+RoleBinding installer set; the Job succeeds; the Job deletes the command |
| workspace-sa-name-forms/                | Every rendered `sycophant.md/type=workspace-sa` SA is named `harness-<ws>`, `unprivileged-<ws>`, or `<ws>-workspace-init` (in sync with WORKSPACE_SA_PREFIXES) |

Belongs here: chainsaw assertions on the shape or render-time naming of
resources shipped by the charts (sycophant-cluster, sycophant-gvisor,
kyverno-crds, sycophant-tenant). Doesn't
belong here: pod admission (`harness-pod-shape/`), tenant lifecycle
(`tenant-resource-protection/`, `tenant-namespace-creation/`), or SA
impersonation (`sa-permission-bounds/`).
