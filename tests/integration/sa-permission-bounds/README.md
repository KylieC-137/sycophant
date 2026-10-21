# sa-permission-bounds/

Tests that pin the upper bound of each ServiceAccount's authority. Each
test impersonates an SA and asserts a specific action is denied —
whether the wall is RBAC (`kubectl auth can-i` or a real `create`
returning Forbidden) or admission (a ValidatingAdmissionPolicy or
Kyverno rule rejecting the request).

| Test                                  | What it proves                                                                |
|---------------------------------------|-------------------------------------------------------------------------------|
| provision-write-scope/                | provision-write creates Secrets but `get`s only adapter-state, and writes only in its bound namespace |
| provision-identity-clusterrole-minimal/ | The provision-identity ClusterRole has no rules and no aggregation |
| relay-ctrl-identity-rbac/         | The chart-rendered relay-controller Role reads the identity ConfigMaps read-only and spawns no workload |
| relay-ctrl-no-secret-updates/     | the relay holds no Secret verbs at all: create, patch, and delete each fail, and get, list, and watch are denied |
| adapter-secret-name-allowlist/    | an adapter may only create the Secret named adapter-state, and only in its own namespace |
| workspace-sa-no-verbs/                | workspace SA has zero K8s API verbs                                           |

Belongs here: SA-impersonation probes (`kubectl --as` or `kubectl auth
can-i`) asserting denied actions, regardless of which layer enforces.
Doesn't belong here: tests scoped to a particular workload shape (see
`harness-pod-shape/`) or a specific tenant-resource lifecycle (see
`tenant-resource-protection/`).
