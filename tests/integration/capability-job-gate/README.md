# capability-job-gate

An admission gate on Job CREATE, keyed on the creator's authenticated identity
`system:serviceaccount:<ns>:ws-<ws>`, forces the Job's pod template into a
hardened, zero-RBAC sandbox bounded to the workspace's operator-approved secrets,
or denies the Job. Two per-workspace ServiceAccounts carry the create/run split:
`ws-<ws>` holds only `create` on `batch/jobs`; `ws-<ws>-unprivileged` holds no
RBAC and automounts no token.

The gate keys on the unforgeable creating identity, never on a self-asserted pod
label. Workspace W's Job may mount only W's approved Secret names, read from the
`ws-<ws>-capability-grants` ConfigMap.

## Denial contract

The gate is a single Kyverno `ClusterPolicy` named **`cluster-capability-job-gate`**
(`background: false`, `validationFailureAction: Enforce`). The deny cases run
offline in `tests/unit/kyverno-policies/capability-job-gate-as-harness/`. Each
deny case is well-formed in every respect except the one field it targets, so with
the targeted rule removed the Job admits and the case goes red — no case passes on
a policy missing the rule it targets.

## Tests

| Test                               | Property                                                       |
|------------------------------------|----------------------------------------------------------------|
| well-formed-job-admits-and-stamps/ | A well-formed harness Job admits and is stamped with the envelope, `component: capability-job`, and `workspace` overwritten from identity (live) |
| policy-exception-admits/           | A gate-denied Job admits when a matching Kyverno PolicyException exists (live) |

The render checks for the two ServiceAccounts live in `tests/unit/tenant-chart/`.
Live tests impersonate the creator with
`kubectl --as system:serviceaccount:<ns>:ws-<ws>` and observe admit/deny at
admission; they need a cluster because identity-keyed admission is not visible to a
render.
