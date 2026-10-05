# integration tests

Live-cluster admission and RBAC tests using chainsaw. Each directory is a
named security property. Tests inside route through real sycophant code. The
tenant namespace comes from the tenant-namespace fixture with real perimeter labels.

## Buckets

| Bucket                          | Property under test                                                  |
|---------------------------------|----------------------------------------------------------------------|
| privileged-workload-rejection/  | PSA rejects privileged pods in sycophant namespaces (orthogonality)  |
| harness-pod-shape/            | Harness VAP enforces every required field on harness pods    |
| tenant-namespace-creation/      | Perimeter label triggers per-tenant wiring; any name, any creator    |
| tenant-resource-protection/     | Same-ns SAs cannot tamper with their own NetworkPolicy/RBAC/etc.     |
| job-egress-baselines/           | toolset (capability-job) egress shape: chart fail-closed floor is L7, not L4-only |
| sa-permission-bounds/           | provisioner + controller SAs hold only the verbs/names claimed       |
| sa-token-audience/              | Apiserver enforces SA-token audience: one token, one controller      |
| cluster-resources/              | Chart-shipped cluster-scoped resources (RuntimeClass, etc.) shape    |
| gvisor-scope/                   | gVisor runtime scope pinned to toolsets only (capability-job); other components on runc |
| conversation-log-mount/         | Only the harness may mount the `conversation-data-*` PVC (VAP, label-agnostic)   |
| relay-access-grants/            | The deployed relay reconciles the chart-created relay-access-grants ConfigMap |
| inference-workload/             | Applied shape of the in-cluster inference server and its fence |
| namespace-egress-baseline/      | Namespace-wide egress default-deny floor; uncovered pods denied |
| capability-job-gate/            | Identity-keyed Job CREATE gate: harness-<ws> Jobs forced into the envelope + secret allowlist or denied; the two per-workspace SAs |

## Picking a bucket for a new test

Ask: "What property is this test asserting?"

- Pod admission shape under VAP → `harness-pod-shape/`
- Namespace lifecycle (create / label / name) → `tenant-namespace-creation/`
- Same-tenant write isolation → `tenant-resource-protection/`
- Job creation gated on creator identity → `capability-job-gate/`
- toolset (capability-job) egress policy shape (chart baseline floor) → `job-egress-baselines/`
- Verb-by-actor or name-by-actor (SA impersonation) → `sa-permission-bounds/`
- SA-token audience handling → `sa-token-audience/`
- Chart-shipped cluster-scoped resource shape → `cluster-resources/`
- gVisor runtime scope (toolsets only) → `gvisor-scope/`
- Relay reconciling the relay-access-grants ConfigMap → `relay-access-grants/`
- Applied pod shape or network fence of the in-cluster inference server →
  `inference-workload/`
- Namespace-wide egress default-deny floor, or a pod left uncovered by it →
  `namespace-egress-baseline/`
- Job CREATE forced into a hardened, secret-bounded pod template keyed on the
  creating harness identity (mutate + validate) → `capability-job-gate/`
- "PSA does X" — usually wrong bucket; PSA is upstream, not sycophant.
- Tenant chart render shape that needs no cluster → `tests/unit/tenant-chart/`,
  not chainsaw.

Do not create a `misc/` or `other/` bucket. Force a property decision.

## Running

```bash
chainsaw test tests/integration --config tests/integration/.chainsaw.yaml
chainsaw test tests/integration/tenant-resource-protection --config tests/integration/.chainsaw.yaml
chainsaw test tests/integration/harness-pod-shape/projected-sa-token-rejected --config tests/integration/.chainsaw.yaml
```

## Authoring conventions

- Tenant namespaces are created by the test harness's own kubeconfig (`kubectl create namespace X`, or the shared `step-templates/tenant.yaml`), then the test applies the perimeter labels itself (`app.kubernetes.io/part-of=sycophant-tenant` + the four `pod-security.kubernetes.io/*` labels) — there is no auto-labelling mutate; labeling is the namespace creator's job (chart `tenant-ns.yaml` in prod). At runtime Kyverno materializes the namespace from the tenant provision command, and no ServiceAccount holds `namespaces:create` — the Kyverno background controller does. The label is what triggers the generate rule that produces the per-tenant VAPBinding + tokenreview CRBs; wait for that wiring before the test workload submits.
- Pod fixtures live in `fixtures/` and use `($target_namespace)` for templated namespace. Inline pod manifests in the test file are fine for one-offs.
- Tenant-namespace setup and teardown go through the shared `step-templates/tenant.yaml` StepTemplate: a `create-tenant-ns` step calls it with `use.template` and passes the name via `with.bindings` (`tenant_ns: ($tenant_ns)`). The template applies `fixtures/tenant-namespace.yaml` and deletes the namespace in `spec.cleanup`, which runs after the whole test. Do not add a namespace-delete `finally:` alongside it. Use the plain `finally:` form only for tests whose setup does more than the bare namespace (extra NetworkPolicy or egress floor) — those stay hand-rolled.
- Gotcha: a StepTemplate must NOT declare a `spec.bindings` default for a binding it expects from the call site. A `spec.bindings` default SHADOWS the `with.bindings` value the caller passes, so the namespace would be created and deleted under the default name, not the test's. `tenant.yaml` declares no default for `tenant_ns` on purpose.
- For impersonation across multiple identities in one test, use `script:` blocks with `kubectl --as=...`. The `command:` form gives cleaner diagnostics but is one-arg-set per step.
- Match denial messages on the shortest unique substring of the policy's `message:` field. Long matches break the moment someone reflows the YAML.
