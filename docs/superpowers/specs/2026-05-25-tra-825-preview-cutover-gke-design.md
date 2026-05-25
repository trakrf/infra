# TRA-825 — Preview cutover to GKE (off Railway + TimescaleDB Cloud): expose-only scope

## Background

TRA-823 (per-env DB tenancy on CNPG) is Done and live. `trakrf-backend-preview` and `trakrf-ingester-preview` are deployed on GKE, Synced+Healthy, connected to the `trakrf_preview` database. TRA-829 landed the `gke.trakrf.id` Cloud DNS + cert-manager DNS-01 foundation, and a `*.gke.trakrf.id` wildcard cert is issued by `letsencrypt-prod`.

The remaining work is **expose → validate → flip → decommission**. This spec covers the **expose** stage only (steps 1–3, 5 of the ticket). Validation, the user-traffic flip, the TimescaleDB Cloud teardown, and the Railway preview retire all happen as separate human-gated follow-ups after the PR merges.

## Goal

Both candidate routes resolve to `trakrf-backend-preview` on GKE, each origin-locked to an allowlist appropriate to its trust model:

- **`app.preview.gke.trakrf.id`** — direct (no Cloudflare). Origin-locked to a single break-glass home IP. TLS via a per-host `letsencrypt-prod` cert (sidesteps the GKE default-TLSStore mismatch).
- **`app.preview.trakrf.id`** — Cloudflare-proxied (eventually). Origin-locked to Cloudflare's published IP ranges. TLS via a Cloudflare Origin CA cert. DNS is **not** flipped in this PR — the existing Railway-pointing CNAME stays in place. The route is reachable from origin (verifiable via `--resolve` / Host-header rewrite) but not from `app.preview.trakrf.id` over the public internet until step 6.

Preview image bumped to current platform `main` SHA (currently pinned to `sha-c18ee87` from the TRA-823 cutover).

Prod (`trakrf-prod`) gets none of this — `ingress.enabled` stays `false`. Prod cutover is TRA-375.

## Out of scope

- Validation (step 4): manual `curl --resolve` post-merge.
- DNS flip (step 6): tiny follow-up TF change to `cloudflare_record.app_preview`.
- TimescaleDB Cloud teardown (step 7): manual TS Cloud console action; not in Terraform.
- Railway preview retire (step 8): blocked on TRA-483.
- Cloudflare Authenticated Origin Pulls (proper mTLS lock): lands with prod cutover (TRA-375). IP allowlist suffices for preview's throwaway data.
- Backend `Dockerfile` non-root posture (TRA-84). Unrelated.

## Architecture

```
                         ┌──────────────────────────────────────────┐
                         │  Cloudflare zone  trakrf.id              │
                         │  app.preview.trakrf.id  CNAME → Railway  │  ← unchanged this PR
                         └──────────────────────────────────────────┘
                                              │
                  (DNS flip in step 6 →)      │
                                              ▼
              ┌─────────────────────────────────────────────────────────────┐
              │              Cloud DNS zone  gke.trakrf.id                  │
              │   *.gke.trakrf.id  A → 34.x.y.z  (static Traefik LB)        │
              │   app.preview.gke.trakrf.id  → wildcard                     │
              └─────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
                ┌─────────────────────────────────────────────────────┐
                │             Traefik IngressRoute CRDs                │
                │  ─────────────────────────────────────────────────   │
                │  Route 1  Host: app.preview.gke.trakrf.id            │
                │           TLS:   <host>-tls (letsencrypt-prod)        │
                │           Mids:  default-chain + breakglass-allow    │
                │  ─────────────────────────────────────────────────   │
                │  Route 2  Host: app.preview.trakrf.id                │
                │           TLS:   trakrf-id-origin-tls (CF Origin CA) │
                │           Mids:  default-chain + cloudflare-allow    │
                └─────────────────────────────────────────────────────┘
                                              │
                                              ▼
                              Service trakrf-backend (ClusterIP)
                              ns: trakrf-preview
```

## Components

### A. Terraform — `terraform/cloudflare/`

**A1. `origin-cert.tf` (new)**
- `cloudflare_origin_ca_certificate.trakrf_id`:
  - `hostnames = ["*.trakrf.id", "trakrf.id"]`
  - `request_type = "origin-rsa"`
  - `requested_validity = 5475` (15 years)
- Outputs in `outputs.tf` (additions):
  - `origin_ca_cert_pem` (sensitive)
  - `origin_ca_private_key_pem` (sensitive)

The wildcard covers preview now and prod cutover later (TRA-375 reuses the same Secret). Origin CA certs are CF-CA-signed (not publicly trusted) — exactly what `ssl = strict` requires on the origin hop. They are minted instantly with no DNS-01 dance.

