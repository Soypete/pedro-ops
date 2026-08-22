{{- define "pedro-observability.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: pedro-observability
release: {{ .Values.prometheusRelease }}
{{- end }}
