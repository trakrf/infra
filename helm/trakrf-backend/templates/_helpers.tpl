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

{{/*
  trakrf-backend.image — render the full container image reference,
  picking the right separator for tag-vs-digest.

  ArgoCD Image Updater's `digest` update-strategy writes back the resolved
  digest into `image.tag` as `sha256:<hex>`. A normal Docker reference uses
  `:` between repo and tag but `@` between repo and digest. Detect the
  `sha256:` prefix and switch separators so the same field works for both
  human-pinned `sha-<short>` tags and Image-Updater-written digests.
*/}}
{{- define "trakrf-backend.image" -}}
{{- $tag := required "image.tag must be set (usually in values-<cluster>.yaml)" .Values.image.tag -}}
{{- $sep := ternary "@" ":" (hasPrefix "sha256:" $tag) -}}
{{- printf "%s%s%s" .Values.image.repository $sep $tag -}}
{{- end -}}
