{{/*
  trakrf.application — shared Application shape for in-repo helm charts.

  Usage:
    {{- include "trakrf.application" (dict
      "name" "cert-manager-config"
      "path" "helm/cert-manager-config"
      "namespace" .Values.namespaces.certManager
      "syncWave" "0"
      "cluster" .Values.cluster
      "repoURL" .Values.repoURL
      "targetRevision" .Values.targetRevision
      "destination" .Values.destination
      "inlineValues" ""
    ) }}

  - `path` points at a chart inside this repo; the Application resolves
    valueFiles as `values.yaml` + `values-<cluster>.yaml`.
  - `inlineValues` is a YAML string (pre-rendered) injected via
    source.helm.values — use for tofu-sourced values that must be
    substituted per-install. Empty string skips the stanza.
  - Upstream charts (Application pointing at e.g. charts.jetstack.io)
    do NOT use this helper — they emit their full source block inline
    since they can't reference valueFiles inside a different repo.
*/}}
{{- define "trakrf.application" -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ .syncWave | quote }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: trakrf
  source:
    repoURL: {{ .repoURL }}
    targetRevision: {{ .targetRevision }}
    path: {{ .path }}
    helm:
      valueFiles:
        - values.yaml
        - values-{{ .cluster }}.yaml
      {{- if .inlineValues }}
      values: |
{{ .inlineValues | indent 8 }}
      {{- end }}
  destination:
    server: {{ .destination.server }}
    namespace: {{ .namespace }}
  {{- if .ignoreDifferences }}
  ignoreDifferences:
{{ .ignoreDifferences | indent 4 }}
  {{- end }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
{{- end -}}
