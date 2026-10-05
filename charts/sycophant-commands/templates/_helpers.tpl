{{- define "commands.tenantNs" -}}tenant-{{ . }}{{- end -}}

{{- /*
A command ConfigMap. Params: name, namespace, data (a flat map; every value is
written as a quoted string, since command data is flat strings). YAML numbers
arrive as floats, so a whole one is printed as an integer, never as 1e+06.
*/ -}}
{{- define "commands.command" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
  labels:
    sycophant.md/command: "true"
    app.kubernetes.io/part-of: sycophant
{{- with .data }}
data:
  {{- range $k, $v := . }}
  {{- if and (kindIs "float64" $v) (eq $v (float64 (int64 $v))) }}{{ $v = int64 $v }}{{ end }}
  {{ $k | quote }}: {{ $v | toString | quote }}
  {{- end }}
{{- end }}
{{- end -}}

{{- /* A reap command for kind .kind from its values block .v. */ -}}
{{- define "commands.reap" -}}
{{ include "commands.command" (dict "name" (printf "reap-%s-%s" .kind .v.name) "namespace" (include "commands.tenantNs" .v.tenant)) }}
{{- end -}}
