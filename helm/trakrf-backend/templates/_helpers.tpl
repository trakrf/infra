{{/*
Expand the name of the chart.
*/}}
{{- define "trakrf-backend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "trakrf-backend.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "trakrf-backend.labels" -}}
app.kubernetes.io/name: {{ include "trakrf-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: trakrf
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "trakrf-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "trakrf-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