**A2. `cloudflare-ips.tf` (new)**
- `data "cloudflare_ip_ranges" "this"` — provider-published list.
- Outputs:
  - `cloudflare_ipv4_cidrs` (list)
  - `cloudflare_ipv6_cidrs` (list)

The user's apply pipeline (`scripts/apply-root-app.sh`) reads these and injects them into the root chart inlineValues, so the `cloudflare-allow` middleware always reflects CF's current ranges at the moment of the last `apply-root-app.sh` run. Memory `feedback_root_chart_needs_manual_bump` is in effect — operator must re-run on rotation.

### B. Origin-cert Secret bootstrap (user-supplied secret, like CNPG creds)

The Origin Cert private key is sensitive and should not be Argo-managed (no GitOps for raw key material). Use the same "user-supplied secret" pattern documented in memory `project_cnpg_secrets`.

**B1. New `just` recipe — `origin-cert-secret`**
```just
# Materialize Cloudflare Origin Cert into a Secret with reflector mirrors.
# Run AFTER `just cloudflare` mints/rotates the cert.
origin-cert-secret:
    @tofu -chdir=terraform/cloudflare output -raw origin_ca_cert_pem > /tmp/origin.crt
    @tofu -chdir=terraform/cloudflare output -raw origin_ca_private_key_pem > /tmp/origin.key
    @kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create secret tls trakrf-id-origin-tls \
        --cert=/tmp/origin.crt --key=/tmp/origin.key \
        --namespace trakrf-system \
        --dry-run=client -o yaml \
      | kubectl annotate --local -f - --overwrite \
          reflector.v1.k8s.emberstack.com/reflection-allowed=true \
          reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces='trakrf-preview,trakrf-prod' \
          reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
          reflector.v1.k8s.emberstack.com/reflection-auto-namespaces='trakrf-preview,trakrf-prod' \
          -o yaml \
      | kubectl apply -f -
    @rm -f /tmp/origin.crt /tmp/origin.key
```
- Idempotent (recreate-on-change via dry-run + apply).
- Wipes tmp files on completion.

**B2. Documentation**
- One-paragraph note in `terraform/cloudflare/README.md` (or a new `README.md` if not present) wiring the cert → secret flow.

### C. helm/trakrf-backend chart

**C1. `templates/middleware.yaml` (new)**
- Renders `traefik.io/v1alpha1/Middleware/ipAllowList` resources gated by per-env values:
  - `breakglass-allow` if `.Values.ingress.middlewares.breakglass.enabled`
  - `cloudflare-allow` if `.Values.ingress.middlewares.cloudflare.enabled`
- Both rendered into the chart's release namespace (per-env: `trakrf-preview`).
- `sourceRange` driven by values.

```yaml
{{- if .Values.ingress.middlewares.breakglass.enabled }}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: breakglass-allow
  namespace: {{ .Release.Namespace }}
spec:
  ipAllowList:
    sourceRange:
      {{- toYaml .Values.ingress.middlewares.breakglass.sourceRange | nindent 6 }}
{{- end }}
---
{{- if .Values.ingress.middlewares.cloudflare.enabled }}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: cloudflare-allow
  namespace: {{ .Release.Namespace }}
spec:
  ipAllowList:
    sourceRange:
      {{- toYaml .Values.ingress.middlewares.cloudflare.sourceRange | nindent 6 }}
{{- end }}
```

**C2. `templates/certificate.yaml` (new)**
- Renders one `cert-manager.io/v1/Certificate` per entry in `.Values.ingress.routes` that has `cert.issue: true`. Secret lands in the release namespace.
- Skip entries that bring their own pre-existing secret (e.g. the Origin Cert route).

```yaml
{{- range .Values.ingress.routes }}
{{- if .cert.issue }}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .secretName }}
  namespace: {{ $.Release.Namespace }}
spec:
  secretName: {{ .secretName }}
  issuerRef:
    name: {{ .cert.issuer }}
    kind: ClusterIssuer
  commonName: {{ .host }}
  dnsNames:
    - {{ .host }}
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
{{- end }}
{{- end }}
```

Mirrors the existing `helm/monitoring/manifests-gke/grafana-id-certificate.yaml` shape.

**C3. `templates/ingressroute.yaml` (refactor)**
- Iterate over `.Values.ingress.routes[]`. Each entry produces one IngressRoute (separate resources needed because `spec.tls.secretName` is per-IngressRoute, not per-rule).
- No legacy single-route fallback. `ingress.host` + the implicit `default-chain` middleware ref are dropped. The chart is only consumed by `argocd/root/templates/trakrf-backend.yaml`, which is updated in lockstep; no external consumers.

