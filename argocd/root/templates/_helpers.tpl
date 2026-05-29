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
  - `automatedPrune` (optional) overrides syncPolicy.automated.prune.
    Defaults to true. Set false for stateful resources (CNPG Clusters)
    so an accidental prune cannot delete the database.
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
      prune: {{ if hasKey . "automatedPrune" }}{{ .automatedPrune }}{{ else }}true{{ end }}
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
{{- end -}}

{{/*
  trakrf-backend.ingressValues — YAML block injected into a trakrf-backend
  Application's inline helm.values. Renders the GKE-direct route
  `app.<env>.gke.trakrf.id` (always when ingress is on) and optionally the
  CF grey-cloud route `app.<env>.trakrf.id` (gated on .appTrakrfIdRouteEnabled).
  Both Cloudflare/breakglass IPAllowList middlewares are always emitted —
  they're cheap and future-proof for the Saturday `app.trakrf.id` route.

  Caller MUST pass a dict with:
    env                       — env slug ("preview", "prod")
    appTrakrfIdRouteEnabled   — bool; true on preview today, false on prod
                                (prod's CF grey-cloud route lands Saturday)
    breakglassSourceCidr      — root values pass-through
    cloudflareIpv4Cidrs       — root values pass-through (list)
    cloudflareIpv6Cidrs       — root values pass-through (list)
*/}}
{{- define "trakrf-backend.ingressValues" -}}
ingress:
  enabled: true
  routes:
    - name: gke-direct
      host: app.{{ .env }}.gke.trakrf.id
      secretName: app-{{ .env }}-gke-trakrf-id-tls
      cert:
        issue: true
        issuer: letsencrypt-prod
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: breakglass-allow
    {{- if .appTrakrfIdRouteEnabled }}
    # `app.<env>.trakrf.id` — public customer-facing host. TRA-856 removed the
    # breakglass operator /32 from this route ahead of the orange-cloud flip;
    # the cloudflare-allow IPAllowList + ACM edge cert land in Phase 1 so the
    # origin becomes reachable only via the Cloudflare edge. Until then it is
    # intentionally open (grey-cloud, pre-launch preview) to unblock the docs
    # build's live OpenAPI fetch. Per-host LE cert via HTTP-01 at origin.
    - name: trakrf-id-direct
      host: app.{{ .env }}.trakrf.id
      secretName: app-{{ .env }}-trakrf-id-tls
      cert:
        issue: true
        issuer: letsencrypt-prod
      middlewares:
        - name: default-chain
          namespace: traefik
    {{- end }}
  middlewares:
    breakglass:
      enabled: true
      sourceRange:
        - {{ .breakglassSourceCidr | quote }}
    cloudflare:
      enabled: true
      sourceRange:
        {{- range .cloudflareIpv4Cidrs }}
        - {{ . | quote }}
        {{- end }}
        {{- range .cloudflareIpv6Cidrs }}
        - {{ . | quote }}
        {{- end }}
{{- end -}}
