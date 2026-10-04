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
{{- define "sycophant.inferenceProvisionMarkerName" -}}provision-inference{{- end -}}
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

{{/* Match for the reactors on the tenant marker in sycophant-system. */}}
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

Every generated object is named `provision-<kind>-<uid10>`, from the marker's
uid, so a re-created marker never collides with an earlier run's Job, even
within its TTL.

The tenant marker lives in sycophant-system and installs the base release from
chart defaults. Every other marker is `provision-<kind>-<name>` in the tenant
namespace it targets, so the tenant is the marker's own namespace, and installs
one `<kind>-<name>` release with render=<kind>. render and
namespace.create=false are forced on the command line so a marker cannot change
the slice it renders or manage the namespace. Only the tenant install takes
ownership of existing objects; a capability install refuses a name another
release holds.

Markers are one-shot: once helm succeeds the Job deletes its marker. A failed
install exits first and leaves the marker in place. The tenant install deletes
its marker through Role/provision-tenant-marker in sycophant-system.
*/ -}}
{{- define "sycophant.provisionInstallerMatch" -}}
{{- $ctx := .ctx -}}
{{- if eq .kind "tenant" -}}
{{ include "sycophant.provisionMarkerSystemMatchConstraints" $ctx }}
{{- else -}}
{{- $prefix := .prefix | default (include (printf "sycophant.%sProvisionMarkerName" .kind) $ctx) -}}
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
      operations: {{ .operations | default (list "CREATE" "UPDATE") | toJson }}
      resources: ["configmaps"]
# resourceNames cannot hold a prefix, so the apiserver drops a foreign marker
# here before Kyverno is called.
matchConditions:
  - name: marker-name-is-a-{{ .prefix | default .kind }}-marker
    expression: >-
      object.metadata.name.startsWith('{{ $prefix }}-')
{{- end }}
variables:
  - name: tenant
{{- if eq .kind "tenant" }}
    expression: '"{{ include "sycophant.tenantNsPrefix" $ctx }}" + object.data["tenant"]'
{{- else }}
    expression: 'object.metadata.namespace'
{{- end }}
  - name: uid10
    expression: 'object.metadata.uid.replace("-", "").substring(0, 10)'
  # Past the Job's activeDeadline, so the reap removes the identity only after
  # the install has finished or timed out.
  - name: reapAfter
    expression: 'string(time.now() + duration("1800s"))'
{{- end -}}

