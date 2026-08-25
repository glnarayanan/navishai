{{- define "navishai.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "navishai.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "navishai.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "navishai.labels" -}}
app.kubernetes.io/name: {{ include "navishai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "navishai.image" -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
