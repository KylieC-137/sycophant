# tenant-resource-protection/

Once a tenant namespace exists, same-namespace ServiceAccounts cannot tamper
with the resources that define their security boundary. The
`cluster-protect-security` ValidatingPolicy holds one validation per protected
resource kind. External callers (cluster-admin, operator-owned ServiceAccounts)
are excluded by the match condition, which fires only for a caller inside the
namespace it is writing to.

One test per protected resource:
- `capability-grants-configmap-immutable/` — an in-namespace SA cannot
  create, update, or delete a ConfigMap labeled
  `sycophant.md/type=capability-grants`
- `cilium-network-policy-immutable/` — an in-namespace SA cannot CRUD a
  CiliumNetworkPolicy in its own namespace
- `grants-configmap-immutable/` — an in-namespace SA cannot create, update, or
  delete the relay-access-grants ConfigMap
- `network-policy-immutable/` — an in-namespace SA cannot create, update, or
  delete a NetworkPolicy
- `rbac-roles-immutable/` — an in-namespace SA cannot CRUD Roles or
  RoleBindings in its own namespace
- `workspace-admission-rule-immutable/` — the most privileged tenant identity
  cannot delete or change the cluster-wide gVisor rule
- `workspace-service-accounts-immutable/` — an in-namespace SA cannot CRUD the
  workspace ServiceAccounts

Plus:
- `external-sa-can-write/` — pair test proving the check isn't a blanket deny
- `policy-write-verbs-are-admin-only/` — protects the policies themselves.
  Admission cannot guard them, so the assertion is on RBAC.

Belongs here: same-ns write/update/delete denials.
Doesn't belong here: rules gated on caller identity that's NOT same-ns
(see `capability-job-gate/` for the identity-keyed Job CREATE gate).
