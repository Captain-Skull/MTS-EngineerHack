{{- define "rollout.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/part-of: mts-hack
mts-hack/app: {{ .Release.Name }}
{{- end }}
