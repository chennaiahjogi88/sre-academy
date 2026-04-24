{{- define "locust.labels" -}}
app.kubernetes.io/name: locust
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
