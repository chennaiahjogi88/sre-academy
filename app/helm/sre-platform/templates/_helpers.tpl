{{/*
Common labels
*/}}
{{- define "sre-platform.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for a given component
*/}}
{{- define "sre-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
{{- end }}
