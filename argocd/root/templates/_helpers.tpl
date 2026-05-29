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
      {{- range .extraSyncOptions }}
      - {{ . }}
      {{- end }}
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
    # `app.<env>.trakrf.id` — public customer-facing host, orange-clouded
    # (TRA-856). Cloudflare owns edge TLS (ACM cert) + WAF + DDoS; the origin is
    # locked to Cloudflare by the cloudflare-allow IPAllowList (CF published
    # CIDRs), so direct-to-origin is refused. Later hardened to private-CA
    # Authenticated Origin Pulls (mTLS) with cloudflare-allow as backstop.
    # The breakglass operator /32 lives only on the grey gke-direct route now.
    #
    # CF→origin leg (SSL mode "strict") presents the Cloudflare Origin CA cert
    # `trakrf-id-origin-tls` (origin-cert.tf: 15yr, SANs *.trakrf.id +
    # *.preview.trakrf.id, reflected into trakrf-* namespaces) — NOT a Let's
    # Encrypt cert. cert.issue=false here on purpose: an LE/HTTP-01 cert would
    # need ACME validation egress that cloudflare-allow blocks (LE validates
    # from its own servers, not CF CIDRs) → renewal fails → silent strict-handshake
    # outage in <=90d. The Origin CA cert is CF-edge-trusted, 15yr, no renewal
    # dance. (The grey gke-direct route stays on its publicly-trusted LE cert
    # because direct clients hit it without the CF edge.)
    #
    # APPLY ORDER (lockstep, per runbook): ACM edge cert active + Bot Fight Mode
    # off → flip DNS proxied=true → THEN this cloudflare-allow takes effect.
    # Applying cloudflare-allow while the record is still grey would 403 all
    # traffic.
    - name: trakrf-id-direct
      host: app.{{ .env }}.trakrf.id
      secretName: trakrf-id-origin-tls
      cert:
        issue: false
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: cloudflare-allow
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
