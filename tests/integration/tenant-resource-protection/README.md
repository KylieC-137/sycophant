# tenant-resource-protection/

Once a tenant namespace exists, same-namespace ServiceAccounts cannot tamper
with the resources that define their security boundary. The
`cluster-protect-security` ValidatingPolicy holds one validation per protected
resource kind. External callers (cluster-admin, operator-owned ServiceAccounts)
are excluded by the match condition, which fires only for a caller inside the
namespace it is writing to.

The per-resource denials run offline in `tests/unit/kyverno-policies/`. The
cluster-wide gVisor rule cannot be guarded at admission; the provision-installer
provision-write check in `tests/unit/provision-installer/` pins that the
installer's role reaches no admission rule. Live here:
- `network-policy-immutable/` — an in-namespace SA cannot create, update, or
  delete a NetworkPolicy

Plus:
- `external-sa-can-write/` — pair test proving the check isn't a blanket deny
- `policy-write-verbs-are-admin-only/` — protects the policies themselves.
  Admission cannot guard them, so the assertion is on RBAC.

Belongs here: same-ns write/update/delete denials.
Doesn't belong here: rules gated on caller identity that's NOT same-ns
(see `capability-job-gate/` for the identity-keyed Job CREATE gate).
