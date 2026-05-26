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
  - `extraAnnotations` (optional) is a pre-rendered YAML string of
    additional metadata.annotations — e.g. ArgoCD Image Updater
    annotations on the preview Application. Empty string skips.
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
    {{- if .extraAnnotations }}
{{ .extraAnnotations | indent 4 }}
    {{- end }}
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

{{/*
  trakrf-backend.previewIngressValues — YAML block injected into the
  trakrf-backend-preview Application's inline helm.values. Renders the
  two routes (direct gke.trakrf.id + CF-proxied trakrf.id) and the two
  IPAllowList middlewares, sourcing IP CIDRs from root-chart values
  populated by scripts/apply-root-app.sh.

  Caller MUST pass the root Chart render context (`$` from a template
  using `.Values`) — the helper reads .Values.breakglassSourceCidr,
  .Values.cloudflareIpv4Cidrs, .Values.cloudflareIpv6Cidrs.
*/}}
{{/*
  trakrf-backend.previewImageUpdaterAnnotations — emit ArgoCD Image
  Updater annotations for the GKE preview Application. Watches the
  floating `:preview` tag on ghcr.io/trakrf/backend (published by
  platform docker-build.yml on every preview-branch rewrite); the
  `digest` strategy redeploys whenever that tag's digest changes.

  Write-back is `argocd` (default): Image Updater patches the
  Application's spec.source.helm.parameters with the resolved digest
  (sha256:<hex>) as image.tag. The chart helper trakrf-backend.image
  recognises the sha256: prefix and renders <repo>@<digest>. The
  values-gke.yaml image.tag pin stays as the manual bootstrap value;
  the live tag lives on the Application until a manual override
  re-asserts (set image.tag back via values-gke.yaml + helm parameter
  removal). values-gke.yaml.image.tag is NOT modified.

  The image alias `backend` ties the per-image annotations together.
*/}}
{{- define "trakrf-backend.previewImageUpdaterAnnotations" -}}
argocd-image-updater.argoproj.io/image-list: backend=ghcr.io/trakrf/backend:preview
argocd-image-updater.argoproj.io/backend.update-strategy: digest
argocd-image-updater.argoproj.io/backend.helm.image-name: image.repository
argocd-image-updater.argoproj.io/backend.helm.image-tag: image.tag
argocd-image-updater.argoproj.io/write-back-method: argocd
{{- end -}}

{{- define "trakrf-backend.previewIngressValues" -}}
ingress:
  enabled: true
  routes:
    - name: gke-direct
      host: app.preview.gke.trakrf.id
      secretName: app-preview-gke-trakrf-id-tls
      cert:
        issue: true
        issuer: letsencrypt-prod
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: breakglass-allow
    # `app.preview.trakrf.id` runs grey-cloud (CF DNS-only) because CF Universal
    # SSL (Free tier) can't issue an edge cert for two-label hosts under
    # trakrf.id. Per-host LE cert via HTTP-01 at origin; same breakglass
    # IPAllowList as the gke-direct route. The Origin Cert + cloudflare-allow
    # middleware live on for future use when prod cutover lands ACM/Total TLS.
    - name: trakrf-id-direct
      host: app.preview.trakrf.id
      secretName: app-preview-trakrf-id-tls
      cert:
        issue: true
        issuer: letsencrypt-prod
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: breakglass-allow
  middlewares:
    breakglass:
      enabled: true
      sourceRange:
        - {{ .Values.breakglassSourceCidr | quote }}
    cloudflare:
      enabled: true
      sourceRange:
        {{- range .Values.cloudflareIpv4Cidrs }}
        - {{ . | quote }}
        {{- end }}
        {{- range .Values.cloudflareIpv6Cidrs }}
        - {{ . | quote }}
        {{- end }}
{{- end -}}
