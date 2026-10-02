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
Lifecycle marker contract: a ConfigMap carrying the label below, whose reserved
name selects the reactor. The tenant prefix keeps every provisioned namespace
out of the reserved ones.
*/}}
{{- define "sycophant.lifecycleMarkerLabel" -}}sycophant.md/lifecycle-marker{{- end -}}
{{- define "sycophant.provisionMarkerName" -}}provision-tenant{{- end -}}
{{- define "sycophant.workspaceProvisionMarkerName" -}}provision-workspace{{- end -}}
{{- define "sycophant.userProvisionMarkerName" -}}provision-user{{- end -}}
{{- define "sycophant.toolsetProvisionMarkerName" -}}provision-toolset{{- end -}}
{{- define "sycophant.suspendMarkerName" -}}suspend-tenant{{- end -}}
{{- define "sycophant.reapAfterAnnotation" -}}sycophant.md/reap-after{{- end -}}
{{- define "sycophant.tenantNsPrefix" -}}tenant-{{- end -}}

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

{{/*
Match for the reactors on the tenant marker in sycophant-system. A free-form
keepalive matches nothing, so nothing is stamped.
*/}}
{{- define "sycophant.provisionMarkerSystemMatchConstraints" -}}
matchConstraints:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: sycophant-system
  objectSelector:
    matchLabels:
      {{ include "sycophant.lifecycleMarkerLabel" . }}: "true"
  resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["configmaps"]
      resourceNames: ["{{ include "sycophant.provisionMarkerName" . }}"]
matchConditions:
  - name: keepalive-is-a-policy-value
    expression: >-
      object.?data["keepalive"].orValue("") in ["0", "30", "60", "90"]
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

{{/* The IdP user prefix the apiserver stamps on an OIDC identity, `<issuer>#`. */}}
{{- define "sycophant.idpUserPrefix" -}}{{ .Values.idp.issuer }}#{{- end -}}