```yaml
{{- if .Values.ingress.enabled }}
{{- range .Values.ingress.routes }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ include "trakrf-backend.fullname" $ }}-{{ .name }}
  namespace: {{ $.Release.Namespace }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .host }}`)
      kind: Rule
      middlewares:
        {{- range .middlewares }}
        - name: {{ .name }}
          {{- if .namespace }}
          namespace: {{ .namespace }}
          {{- end }}
        {{- end }}
      services:
        - name: {{ include "trakrf-backend.fullname" $ }}
          port: {{ $.Values.service.port }}
  tls:
    secretName: {{ .secretName }}
{{- end }}
{{- end }}
```

**C4. `values.yaml` (replace `ingress:` block)**
```yaml
ingress:
  enabled: false
  routes: []
  middlewares:
    breakglass:
      enabled: false
      sourceRange: []
    cloudflare:
      enabled: false
      sourceRange: []
```
Drops `host` and the implicit `middlewares: [{name: default-chain, namespace: traefik}]` — both now live per-route in the env-conditional inline values.

**C5. `values-gke.yaml` (edits)**
- Drop `ingress.host: gke.trakrf.app` (inert; misleading).
- Bump `image.tag` to current `ghcr.io/trakrf/backend:sha-<latest-main>` (resolved during plan execution via `gh api repos/trakrf/platform/commits/main`).

### D. argocd/root

**D1. `templates/trakrf-backend.yaml`**
- Inline `$values` becomes env-conditional. For `preview`, set the full ingress + middleware + routes block; for `prod`, keep `ingress.enabled: false`.

Sketch:
```go-template
{{- range $env := list "preview" "prod" }}
{{- $base := printf "database:\n  name: trakrf_%s\n  user: trakrf-app-%s\n  credentialsSecret: trakrf-app-%s-credentials\n  host: trakrf-db-rw.trakrf-system\nmigrate:\n  database: trakrf_%s\n  user: trakrf-migrate-%s\n  credentialsSecret: trakrf-migrate-%s-credentials\n  host: trakrf-db-rw.trakrf-system\nconfig:\n  appEnv: %s\n" $env $env $env $env $env $env $env }}
{{- $ingress := "ingress:\n  enabled: false\n" }}
{{- if eq $env "preview" }}
{{- $ingress = include "trakrf-backend.previewIngressValues" $ }}
{{- end }}
{{- $values := printf "%s%s" $base $ingress }}
---
{{- include "trakrf.application" (dict
  "name" (printf "trakrf-backend-%s" $env)
  ...
  "inlineValues" $values
) }}
{{- end }}
```

The `trakrf-backend.previewIngressValues` helper (in `argocd/root/templates/_helpers.tpl`) builds the YAML block:

```yaml
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
    - name: cloudflare
      host: app.preview.trakrf.id
      secretName: trakrf-id-origin-tls   # reflected from trakrf-system
      cert:
        issue: false                     # secret hand-applied via `just origin-cert-secret`
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: cloudflare-allow
  middlewares:
    breakglass:
      enabled: true
      sourceRange: ["{{ .Values.breakglassSourceCidr }}"]
    cloudflare:
      enabled: true
      sourceRange:
        {{- range .Values.cloudflareIpv4Cidrs }}
        - {{ . | quote }}
        {{- end }}
        {{- range .Values.cloudflareIpv6Cidrs }}
        - {{ . | quote }}
        {{- end }}
```

**D2. `values.yaml` (root chart additions)**
- `breakglassSourceCidr: ""` (injected by apply-root-app.sh)
- `cloudflareIpv4Cidrs: []` (injected)
- `cloudflareIpv6Cidrs: []` (injected)

### E. scripts/apply-root-app.sh

**E1. Break-glass resolution**
```bash
breakglass_ip=$(dig +short opsumo-austin.asuscomm.com A | tail -1)
if [[ -z "$breakglass_ip" ]]; then
  echo "FATAL: could not resolve opsumo-austin.asuscomm.com — refusing to apply with empty allowlist" >&2
  exit 1
