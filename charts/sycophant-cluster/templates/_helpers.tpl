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

{{- /*
One single-shot install per lifecycle marker. The stack policy stamps a
ServiceAccount and a Job in sycophant-system; the Job runs `helm upgrade
--install` against the tenant chart baked into the installer image, presenting
the ServiceAccount's projected token. The ServiceAccount lives outside the
tenant namespace, so it stays an external caller to the tenant-scoped write
protections and needs no exemption from them.

The grant policy binds that ServiceAccount to ClusterRole/provision-write in the
tenant namespace, so RBAC bounds its reach to that one namespace. It is a
separate policy because its target namespace may not exist yet (the tenant
marker's sibling reactor creates it), and its retry must never re-apply the Job,
whose spec.selector is immutable. Both the ServiceAccount and the RoleBinding
carry a reap-after annotation the scheduled reap sweeps.

The tenant marker lives in sycophant-system and installs the base release. Its
values ride into the Job as an env var, since the installer cannot read
sycophant-system. Every other marker lives in the tenant namespace it targets,
so the tenant is the marker's own namespace, and installs one `<kind>-<name>`
release with render=<kind>. render and namespace.create=false are forced on the
command line so a marker cannot change the slice it renders or manage the
namespace.

A re-written marker re-runs its installer, which upgrades the release in place.
The slices render disjoint object sets, so no slice takes another's.
*/ -}}
{{- define "sycophant.provisionInstallerMatch" -}}
{{- $ctx := .ctx -}}
{{- if eq .kind "tenant" -}}
{{ include "sycophant.provisionMarkerSystemMatchConstraints" $ctx }}
{{- else -}}
{{- $marker := printf "provision-%s" .kind -}}
matchConstraints:
  namespaceSelector:
    matchLabels:
      app.kubernetes.io/part-of: sycophant-tenant
  objectSelector:
    matchLabels:
      {{ include "sycophant.lifecycleMarkerLabel" $ctx }}: "true"
  resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["configmaps"]
      resourceNames: ["{{ $marker }}"]
# A webhook rule cannot filter by resourceName, and the generate handler queues
# an update request before the name is checked. The apiserver honors webhook
# matchConditions, so this drops a foreign marker before Kyverno is called.
matchConditions:
  - name: marker-name-is-the-{{ .kind }}-marker
    expression: >-
      object.metadata.name == '{{ $marker }}'
{{- end }}
variables:
  {{- if and .stack (has .kind (list "workspace" "toolset")) }}
  - name: {{ .kind }}
    expression: 'object.data["{{ .kind }}"]'
  {{- end }}
  {{- if and .stack (eq .kind "tenant") }}
  # The kubelet expands $(VAR) and collapses $$ in env values, so every $ is
  # doubled to arrive unchanged.
  - name: values
    expression: 'object.data["values"].replace("$", "$$")'
  {{- end }}
  - name: tenant
{{- if eq .kind "tenant" }}
    expression: '"{{ include "sycophant.tenantNsPrefix" $ctx }}" + object.data["tenant"]'
{{- else }}
    expression: 'object.metadata.namespace'
{{- end }}
  - name: handle
    expression: 'object.data["handle"]'
  # Past the Job's activeDeadline, so the reap removes the identity only after
  # the install has finished or timed out.
  - name: reapAfter
    expression: 'string(time.now() + duration("1800s"))'
{{- end -}}

{{- define "sycophant.provisionInstaller" -}}
{{- $ctx := .ctx -}}
{{- $kind := .kind -}}
{{- $component := printf "provision-%s" $kind -}}
{{- $env := dict "workspace" "WORKSPACE" "toolset" "TOOLSET" "user" "HANDLE" -}}
apiVersion: policies.kyverno.io/v1
kind: GeneratingPolicy
metadata:
  name: {{ ternary "provision-tenant-stack" $component (eq $kind "tenant") }}
  labels:
    {{- include "sycophant.labels" $ctx | nindent 4 }}
