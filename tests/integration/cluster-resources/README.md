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
| marker-provision-tenant-vap-identity-only/     | The provision-tenant marker VAP admits only an issuer-prefixed username        |
| provision-generates-namespace-and-quota/ | The provision generate policy emits the tenant Namespace + capacity ResourceQuota |
| suspend-marker-scales-to-zero/          | The suspend mutate scales the tenant Deployments to zero               |
| keepalive-restricted-to-policy-values/  | Keepalive is constrained to 0, 30, 60, 90                             |
| background-controller-holds-namespace-create/ | The Kyverno bg-controller role grants create on Namespaces + ResourceQuotas |
| provision-tenant-workspace-user-toolset-installer-set-shape/ | Each provision-<kind> installer pair emits SA+Job+RoleBinding, one provision-<kind>-<handle> name, reap-after, provision-write roleRef |
| reap-tenant-workspace-user-toolset-deletingpolicy-shape/ | Each reap-<kind> DeletingPolicy runs on a schedule, selects provision-<kind>, reaps past reap-after, no PV-Retain; reap-tenant also reaps the namespace |
| provision-tenant-marker-materializes-installer/ | LIVE: an admitted provision-tenant marker materializes the SA+Job+RoleBinding installer set; its values reach the base release unchanged |
| provision-workspace-marker-materializes-installer/ | LIVE: an admitted provision-workspace marker materializes its installer set |
| provision-tenant-marker-vap-validates-data/ | LIVE: the provision-tenant marker VAP denies a bad handle, bad capacity, missing values, or a token over its release cap; admits a valid marker and a token at the cap |
| slice-marker-vap-validates-data/ | LIVE: the workspace, toolset, and user marker VAPs deny a name over its release cap and a user subject with a quote, CR, or U+2028; admit a name at the cap |
| workspace-sa-name-forms/                | Every rendered `sycophant.md/type=workspace-sa` SA is named `harness-<ws>`, `unprivileged-<ws>`, or `<ws>-workspace-init` (in sync with WORKSPACE_SA_PREFIXES) |

Belongs here: chainsaw assertions on the shape or render-time naming of
resources shipped by the charts (sycophant-cluster, sycophant-gvisor,
kyverno-crds, sycophant-tenant). Doesn't
belong here: pod admission (`harness-pod-shape/`), tenant lifecycle
(`tenant-resource-protection/`, `tenant-namespace-creation/`), or SA
impersonation (`sa-permission-bounds/`).
