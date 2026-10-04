{{- define "sycophant.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: sycophant
{{- end -}}

{{- define "sycophant.workspaceLabels" -}}
{{ include "sycophant.labels" .context }}
app.kubernetes.io/component: harness
app.kubernetes.io/name: {{ .name }}
{{- end -}}

{{- /*
One workspace's bindings entry: the toolsets it may call and, per grant, the
Secret name, mount path, and egress domain. Takes `.name` and `.workspace`.

A list item is either a bare toolset name or an object naming the toolset and
its grants. Both bind the same toolset by name; only the second exposes
credentials.

Rendered at zero indent; the caller nindents it under a `bindings.yaml` key.
With `.namesOnly` set it renders the names-only `relay-toolset-grants` the relay
serves on ListGrants -- the grant leaf collapses to `<grant>: {}`, no secret,
path, or egress.
*/}}
{{- define "sycophant.workspaceBindings" -}}
{{- $name := .name -}}
{{- $ws := .workspace -}}
{{- $namesOnly := .namesOnly -}}
{{ $name }}:
{{- if hasKey $ws "toolsets" }}
{{- range $toolset := $ws.toolsets }}
{{- if kindIs "string" $toolset }}
  - {{ $toolset }}
{{- else }}
  - name: {{ $toolset.name }}
    grants:
    {{- range $grant, $spec := $toolset.grants }}
    {{- if $namesOnly }}
      {{ $grant }}: {}
    {{- else }}
      {{ $grant }}:
        secret: {{ $spec.secret }}
        {{- if $spec.path }}
        path: {{ $spec.path }}
        {{- end }}
        {{- if $spec.egress }}
        egress: {{ $spec.egress }}
        {{- end }}
    {{- end }}
    {{- end }}
{{- end }}
{{- end }}
{{- else }}
  - stdlib
{{- end }}
{{- end -}}

{{- /*
One workspace's capability manifest: every tool the workspace's bound toolsets
expose, each fully resolved with its argument schema and this workspace's grants.
Takes `.name`, `.workspace`, and the root `.context`.

The manifest is derived from the toolset IMAGES, not from Helm values: the
deploy driver runs `syco toolset manifest <image>` per bound image (merging this
workspace's grants) and hands the assembled document to the chart as the string
`workspaces.<ws>.capabilityManifest` (via `--set-file`). This helper emits that
string verbatim so both the ConfigMap and the harness pod-roll checksum see the
same bytes. A workspace with no supplied manifest renders an empty `{tools: []}`
document; the chart never sources tool schema from `toolsets.<name>.tools`.
*/}}
{{- define "sycophant.capabilityManifest" -}}
{{- $ws := .workspace -}}
{{- with (default "" $ws.capabilityManifest) -}}
{{- . -}}
{{- else -}}
{{- (dict "tools" (list)) | toYaml -}}
{{- end -}}
{{- end -}}

{{- /*
The per-workspace capability-manifest ConfigMap name, content-addressed: the
manifest hash is part of the name, so a changed manifest yields a NEW immutable
ConfigMap. The harness volume points at this same name, so a change swaps the
mounted object and rolls the pod, and helm prunes the superseded ConfigMap.
Deriving the name here keeps the ConfigMap and the volume from drifting. Takes
`.name`, `.workspace`, `.context`.
*/}}
{{- define "sycophant.capabilityManifestConfigMapName" -}}
capability-manifest-{{ .name }}-{{ include "sycophant.capabilityManifest" (dict "name" .name "workspace" .workspace "context" .context) | sha256sum | trunc 10 }}
{{- end -}}

{{- /*
The one port every local model serves on. A local marker carries no baseUrl:
the server, its Service, and its ingress fence all bind this port, and the
harness dials `inference-<key>` on the same number.
*/}}
{{- define "sycophant.inferenceLocalPort" -}}
8080
{{- end -}}

{{- /*
Projected kube-apiserver SA token + CA + namespace at the canonical
kubelet mount path. Controllers use this in place of the auto-mounted
default token so the pod can carry `automountServiceAccountToken: false`
and still talk to the kube-apiserver via `kube::Client::try_default()`.
audience: omitted -- kubelet binds to apiserver default audience.
*/}}
{{- define "sycophant.projectedKubeApiToken.volume" -}}
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

{{- define "sycophant.projectedKubeApiToken.mount" -}}
- name: kube-api-token
  mountPath: /var/run/secrets/kubernetes.io/serviceaccount
  readOnly: true
{{- end -}}

{{- /*
The kube-dns egress every per-pod CNP opens: an L4 toEndpoints allowing UDP and
TCP :53 to the kube-system kube-dns pods. Identical across all CNPs; the L7
`rules.dns` allowlist a policy layers on top of it stays local. Caller nindents
to the egress-entry depth (4).
*/ -}}
{{- define "sycophant.dnsEgress" -}}
- toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
  toPorts:
    - ports:
        - port: "53"
          protocol: UDP
        - port: "53"
          protocol: TCP
{{- end -}}


{{/* Number of `kind: app` entries under `.Values.channels`. */}}
{{- define "sycophant.appChannelCount" -}}
{{- $n := 0 -}}
{{- range .Values.channels }}{{- if eq .kind "app" }}{{- $n = add $n 1 }}{{- end }}{{- end -}}
{{- $n -}}
{{- end -}}