{{- /*
The ServiceAccount and Job a lifecycle reactor stamps in sycophant-system, both
named `<name>-<uid10>` and labelled component `<name>`. Params: ctx, name, script. Rendered at zero
indent inside a CEL-interpolated generate template.
*/ -}}
{{- define "sycophant.provisionerJob" -}}
{{- $ctx := .ctx -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: (( "{{ .name }}-" + variables.uid10 ))
  namespace: sycophant-system
  labels:
    {{- include "sycophant.labels" $ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
  annotations:
    {{ include "sycophant.reapAfterAnnotation" $ctx }}: (( variables.reapAfter ))
---
apiVersion: batch/v1
kind: Job
metadata:
  name: (( "{{ .name }}-" + variables.uid10 ))
  namespace: sycophant-system
  labels:
    {{- include "sycophant.labels" $ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
spec:
  backoffLimit: 4
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        {{- include "sycophant.labels" $ctx | nindent 8 }}
        app.kubernetes.io/component: {{ .name }}
    spec:
      restartPolicy: OnFailure
      serviceAccountName: (( "{{ .name }}-" + variables.uid10 ))
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
            - name: MARKER
              value: (( object.metadata.name ))
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: kube-api-token
              mountPath: /var/run/secrets/kubernetes.io/serviceaccount
              readOnly: true
          command: [sh, -c]
          args:
            - |
              {{- .script | trim | nindent 14 }}
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
{{- end -}}

{{- /* The install script for one kind; see sycophant.provisionInstaller. */ -}}
{{- define "sycophant.provisionInstallScript" -}}
{{- $ctx := .ctx -}}
{{- $kind := .kind -}}
set -eu
{{- if eq $kind "tenant" }}
# The sibling reactor creates the Namespace from the same marker.
for i in $(seq 1 60); do
  kubectl get namespace "$TENANT" >/dev/null 2>&1 && break
  sleep 2
done
helm upgrade --install "$TENANT" {{ $ctx.Values.provisioner.chartPath }} \
  --namespace "$TENANT" \
  --set render=base \
  --set namespace.create=false \
  --take-ownership \
  --timeout 10m
kubectl delete configmap "$MARKER" -n sycophant-system
{{- else }}
NAME="${MARKER#provision-{{ $kind }}-}"
{{- if eq $kind "user" }}
# Quoted so the subject's `:` and `#` stay one scalar.
SUBJECT="$(kubectl get configmap "$MARKER" \
  -n "$TENANT" -o "jsonpath={.data.user}")"
printf 'users:\n  - "%s"\n' "$SUBJECT" > /tmp/values.yaml
{{- else if eq $kind "inference" }}
# The marker's flat data rides into the chart verbatim as .Values.marker.
printf '{"marker":%s}' "$(kubectl get configmap "$MARKER" \
  -n "$TENANT" -o 'jsonpath={.data}')" > /tmp/values.yaml
{{- else }}
kubectl get configmap "$MARKER" \
  -n "$TENANT" -o "jsonpath={.data.values}" > /tmp/values.yaml
{{- end }}
helm upgrade --install "{{ $kind }}-$NAME" {{ $ctx.Values.provisioner.chartPath }} \
  --namespace "$TENANT" \
  --set render={{ $kind }} \
  --set-string name="$NAME" \
  --set namespace.create=false \
  -f /tmp/values.yaml \
  --timeout 10m
kubectl delete configmap "$MARKER" -n "$TENANT"
{{- end }}
{{- end -}}

{{- define "sycophant.provisionInstaller" -}}
{{- $ctx := .ctx -}}
{{- $kind := .kind -}}
{{- $component := printf "provision-%s" $kind -}}
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
  {{- include "sycophant.provisionInstallerMatch" (dict "ctx" $ctx "kind" $kind) | nindent 2 }}
  generate:
    - template:
        interpolate: cel
        value: |
          {{- include "sycophant.provisionerJob" (dict "ctx" $ctx "name" $component "script" (include "sycophant.provisionInstallScript" (dict "ctx" $ctx "kind" $kind))) | nindent 10 }}
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
  {{- include "sycophant.provisionInstallerMatch" (dict "ctx" $ctx "kind" $kind) | nindent 2 }}
  generate:
    - template:
        interpolate: cel
        value: |
          {{- include "sycophant.provisionerBinding" (dict "ctx" $ctx "name" $component "namespace" "(( variables.tenant ))" "kind" "ClusterRole" "role" "provision-write") | nindent 10 }}
          {{- if eq $kind "tenant" }}
          ---
          {{- include "sycophant.provisionerBinding" (dict "ctx" $ctx "name" $component "namespace" "sycophant-system" "kind" "Role" "role" "provision-tenant-marker") | nindent 10 }}
          {{- end }}
{{- end -}}

{{- /* A RoleBinding named `<name>-<uid10>`, labelled component `<name>`, for the reactor's ServiceAccount. */ -}}
{{- define "sycophant.provisionerBinding" -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: (( "{{ .name }}-" + variables.uid10 ))
  namespace: {{ .namespace }}
  labels:
    {{- include "sycophant.labels" .ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
  annotations:
    {{ include "sycophant.reapAfterAnnotation" .ctx }}: (( variables.reapAfter ))
subjects:
  - kind: ServiceAccount
    name: (( "{{ .name }}-" + variables.uid10 ))
    namespace: sycophant-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: {{ .kind }}
  name: {{ .role }}
{{- end -}}

{{- /* The uninstall script for one kind; see sycophant.provisionUninstaller. */ -}}
{{- define "sycophant.provisionUninstallScript" -}}
set -eu
NAME="${MARKER#reap-{{ .kind }}-}"
helm uninstall "{{ .kind }}-$NAME" -n "$TENANT" --timeout 10m
kubectl delete configmap "$MARKER" -n "$TENANT"
{{- end -}}

{{- /*
One single-shot uninstall per reap marker `reap-<kind>-<name>` in a tenant
namespace. The ServiceAccount and Job `uninstall-<kind>-<uid10>` live in
sycophant-system; the RoleBinding of the same name binds them to
ClusterRole/provision-write in the marker's namespace, which exists already.
The Job runs `helm uninstall <kind>-<name>` and then deletes the reap marker; a
failed uninstall exits first and leaves the marker in place. The ServiceAccount
and RoleBinding carry component `uninstall-<kind>` and the reap-after
annotation, so `reap-<kind>` sweeps them.
*/ -}}
{{- define "sycophant.provisionUninstaller" -}}
{{- $ctx := .ctx -}}
{{- $kind := .kind -}}
{{- $name := printf "uninstall-%s" $kind -}}
{{- $script := include "sycophant.provisionUninstallScript" (dict "kind" $kind) -}}
apiVersion: policies.kyverno.io/v1
kind: GeneratingPolicy
metadata:
  name: {{ $name }}
  labels:
    {{- include "sycophant.labels" $ctx | nindent 4 }}
spec:
  evaluation:
    generateExisting:
      enabled: false
    synchronize:
      enabled: false
  {{- include "sycophant.provisionInstallerMatch" (dict "ctx" $ctx "kind" $kind "prefix" (printf "reap-%s" $kind) "operations" (list "CREATE")) | nindent 2 }}
  generate:
    - template:
        interpolate: cel
        value: |
          {{- include "sycophant.provisionerJob" (dict "ctx" $ctx "name" $name "script" $script) | nindent 10 }}
          ---
          {{- include "sycophant.provisionerBinding" (dict "ctx" $ctx "name" $name "namespace" "(( variables.tenant ))" "kind" "ClusterRole" "role" "provision-write") | nindent 10 }}
{{- end -}}

{{/*
Reaps each install and uninstall ServiceAccount and RoleBinding once its
reap-after instant passes, so no apply-capable credential persists between runs.
Each Job self-cleans on its own ttlSecondsAfterFinished.
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
      matchExpressions:
        - key: app.kubernetes.io/component
          operator: In
          values: [provision-{{ $kind }}, uninstall-{{ $kind }}]
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