fi
breakglass_cidr="${breakglass_ip}/32"
```

**E2. Cloudflare IP-range injection**
```bash
cf_v4=$(tofu -chdir=terraform/cloudflare output -json cloudflare_ipv4_cidrs)
cf_v6=$(tofu -chdir=terraform/cloudflare output -json cloudflare_ipv6_cidrs)
```

Both threaded into the `helm.values` block of the root Argo Application alongside the existing tofu outputs.

### F. AppProject

No change. `trakrf-preview` namespace is already in `argocd/projects/trakrf.yaml destinations[]`. No new Argo Applications introduced (Origin Cert Secret is hand-applied via `just`, not Argo-managed).

## Data flow at apply time

1. Operator runs `just cloudflare` → mints/rotates Origin Cert; emits CF IP ranges.
2. Operator runs `just origin-cert-secret` → creates `trakrf-id-origin-tls` in `trakrf-system` with reflector annotations.
3. Reflector mirrors the Secret to `trakrf-preview` (and `trakrf-prod`, dormant).
4. Operator runs `scripts/apply-root-app.sh gke`:
   - Resolves break-glass IP via dig.
   - Reads CF IP ranges from tofu outputs.
   - Renders root Application with all values injected.
5. ArgoCD reconciles:
   - `trakrf-backend-preview` Application syncs.
   - Chart renders: two `Middleware` (in `trakrf-preview`), one `Certificate` (in `trakrf-preview`), two `IngressRoute` (in `trakrf-preview`).
   - cert-manager issues `app.preview.gke.trakrf.id` cert via Cloud DNS solver (existing wildcard cert is unaffected; new cert is independent).
6. Routes are reachable.

## Validation procedure (post-merge, manual)

```bash
# Get LB IP
LB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Direct route — should succeed from home IP, fail from elsewhere
curl -sv https://app.preview.gke.trakrf.id/health
# expect 200; body includes current platform main SHA

# CF route via Host header rewrite — bypasses DNS, hits origin directly
curl -sv --resolve app.preview.trakrf.id:443:$LB \
    https://app.preview.trakrf.id/health
# expect 200 from a CF IP (will fail with 403 from non-CF source — that's correct!)
# To genuinely test: temporarily allowlist your IP in cloudflare-allow, or wait for the
# real CF flip in step 6, after which the CF edge will be the source IP.

# DB sanity
kubectl -n trakrf-preview exec deploy/trakrf-backend -- \
    sh -c 'PGURL="..." psql -tAc "select current_database()"'
# expect: trakrf_preview
```

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| GKE default TLSStore points at non-existent `trakrf-wildcard-tls` Secret | Per-host Certificate sidesteps it. Not fixed in this PR. |
| Home IP rotation between `apply-root-app.sh` runs locks me out of direct route | Documented in PR. Re-run `apply-root-app.sh` to refresh. CF route (CF-IP allowlist) remains for fallback once flipped. |
| Origin Cert private key only lives in TF state | Standard CF behavior. State is in R2 (encrypted). Losing state = re-mint + re-apply secret; not a data-loss scenario. |
| CF API token lacks `Origin CA` scope | Caught on first `tofu plan`. Token needs `SSL and Certificates: Edit` at account level. Document in PR if encountered. |
| TLSStore default still broken on GKE — anyone adding an IngressRoute with bare `tls: {}` will fail | Out of scope. File a follow-up if it bites. |
| `cloudflare-allow` allowlist drifts as CF rotates ranges | Operator re-runs `just cloudflare && scripts/apply-root-app.sh gke` to refresh. Same pattern as any other root-chart value. |

## Follow-ups (separate PRs / ops)

1. **Validate routes** — manual, post-merge.
2. **Flip CF DNS** — small TF PR: change `cloudflare_record.app_preview` to `type=A`, `content=<traefik LB IP>` (or to a new `loadBalancerIP` variable), `proxied=true`. Drop the `railway_app_preview_endpoint` variable too (no longer used).
3. **Kill TimescaleDB Cloud `trakrf-preview`** — manual TS Cloud console; comment on TRA-825 with confirmation. **The cost win.**
4. **Railway preview retire** — blocked on TRA-483; not this ticket.
5. **(opportunistic) Fix the GKE default-TLSStore mismatch** — separate housekeeping.

## Verification before claiming done

- `tofu -chdir=terraform/cloudflare plan` — clean, no surprises beyond the two new resources.
- `helm template helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-gke.yaml` — renders without error; legacy fallback path still works.
- `helm template argocd/root -f argocd/root/values.yaml --set cluster=gke --set breakglassSourceCidr=1.2.3.4/32 --set 'cloudflareIpv4Cidrs={1.0.0.0/24}' --set 'cloudflareIpv6Cidrs={2400:cb00::/32}'` — renders both `trakrf-backend-preview` (with full ingress block) and `trakrf-backend-prod` (with `ingress.enabled: false`).
- Inspect rendered output — two IngressRoutes, two Middlewares, one Certificate in the preview render; none in the prod render.
