{{- define "sycophant.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: sycophant
{{- end -}}

{{- /*
The subject's 10-character sha256 handle, the suffix of every object this
chart names. Empty when the command carries no `user`, so callers render
nothing.
*/ -}}
{{- define "sycophant-user.hash" -}}
{{- with .Values.command }}{{ with .user }}{{ sha256sum . | trunc 10 }}{{ end }}{{ end -}}
{{- end -}}
