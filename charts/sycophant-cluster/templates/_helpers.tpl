{{/*
Guard for the Kyverno policies. The cluster chart always renders them; this
helper only fails loudly when the Kyverno CRDs are absent, so a Kyverno-less
cluster errors at install instead of silently shipping without the
tenant-isolation policies. `fail` fires on `include`, so the guard cannot be
bypassed. Installing the Kyverno controller is a cluster prerequisite the
operator or the quickstart bundle handles, not a chart values knob.

The probe is ValidatingPolicy because the CEL types arrived after the legacy
ones: a cluster whose CRDs predate it cannot serve any policy this chart ships.
*/}}
{{- define "sycophant.renderKyverno" -}}
{{- if not (.Capabilities.APIVersions.Has "policies.kyverno.io/v1/ValidatingPolicy") -}}
{{- fail "the Kyverno CRDs are absent (policies.kyverno.io/v1/ValidatingPolicy not found). Install the kyverno-crds chart (or run `syco setup`, which installs Kyverno) before installing sycophant-cluster." -}}
{{- end -}}
true
{{- end -}}

{{/*
Tenant lifecycle marker contract. The marker is a plain ConfigMap identified by
the well-known label below; the reserved name in each reactor's match block
selects the operation. Schema keys are tenant, capacity, keepalive; there is no
authority field. One source so the provision VAP and the reactor policies stay
in step.
*/}}
{{- define "sycophant.lifecycleMarkerLabel" -}}sycophant.md/lifecycle-marker{{- end -}}
{{- define "sycophant.provisionMarkerName" -}}sycophant-tenant-provision{{- end -}}
{{- define "sycophant.suspendMarkerName" -}}sycophant-tenant-suspend{{- end -}}
{{- define "sycophant.reapAfterAnnotation" -}}sycophant.md/reap-after{{- end -}}

{{/*
The capability job gate's creating identity, shared by its mutate and its
validate so the two cannot drift onto different notions of "the workspace".

`parseServiceAccount` pulls NS/NAME out of `system:serviceaccount:NS:NAME`.
The match conditions are the gate: the creator must be a ServiceAccount in the
namespace it is writing to, and its name must be `harness-<workspace>`. A Job
from any other identity is not this gate's business and falls through to the
rest of admission.
*/}}
{{- define "sycophant.capabilityJobGateIdentity" -}}
matchConditions:
  - name: creator-is-a-harness-in-this-namespace
    expression: >-
      request.userInfo.username.startsWith("system:serviceaccount:")
        && parseServiceAccount(request.userInfo.username).Namespace == request.namespace
        && parseServiceAccount(request.userInfo.username).Name.startsWith("harness-")
variables:
  - name: workspace
    expression: >-
      parseServiceAccount(request.userInfo.username).Name.substring(8)
  - name: pod
    expression: "object.spec.template.spec"
  - name: containers
    expression: "variables.pod.containers"
  - name: initContainers
    expression: "variables.pod.?initContainers.orValue([])"
  - name: allContainers
    expression: "variables.containers + variables.initContainers"
{{- end -}}

{{- define "sycophant.labels" -}}
{{ include "sycophant.baseLabels" . }}
app.kubernetes.io/part-of: sycophant
{{- end -}}

{{/*
`sycophant.labels` without `part-of`, for the one resource that carries a
different one: the generated tenant Namespace is `part-of: sycophant-tenant`,
which is the label every tenant-scoped policy triggers on. Emitting both would
be a duplicate mapping key, which a generate template is parsed strictly enough
to reject.
*/}}
{{- define "sycophant.baseLabels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
The IdP user prefix the apiserver stamps on an OIDC identity, `<issuer>#`.
Shared so the positive gate in `provision-marker-vap.yaml` and the negative
gate below cannot drift onto different notions of an IdP user.
*/}}
{{- define "sycophant.idpUserPrefix" -}}{{ .Values.idp.issuer }}#{{- end -}}

{{/*
Kyverno match condition: the policy applies to the principals a tenant can
reach, which is a ServiceAccount inside the request namespace or a user
identity the cluster's IdP minted. Those two classes live inside the blast
radius. Scopes tenant-operator writes to its own tenant; defends against a
cross-tenant RoleBinding leak.

Every other caller falls through unmatched and is admitted: the chart
deployer and the Kyverno controllers, ServiceAccounts in operator-owned
namespaces, and the operator's own cluster kubeconfig, which is what
`cluster-chart-admin` break-glass rides on.

An IdP user writes a lifecycle marker and a scoped ServiceAccount does the
work. The marker carries `sycophant.md/lifecycle-marker`, never
`sycophant.md/type`, so no validation here fires on it.

`parseServiceAccount` pulls the namespace out of
`system:serviceaccount:NS:NAME`; the prefix test guards the parse.
*/}}
{{- define "sycophant.kyvernoTenantScopedCallerMatchCondition" -}}
matchConditions:
  - name: caller-is-scoped-to-this-tenant
    expression: >-
      (request.userInfo.username.startsWith("system:serviceaccount:")
        && parseServiceAccount(request.userInfo.username).Namespace == request.namespace)
        || request.userInfo.username.startsWith("{{ include "sycophant.idpUserPrefix" . }}")
{{- end -}}

{{/*
The sycophant.md CRD resources the per-tenant operator role manages.
Mirrored verbatim into `kyverno-rbac-aggregation.yaml` so kyverno's
RoleBinding generate rule passes K8s anti-escalation. Adding a CRD to
the framework requires updating ONLY this helper (and the
tenant-deployer ClusterRole separately — its verbs and resource set
differ).
*/}}
{{- define "sycophant.operatorCrds" -}}
- "clients"
{{- end -}}

{{/*
Status subresources matching `sycophant.operatorCrds`. Kept in
parallel rather than computed from the base list so Helm rendering
stays trivially predictable; divergence risk is the same as the base
list (both staked on the same mirror invariant).
*/}}
{{- define "sycophant.operatorCrdStatuses" -}}
- "clients/status"
{{- end -}}
