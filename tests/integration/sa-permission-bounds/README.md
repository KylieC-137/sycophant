# sa-permission-bounds/

Tests that pin the upper bound of each ServiceAccount's authority. Each
test impersonates an SA and asserts a specific action is denied —
whether the wall is RBAC (`kubectl auth can-i` or a real `create`
returning Forbidden) or admission (a ValidatingAdmissionPolicy or
Kyverno rule rejecting the request).

| Test                                  | What it proves                                                                |
|---------------------------------------|-------------------------------------------------------------------------------|
| provision-write-scope/                | provision-write creates Secrets but `get`s only relay-registered-keys and adapter-state, and writes only in its bound namespace |
| provision-identity-rolebinding/       | The tenant chart binds exactly the listed `users` to ClusterRole/provision-identity, nothing when unset, and rejects a subject with a quote, backslash, control character, or U+2028 |
| provision-identity-clusterrole-minimal/ | The provision-identity ClusterRole has no rules and no aggregation |
| relay-ctrl-grants-and-key-rbac/   | The chart-rendered relay-controller Role grants exactly its grants and key verbs |
| relay-ctrl-no-secret-updates/     | relay's Secret writes are name-scoped to relay-registered-keys, and it can delete none |
| relay-secret-name-allowlist/      | relay may only create the Secret named relay-registered-keys; an adapter only adapter-state |
| workspace-sa-no-verbs/                | workspace SA has zero K8s API verbs                                           |

Belongs here: SA-impersonation probes (`kubectl --as` or `kubectl auth
can-i`) asserting denied actions, regardless of which layer enforces.
Doesn't belong here: tests scoped to a particular workload shape (see
`harness-pod-shape/`) or a specific tenant-resource lifecycle (see
`tenant-resource-protection/`).
