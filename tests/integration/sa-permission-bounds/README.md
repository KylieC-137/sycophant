# sa-permission-bounds/

Tests that pin the upper bound of each ServiceAccount's authority. Each
test impersonates an SA and asserts a specific action is denied —
whether the wall is RBAC (`kubectl auth can-i` or a real `create`
returning Forbidden) or admission (a ValidatingAdmissionPolicy or
Kyverno rule rejecting the request).

| Test                                  | What it proves                                                                |
|---------------------------------------|-------------------------------------------------------------------------------|
| channel-secret-name-allowlist/    | a channel may only create the Secret named tailnet-identity, and only in its own namespace |

The render-time bounds (provision-write, provision-identity, the relay-controller
Role) live in `tests/unit/provision-installer/` and `tests/unit/tenant-chart/`.

Belongs here: SA-impersonation probes (`kubectl --as` or `kubectl auth
can-i`) asserting denied actions, regardless of which layer enforces.
Doesn't belong here: tests scoped to a particular workload shape (see
`harness-pod-shape/`) or a specific tenant-resource lifecycle (see
`tenant-resource-protection/`).