spec:
  evaluation:
    generateExisting:
      enabled: false
    synchronize:
      enabled: false
  {{- include "sycophant.provisionInstallerMatch" (dict "ctx" $ctx "kind" $kind "stack" true) | nindent 2 }}
  generate:
    - template:
        interpolate: cel
        value: |
          apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: (( "{{ $component }}-" + variables.handle ))
            namespace: sycophant-system
            labels:
              {{- include "sycophant.labels" $ctx | nindent 14 }}
              app.kubernetes.io/component: {{ $component }}
            annotations:
              {{ include "sycophant.reapAfterAnnotation" $ctx }}: (( variables.reapAfter ))
          ---
          apiVersion: batch/v1
          kind: Job
          metadata:
            name: (( "{{ $component }}-" + variables.handle ))
            namespace: sycophant-system
            labels:
              {{- include "sycophant.labels" $ctx | nindent 14 }}
              app.kubernetes.io/component: {{ $component }}
          spec:
            backoffLimit: 4
            activeDeadlineSeconds: 900
            ttlSecondsAfterFinished: 600
            template:
              metadata:
                labels:
                  {{- include "sycophant.labels" $ctx | nindent 18 }}
                  app.kubernetes.io/component: {{ $component }}
              spec:
                restartPolicy: OnFailure
                serviceAccountName: (( "{{ $component }}-" + variables.handle ))
                automountServiceAccountToken: false
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 65532
                  runAsGroup: 65532
                  seccompProfile:
                    type: RuntimeDefault
                containers:
                  - name: helm
                    image: "{{ $ctx.Values.provisioner.image }}:{{ $ctx.Values.provisioner.tag }}"
                    imagePullPolicy: {{ $ctx.Values.provisioner.pullPolicy }}
                    securityContext:
                      readOnlyRootFilesystem: true
                      allowPrivilegeEscalation: false
                      capabilities:
                        drop: [ALL]
                    resources:
                      requests: { cpu: "50m", memory: "128Mi" }
                      limits:   { cpu: "500m", memory: "256Mi" }
                    env:
                      - name: HOME
                        value: /tmp
                      # Release state lives in ConfigMaps, which the
                      # provision-write role can read; Secrets are write-only.
                      - name: HELM_DRIVER
                        value: configmap
                      - name: TENANT
                        value: (( variables.tenant ))
                      {{- with get $env $kind }}
                      - name: {{ . }}
                        value: (( variables.{{ ternary "handle" $kind (eq $kind "user") }} ))
                      {{- end }}
                      {{- if eq $kind "tenant" }}
                      - name: VALUES
                        value: (( variables.values ))
                      {{- end }}
                    volumeMounts:
                      - name: tmp
                        mountPath: /tmp
                      - name: kube-api-token
                        mountPath: /var/run/secrets/kubernetes.io/serviceaccount
                        readOnly: true
                    command: [sh, -c]
                    args:
                      - |
                        set -eu
                        {{- if eq $kind "tenant" }}
                        # The sibling reactor creates the Namespace from the same marker.
                        for i in $(seq 1 60); do
                          kubectl get namespace "$TENANT" >/dev/null 2>&1 && break
                          sleep 2
                        done
                        printf '%s\n' "$VALUES" > /tmp/values.yaml
                        helm upgrade --install "$TENANT" {{ $ctx.Values.provisioner.chartPath }} \
                          --namespace "$TENANT" \
                          --set render=base \
                          --set namespace.create=false \
                          -f /tmp/values.yaml \
                          --take-ownership \
                          --timeout 10m
                        {{- else }}
                        {{- if eq $kind "user" }}
                        # Quoted so the subject's `:` and `#` stay one scalar.
                        SUBJECT="$(kubectl get configmap {{ $component }} \
                          -n "$TENANT" -o "jsonpath={.data.user}")"
                        printf 'users:\n  - "%s"\n' "$SUBJECT" > /tmp/values.yaml
                        {{- else }}
                        kubectl get configmap {{ $component }} \
                          -n "$TENANT" -o "jsonpath={.data.values}" > /tmp/values.yaml
                        {{- end }}
                        helm upgrade --install "{{ $kind }}-${{ get $env $kind }}" {{ $ctx.Values.provisioner.chartPath }} \
                          --namespace "$TENANT" \
                          --set render={{ $kind }} \
                          --set namespace.create=false \
                          -f /tmp/values.yaml \
                          --take-ownership \
                          --timeout 10m
                        {{- end }}
                volumes:
                  - name: tmp
                    emptyDir: {}
                  - name: kube-api-token
                    projected:
                      defaultMode: 420
                      sources:
                        - serviceAccountToken:
                            path: token
                            expirationSeconds: 3600
                        - configMap:
                            name: kube-root-ca.crt
                            items:
                              - key: ca.crt
                                path: ca.crt
                        - downwardAPI:
                            items:
                              - path: namespace
                                fieldRef:
                                  fieldPath: metadata.namespace
---
apiVersion: policies.kyverno.io/v1
kind: GeneratingPolicy
metadata:
  name: {{ $component }}-grant
  labels:
    {{- include "sycophant.labels" $ctx | nindent 4 }}
spec:
  evaluation:
    generateExisting:
      enabled: false
    synchronize:
      enabled: false
  {{- include "sycophant.provisionInstallerMatch" (dict "ctx" $ctx "kind" $kind "stack" false) | nindent 2 }}
  generate:
    - template:
        interpolate: cel
        value: |
          apiVersion: rbac.authorization.k8s.io/v1
          kind: RoleBinding
          metadata:
            name: (( "{{ $component }}-" + variables.handle ))
            namespace: (( variables.tenant ))
            labels:
              {{- include "sycophant.labels" $ctx | nindent 14 }}
              app.kubernetes.io/component: {{ $component }}
            annotations:
              {{ include "sycophant.reapAfterAnnotation" $ctx }}: (( variables.reapAfter ))
          subjects:
            - kind: ServiceAccount
              name: (( "{{ $component }}-" + variables.handle ))
              namespace: sycophant-system
          roleRef:
            apiGroup: rbac.authorization.k8s.io
            kind: ClusterRole
            name: provision-write
{{- end -}}

{{/*
Reaps each per-install ServiceAccount and RoleBinding once its reap-after
instant passes, so no apply-capable credential persists between installs. The
installer Job self-cleans on its own ttlSecondsAfterFinished.
*/}}
{{- define "sycophant.provisionReap" -}}
{{- $ctx := .ctx -}}
{{- $kind := .kind -}}
apiVersion: policies.kyverno.io/v1
kind: DeletingPolicy
metadata:
  name: reap-{{ $kind }}
  labels:
    {{- include "sycophant.labels" $ctx | nindent 4 }}
spec:
  schedule: {{ $ctx.Values.reap.schedule | quote }}
  matchConstraints:
    objectSelector:
      matchLabels:
        app.kubernetes.io/component: provision-{{ $kind }}
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["serviceaccounts"]
      - apiGroups: ["rbac.authorization.k8s.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["rolebindings"]
  variables:
    - name: reapAfter
      expression: >-
        object.metadata.?annotations["{{ include "sycophant.reapAfterAnnotation" $ctx }}"].orValue("")
  conditions:
    - name: reap-after-ttl-has-passed
      expression: >-
        variables.reapAfter != "" && timestamp(variables.reapAfter) < time.now()
{{- end -}}
