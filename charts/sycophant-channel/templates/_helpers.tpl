{{- define "sycophant.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: sycophant
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

{{- /*
The headscale settings as YAML, from the command's flat `headscale.*` keys with
their defaults filled in. Command data is strings, so the booleans are read as
"true" or "false". The headscale pod checksums this output to roll on a change.
*/ -}}
{{- define "sycophant.headscale" -}}
{{- $m := .Values.command -}}
{{- toYaml (dict
  "enabled" (eq (index $m "headscale.enabled" | default "false") "true")
  "image" (index $m "headscale.image" | default "headscale/headscale")
  "tag" (index $m "headscale.tag" | default "0.28.0")
  "pullPolicy" (index $m "headscale.pullPolicy" | default "IfNotPresent")
  "serverUrl" (index $m "headscale.serverUrl" | default "")
  "magicDns" (ne (index $m "headscale.magicDns" | default "true") "false")
  "baseDomain" (index $m "headscale.baseDomain" | default "ts.local")
  "acme" (dict
    "enabled" (eq (index $m "headscale.acme.enabled" | default "false") "true")
    "email" (index $m "headscale.acme.email" | default ""))) -}}
{{- end -}}
