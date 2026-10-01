{{- define "hello.fullname" -}}hello-{{ .Values.version }}{{- end }}

{{- define "hello.selectorLabels" -}}
app.kubernetes.io/name: hello
app.kubernetes.io/instance: {{ include "hello.fullname" . }}
app.kubernetes.io/version: {{ .Values.version | quote }}
{{- end }}

{{- define "hello.labels" -}}
{{ include "hello.selectorLabels" . }}
app.kubernetes.io/part-of: mts-hack
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "hello.image" -}}
{{ .repository }}:{{ .tag }}{{ with .digest }}@{{ . }}{{ end }}
{{- end }}
