# TRA-825 Preview Cutover (Expose-Only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land both candidate routes (`app.preview.gke.trakrf.id` direct + `app.preview.trakrf.id` CF-proxied) for `trakrf-backend-preview` on GKE, each origin-locked. Bump the preview image to current platform `main`. No user-facing DNS flip, no TimescaleDB Cloud teardown — those are intentional follow-ups.

**Architecture:** Cloudflare Origin CA cert (Terraform) + CF IP-range allowlist (Terraform data source) feed a Kubernetes Secret (hand-applied via `just`) and root-chart inline values (apply-root-app.sh injection). The trakrf-backend chart gains `routes[]`, per-host `Certificate`, and per-env `Middleware` templates. argocd/root sets `ingress.enabled` only for the `preview` env.

**Tech Stack:** OpenTofu (Cloudflare provider 4.x), Helm 3, ArgoCD, cert-manager, Traefik IngressRoute CRDs, reflector for cross-namespace Secret mirroring, `just` for bootstrap recipes.

**Reference spec:** `docs/superpowers/specs/2026-05-25-tra-825-preview-cutover-gke-design.md`

---

## Notes for the executor

- This is infrastructure-as-code work. "Tests" here means `tofu plan` showing only the expected delta, `helm template` rendering clean and producing the expected resources, and `bash -n` syntax checks. There is no pytest suite.
- **Never run `tofu apply`, `kubectl apply`, `just cloudflare`, `just origin-cert-secret`, or `scripts/apply-root-app.sh` as part of this plan.** Those are operator actions that happen after PR review/merge. The plan only covers code that will land in the PR.
- Working directory is the worktree at `.claude/worktrees/miks2u+tra-825-preview-cutover-gke`. The branch is `miks2u/tra-825-preview-cutover-gke`. All git commands run from the worktree root.
- Memory `feedback_helm_chart_vs_app_version`: pin chart version, not appVersion. The trakrf-backend Chart.yaml `version` field gets a bump in Task 5 (the chart's API changes).
- Memory `feedback_no_ticket_refs_in_public_docs`: this repo is public. Commit messages and PR bodies must NOT include `TRA-` references. The branch name and design/plan docs under `docs/superpowers/` are private to my workflow and are allowed to reference the ticket.
- The current commit (`HEAD`) is the design doc commit. Each subsequent task makes a small additional commit.
- After each task, run `git status` to confirm the working tree is clean before moving on.

---

## Task 1: Terraform — Cloudflare Origin CA cert + IP-ranges data source

**Files:**
- Create: `terraform/cloudflare/origin-cert.tf`
- Create: `terraform/cloudflare/cloudflare-ips.tf`
- Modify: `terraform/cloudflare/outputs.tf`

- [ ] **Step 1: Create `terraform/cloudflare/origin-cert.tf`**

```hcl
# Cloudflare Origin CA certificate for trakrf.id origin TLS.
#
# Cloudflare's "Full (strict)" SSL mode requires the origin present a cert
# valid for the requested hostname. Cloudflare Origin CA certs are signed by
# a Cloudflare CA that the Cloudflare edge trusts but the public internet
# does not — exactly the right scope for origin TLS, with none of the rate
# limits or DNS-01 dance of a public ACME issuer. 15-year validity, instant
# issuance.
#
# Wildcard covers both preview (this ticket) and the eventual production
# cutover; the resulting Secret is reflected into every trakrf-* namespace
# that needs it.

resource "tls_private_key" "origin_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin_ca" {
  private_key_pem = tls_private_key.origin_ca.private_key_pem

  subject {
    common_name  = "trakrf.id"
    organization = "TrakRF"
  }

  dns_names = [
    "trakrf.id",
    "*.trakrf.id",
  ]
}

resource "cloudflare_origin_ca_certificate" "trakrf_id" {
  csr                = tls_cert_request.origin_ca.cert_request_pem
  hostnames          = ["trakrf.id", "*.trakrf.id"]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}
```

- [ ] **Step 2: Add `tls` provider to `terraform/cloudflare/versions.tf`**

The Cloudflare provider requires us to bring our own CSR; the `tls` provider generates the key + CSR. Modify `terraform/cloudflare/versions.tf` so `required_providers` includes both providers:

```hcl
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket  = "tf-state"
    key     = "terraform.tfstate"
    region  = "auto"
    profile = "cloudflare-r2"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}
```

(Keep the `backend "s3"` block byte-for-byte identical — do not touch the endpoints-via-backend.conf wiring.)

- [ ] **Step 3: Create `terraform/cloudflare/cloudflare-ips.tf`**

```hcl
# Cloudflare's published IP ranges. Consumed by the GKE Traefik
# `cloudflare-allow` IPAllowList middleware via root-chart inline values
# (scripts/apply-root-app.sh reads the outputs below).
#
# CF rotates these occasionally. Re-run `just cloudflare` and
# `scripts/apply-root-app.sh gke` to refresh the allowlist.

data "cloudflare_ip_ranges" "this" {}
```

- [ ] **Step 4: Modify `terraform/cloudflare/outputs.tf`**

Add four new outputs to the existing file (keep `zone_id` and `nameservers`):

```hcl
output "zone_id" {
  value = cloudflare_zone.domain.id
}

output "nameservers" {
  value = cloudflare_zone.domain.name_servers
}

# Cloudflare Origin CA cert + private key for trakrf.id origin TLS.
# Consumed by `just origin-cert-secret` to materialize the
# trakrf-id-origin-tls Secret in the trakrf-system namespace.
output "origin_ca_cert_pem" {
  value     = cloudflare_origin_ca_certificate.trakrf_id.certificate
  sensitive = true
}

output "origin_ca_private_key_pem" {
  value     = tls_private_key.origin_ca.private_key_pem
  sensitive = true
}

# Cloudflare IPv4 / IPv6 CIDRs. Consumed by scripts/apply-root-app.sh
# to populate the cloudflare-allow IPAllowList sourceRange.
output "cloudflare_ipv4_cidrs" {
  value = data.cloudflare_ip_ranges.this.ipv4_cidr_blocks
}

output "cloudflare_ipv6_cidrs" {
  value = data.cloudflare_ip_ranges.this.ipv6_cidr_blocks
}
```

- [ ] **Step 5: `tofu init` to download the new tls provider**

Run:
```bash
tofu -chdir=terraform/cloudflare init -backend=false -upgrade
```
Expected: `Initializing provider plugins...` resolves `cloudflare/cloudflare` and adds `hashicorp/tls`. Exit 0. Lock file updates.

If the agent does not have network access for provider downloads, mark this step **deferred to operator** in the PR description and skip to step 6 (the lock file change will not be in the commit, and the operator runs `tofu init` before `tofu plan`).

- [ ] **Step 6: `tofu validate`**

Run:
```bash
tofu -chdir=terraform/cloudflare validate
```
Expected: `Success! The configuration is valid.` Exit 0.

If step 5 was deferred (no network), skip this step too — `validate` requires the provider plugins to be present.

- [ ] **Step 7: Commit**

```bash
git add terraform/cloudflare/origin-cert.tf terraform/cloudflare/cloudflare-ips.tf terraform/cloudflare/outputs.tf terraform/cloudflare/versions.tf
# Conditionally include the lock file if step 5 ran:
if git diff --cached --name-only | grep -q '\.terraform\.lock\.hcl' || [ -n "$(git diff terraform/cloudflare/.terraform.lock.hcl 2>/dev/null)" ]; then
  git add terraform/cloudflare/.terraform.lock.hcl
fi
git commit -m "$(cat <<'EOF'
feat(cloudflare): origin CA cert + IP-ranges data source

Adds a wildcard Cloudflare Origin CA cert for trakrf.id (private key
generated locally, CSR signed by CF) and exposes CF's published IP CIDRs
as outputs. Both feed the GKE preview origin lock — cert into a
hand-applied Secret, IP ranges into the Traefik cloudflare-allow
middleware sourceRange via apply-root-app.sh.
EOF
)"
```

---

## Task 2: `just` recipe — materialize Origin Cert Secret with reflector mirrors

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Read the current justfile to find a sensible insertion point**

```bash
grep -n "^[a-z].*:" justfile | head -20
```

Insert the new recipe near the other Cloudflare-related recipes (e.g. just after `cloudflare:`).

- [ ] **Step 2: Add the `origin-cert-secret` recipe to `justfile`**

After the `cloudflare:` recipe block, insert:

```just
# Materialize the Cloudflare Origin Cert into a Kubernetes Secret with
# reflector annotations so it mirrors into trakrf-preview and trakrf-prod.
# Run AFTER `just cloudflare` mints/rotates the cert. Idempotent.
#
# Requires kubectl context pointed at the target GKE cluster.
origin-cert-secret:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    tofu -chdir=terraform/cloudflare output -raw origin_ca_cert_pem > "$tmp/tls.crt"
    tofu -chdir=terraform/cloudflare output -raw origin_ca_private_key_pem > "$tmp/tls.key"
    kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret tls trakrf-id-origin-tls \
        --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
        --namespace trakrf-system \
        --dry-run=client -o yaml \
      | kubectl annotate --local -f - --overwrite \
          reflector.v1.k8s.emberstack.com/reflection-allowed=true \
          'reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=trakrf-preview,trakrf-prod' \
          reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
          'reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-preview,trakrf-prod' \
          -o yaml \
      | kubectl apply -f -
    echo "trakrf-id-origin-tls applied in trakrf-system; reflector will mirror to trakrf-preview/trakrf-prod."
```

Note the leading `#!/usr/bin/env bash` shebang — `just` runs each line in its own shell by default, but we need the temp dir + trap to survive across statements. Memory `feedback_just_recipe_dollar_escaping` warns about `$$` expansion; we use a real bash script with single `$` instead.

- [ ] **Step 3: Verify just recognises the recipe**

Run:
```bash
just --list 2>&1 | grep origin-cert-secret
```
Expected: line shows `origin-cert-secret` in the recipe list. Exit 0.

- [ ] **Step 4: Bash syntax check on the embedded script**

`just` does not have a `--check` mode for recipe bodies, so render and lint with `bash -n`:
```bash
just --show origin-cert-secret | sed '1d' | bash -n
```
Expected: no output, exit 0. (`sed '1d'` strips the `origin-cert-secret:` recipe header.)

- [ ] **Step 5: Commit**

```bash
git add justfile
git commit -m "$(cat <<'EOF'
feat: just origin-cert-secret recipe for CF Origin TLS bootstrap

Materializes the Cloudflare Origin CA cert (from tofu outputs) into a
trakrf-system/trakrf-id-origin-tls Secret with reflector annotations so
it mirrors into trakrf-preview and trakrf-prod. Pattern matches the
existing CNPG-credentials user-supplied-secret flow — Argo doesn't see
the private key.
EOF
)"
```

---

## Task 3: trakrf-backend chart — refactor `values.yaml` ingress block

**Files:**
- Modify: `helm/trakrf-backend/values.yaml`

- [ ] **Step 1: Replace the `ingress:` block**

Find this block (currently lines 30–38):
```yaml
# Public ingress (Traefik IngressRoute CRD). TRA-381.
# host is cluster-specific — overridden in values-<cluster>.yaml
ingress:
  enabled: true
  host: ""
  # Default chain (security-headers + redirect-https) lives in helm/traefik-config.
  middlewares:
    - name: default-chain
      namespace: traefik
```

Replace with:
```yaml
# Public ingress (Traefik IngressRoute CRDs).
#
# `routes` is a list — each entry produces one IngressRoute (TLS secretName
# is per-IngressRoute, not per-rule, so multi-host needs multiple
# IngressRoutes). Optional per-route Certificate is rendered via
# templates/certificate.yaml when `cert.issue: true`.
#
# `middlewares.{breakglass,cloudflare}` render IPAllowList Middleware
# resources in the release namespace. Routes reference them by name.
ingress:
  enabled: false
  routes: []
  # Example route shape (see argocd/root/templates/_helpers.tpl for live values):
  #   - name: gke-direct
  #     host: app.preview.gke.trakrf.id
  #     secretName: app-preview-gke-trakrf-id-tls
  #     cert:
  #       issue: true
  #       issuer: letsencrypt-prod
  #     middlewares:
  #       - name: default-chain
  #         namespace: traefik
  #       - name: breakglass-allow
  middlewares:
    breakglass:
      enabled: false
      sourceRange: []
    cloudflare:
      enabled: false
      sourceRange: []
```

- [ ] **Step 2: Verify base render still succeeds (ingress should be empty)**

```bash
helm template release-test helm/trakrf-backend -f helm/trakrf-backend/values.yaml \
  --set image.tag=sha-test 2>&1 | grep -E '^kind:' | sort -u
```
Expected: `kind: ConfigMap`, `kind: Deployment`, `kind: Job`, `kind: Secret`, `kind: Service`, `kind: ServiceMonitor` — and **no** `IngressRoute`, `Middleware`, or `Certificate`. Exit 0.

(`Job` is the migrate job; `ServiceMonitor` is the metrics scrape.)

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-backend/values.yaml
git commit -m "$(cat <<'EOF'
refactor(trakrf-backend): ingress as routes[] with per-env middlewares

Drops the single-host `ingress.host` and the implicit default-chain
middleware ref. New shape: `ingress.routes[]` (one IngressRoute per
entry, each with its own TLS Secret + middleware list) and
`ingress.middlewares.{breakglass,cloudflare}` for IPAllowList resources
rendered in the release namespace. Default values keep ingress disabled.
EOF
)"
```

---

## Task 4: trakrf-backend chart — multi-route `ingressroute.yaml`

**Files:**
- Modify: `helm/trakrf-backend/templates/ingressroute.yaml`

- [ ] **Step 1: Replace the template**

Replace the file's contents in full with:

```yaml
{{- if .Values.ingress.enabled }}
{{- range .Values.ingress.routes }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ include "trakrf-backend.fullname" $ }}-{{ .name }}
  labels:
    {{- include "trakrf-backend.labels" $ | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .host }}`)
      kind: Rule
      middlewares:
        {{- range .middlewares }}
        - name: {{ .name }}
          {{- with .namespace }}
          namespace: {{ . }}
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

- [ ] **Step 2: Verify render with two routes**

```bash
helm template release-test helm/trakrf-backend -f helm/trakrf-backend/values.yaml \
  --set image.tag=sha-test \
  --set ingress.enabled=true \
  --set 'ingress.routes[0].name=gke-direct' \
  --set 'ingress.routes[0].host=app.preview.gke.trakrf.id' \
  --set 'ingress.routes[0].secretName=app-preview-gke-trakrf-id-tls' \
  --set 'ingress.routes[0].middlewares[0].name=default-chain' \
  --set 'ingress.routes[0].middlewares[0].namespace=traefik' \
  --set 'ingress.routes[0].middlewares[1].name=breakglass-allow' \
  --set 'ingress.routes[1].name=cloudflare' \
  --set 'ingress.routes[1].host=app.preview.trakrf.id' \
  --set 'ingress.routes[1].secretName=trakrf-id-origin-tls' \
  --set 'ingress.routes[1].middlewares[0].name=default-chain' \
  --set 'ingress.routes[1].middlewares[0].namespace=traefik' \
  --set 'ingress.routes[1].middlewares[1].name=cloudflare-allow' \
  2>&1 | grep -A1 'kind: IngressRoute'
```

Expected output contains TWO `kind: IngressRoute` lines, with `name: release-test-trakrf-backend-gke-direct` and `name: release-test-trakrf-backend-cloudflare`. Exit 0.

- [ ] **Step 3: Verify render with ingress disabled produces NO IngressRoute**

```bash
helm template release-test helm/trakrf-backend -f helm/trakrf-backend/values.yaml \
  --set image.tag=sha-test 2>&1 | grep -c 'kind: IngressRoute' || true
```
Expected: `0`. Exit 0.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-backend/templates/ingressroute.yaml
git commit -m "$(cat <<'EOF'
refactor(trakrf-backend): multi-route IngressRoute template

Iterates over `ingress.routes[]` to produce one IngressRoute per host.
Each entry carries its own TLS secretName and middleware list (mixed
namespace-scoped and release-namespace middlewares supported). Renders
nothing when `ingress.enabled: false`.
EOF
)"
```

---

## Task 5: trakrf-backend chart — `middleware.yaml` template

**Files:**
- Create: `helm/trakrf-backend/templates/middleware.yaml`

- [ ] **Step 1: Create the template**

```yaml
{{- if .Values.ingress.middlewares.breakglass.enabled }}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: breakglass-allow
  labels:
    {{- include "trakrf-backend.labels" . | nindent 4 }}
spec:
  ipAllowList:
    sourceRange:
      {{- toYaml .Values.ingress.middlewares.breakglass.sourceRange | nindent 6 }}
{{- end }}
{{- if .Values.ingress.middlewares.cloudflare.enabled }}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: cloudflare-allow
  labels:
    {{- include "trakrf-backend.labels" . | nindent 4 }}
spec:
  ipAllowList:
    sourceRange:
      {{- toYaml .Values.ingress.middlewares.cloudflare.sourceRange | nindent 6 }}
{{- end }}
```

- [ ] **Step 2: Verify default render produces NO Middleware**

```bash
helm template release-test helm/trakrf-backend -f helm/trakrf-backend/values.yaml \
  --set image.tag=sha-test 2>&1 | grep -c 'kind: Middleware' || true
```
Expected: `0`.

- [ ] **Step 3: Verify render with both middlewares enabled produces TWO Middleware**

```bash
helm template release-test helm/trakrf-backend -f helm/trakrf-backend/values.yaml \
  --set image.tag=sha-test \
  --set ingress.middlewares.breakglass.enabled=true \
  --set 'ingress.middlewares.breakglass.sourceRange[0]=1.2.3.4/32' \
  --set ingress.middlewares.cloudflare.enabled=true \
  --set 'ingress.middlewares.cloudflare.sourceRange[0]=173.245.48.0/20' \
  2>&1 | grep -E 'kind: Middleware|name: (breakglass|cloudflare)-allow'
```
Expected: two `kind: Middleware` lines plus `name: breakglass-allow` and `name: cloudflare-allow`. Exit 0.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-backend/templates/middleware.yaml
git commit -m "$(cat <<'EOF'
feat(trakrf-backend): breakglass + cloudflare IPAllowList Middlewares

Renders Traefik IPAllowList Middleware resources in the release
namespace when enabled per overlay. Routes reference them by name from
the IngressRoute middleware list.
EOF
)"
```

---

## Task 6: trakrf-backend chart — `certificate.yaml` template

**Files:**
- Create: `helm/trakrf-backend/templates/certificate.yaml`

- [ ] **Step 1: Create the template**

```yaml
{{- range .Values.ingress.routes }}
{{- if and .cert .cert.issue }}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .secretName }}
  labels:
    {{- include "trakrf-backend.labels" $ | nindent 4 }}
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

- [ ] **Step 2: Verify default render produces NO Certificate**

```bash
helm template release-test helm/trakrf-backend -f helm/trakrf-backend/values.yaml \
  --set image.tag=sha-test 2>&1 | grep -c 'kind: Certificate' || true
```
Expected: `0`.

- [ ] **Step 3: Verify render with one route having cert.issue=true produces ONE Certificate**

```bash
helm template release-test helm/trakrf-backend -f helm/trakrf-backend/values.yaml \
  --set image.tag=sha-test \
  --set ingress.enabled=true \
  --set 'ingress.routes[0].name=gke-direct' \
  --set 'ingress.routes[0].host=app.preview.gke.trakrf.id' \
  --set 'ingress.routes[0].secretName=app-preview-gke-trakrf-id-tls' \
  --set 'ingress.routes[0].cert.issue=true' \
  --set 'ingress.routes[0].cert.issuer=letsencrypt-prod' \
  --set 'ingress.routes[0].middlewares[0].name=default-chain' \
  --set 'ingress.routes[0].middlewares[0].namespace=traefik' \
  --set 'ingress.routes[1].name=cloudflare' \
  --set 'ingress.routes[1].host=app.preview.trakrf.id' \
  --set 'ingress.routes[1].secretName=trakrf-id-origin-tls' \
  --set 'ingress.routes[1].cert.issue=false' \
  --set 'ingress.routes[1].middlewares[0].name=default-chain' \
  --set 'ingress.routes[1].middlewares[0].namespace=traefik' \
  2>&1 | grep -E 'kind: Certificate|secretName: '
```
Expected: exactly ONE `kind: Certificate` (the gke-direct route's), with `secretName: app-preview-gke-trakrf-id-tls`. The cloudflare route appears as IngressRoute tls.secretName but not as a Certificate (it uses the hand-applied Origin secret).

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-backend/templates/certificate.yaml
git commit -m "$(cat <<'EOF'
feat(trakrf-backend): per-route Certificate template

Renders a cert-manager Certificate per route when cert.issue is true.
Lets each route bring its own LE cert (issued in the release namespace
so Traefik's namespace-scoped TLS ref works) or BYO a hand-applied
Secret (cert.issue: false) — the Cloudflare-proxied route uses the
latter to consume the reflected Origin CA cert.
EOF
)"
```

---

## Task 7: trakrf-backend chart — bump Chart version + clean values-gke.yaml + image pin

**Files:**
- Modify: `helm/trakrf-backend/Chart.yaml`
- Modify: `helm/trakrf-backend/values-gke.yaml`

- [ ] **Step 1: Bump Chart.yaml version**

Change `version: 0.2.1` → `version: 0.3.0` (minor bump; values schema changed). Leave `appVersion` alone.

- [ ] **Step 2: Replace `helm/trakrf-backend/values-gke.yaml`**

Full file replacement:

```yaml
# GKE overrides for trakrf-backend.
#
# Pinned to the current trakrf/platform main commit sha-67f3dbc
# (was sha-c18ee87 from the per-env DB tenancy cutover). TRA-483
# will automate this pin to track the platform preview-branch
# composition; until then it's a manual bump.
#
# PR #190 in trakrf/platform switched CI to an ARM-native runner and
# dropped amd64 from main-branch builds — the image is linux/arm64-native,
# which matches GKE's t2a-standard-4 (ARM Ampere) primary node.

image:
  tag: sha-67f3dbc

# Non-production APP_ENV unlocks the test-only routes (e.g.
# /test/invitations/:id/token) that org-invite e2e specs rely on. Matches
# Railway preview. Per-env ConfigMap actually sets this; the override here
# is the GKE-wide default that the root chart preview-env inlineValues
# don't bother to repeat.
config:
  appEnv: preview

# Routes/middlewares/certs are NOT set here — they live in the per-env
# inlineValues block in argocd/root/templates/trakrf-backend.yaml, gated
# on `eq $env "preview"`.

# GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM node pools
# (T2A/T2D/Axion). AKS Ubuntu does not. Toleration scoped to GKE overlays
# only — base and AKS/EKS values stay untouched.
tolerations:
  - key: kubernetes.io/arch
    operator: Equal
    value: arm64
    effect: NoSchedule
```

(Note the inert `ingress.host: gke.trakrf.app` is gone.)

- [ ] **Step 3: Verify GKE overlay renders without setting any ingress resources**

```bash
helm template release-test helm/trakrf-backend \
  -f helm/trakrf-backend/values.yaml \
  -f helm/trakrf-backend/values-gke.yaml \
  2>&1 | grep -cE 'kind: (IngressRoute|Middleware|Certificate)' || true
```
Expected: `0`. (Ingress is disabled by base values; gke overlay doesn't enable it. Root chart will enable + populate routes via inlineValues — covered in Task 9.)

- [ ] **Step 4: Verify the image tag pin is honored**

```bash
helm template release-test helm/trakrf-backend \
  -f helm/trakrf-backend/values.yaml \
  -f helm/trakrf-backend/values-gke.yaml \
  2>&1 | grep 'image:'
```
Expected: one or more `image: ghcr.io/trakrf/backend:sha-67f3dbc` lines (Deployment + migrate Job).

- [ ] **Step 5: Commit**

```bash
git add helm/trakrf-backend/Chart.yaml helm/trakrf-backend/values-gke.yaml
git commit -m "$(cat <<'EOF'
chore(trakrf-backend): bump preview image to sha-67f3dbc; clean GKE overlay

- Chart version 0.2.1 → 0.3.0 (ingress values schema changed)
- Drops inert ingress.host on the GKE overlay (was misleading)
- Bumps preview image pin from sha-c18ee87 to current platform main
EOF
)"
```

---

## Task 8: argocd/root — `_helpers.tpl` preview ingress helper

**Files:**
- Modify: `argocd/root/templates/_helpers.tpl`

- [ ] **Step 1: Append the helper to `argocd/root/templates/_helpers.tpl`**

After the existing `trakrf.application` define block, add:

```go-template

{{/*
  trakrf-backend.previewIngressValues — YAML block injected into the
  trakrf-backend-preview Application's inline helm.values. Renders the
  two routes (direct gke.trakrf.id + CF-proxied trakrf.id) and the two
  IPAllowList middlewares, sourcing IP CIDRs from root-chart values
  populated by scripts/apply-root-app.sh.

  Caller MUST be the root Chart's render context (`.` from a template
  using `.Values`) — the helper reads .Values.breakglassSourceCidr,
  .Values.cloudflareIpv4Cidrs, .Values.cloudflareIpv6Cidrs.
*/}}
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
    - name: cloudflare
      host: app.preview.trakrf.id
      secretName: trakrf-id-origin-tls
      cert:
        issue: false
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: cloudflare-allow
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
```

- [ ] **Step 2: Quick lint — render the root chart and confirm the helper compiles**

(The helper isn't invoked yet — Task 9 wires it in. This step just confirms no parse error in `_helpers.tpl`.)

```bash
helm template trakrf-root argocd/root -f argocd/root/values.yaml \
  --set cluster=gke 2>&1 | head -5
```
Expected: no parse error; output begins with normal Application YAML. Exit 0.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/_helpers.tpl
git commit -m "$(cat <<'EOF'
feat(argocd/root): preview ingress values helper

Builds the YAML block injected into trakrf-backend-preview's inline
helm.values: two routes + two IPAllowList middlewares, sourcing CIDRs
from root-chart values populated by apply-root-app.sh.
EOF
)"
```

---

## Task 9: argocd/root — env-conditional inline values in `trakrf-backend.yaml`

**Files:**
- Modify: `argocd/root/templates/trakrf-backend.yaml`

- [ ] **Step 1: Replace the file**

Full file replacement:

```yaml
{{- /*
  One trakrf-backend Application per env (preview, prod). Each release
  installs into its own namespace and connects to its own Postgres
  database via its own credentials.

  Preview gets ingress + IPAllowList middlewares wired up via the
  trakrf-backend.previewIngressValues helper. Prod stays ingress-off
  pending production cutover (separate ticket).
*/ -}}
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
  "path" "helm/trakrf-backend"
  "namespace" (printf "trakrf-%s" $env)
  "syncWave" "1"
  "cluster" $.Values.cluster
  "repoURL" $.Values.repoURL
  "targetRevision" $.Values.targetRevision
  "destination" $.Values.destination
  "inlineValues" $values
) }}
{{- end }}
```

- [ ] **Step 2: Render preview env and confirm ingress block is present**

```bash
helm template trakrf-root argocd/root -f argocd/root/values.yaml \
  --set cluster=gke \
  --set breakglassSourceCidr=1.2.3.4/32 \
  --set 'cloudflareIpv4Cidrs={173.245.48.0/20,103.21.244.0/22}' \
  --set 'cloudflareIpv6Cidrs={2400:cb00::/32}' \
  2>&1 | awk '/name: trakrf-backend-preview/,/^---$/' \
  | grep -E 'enabled: true|app.preview.gke.trakrf.id|app.preview.trakrf.id|breakglass-allow|cloudflare-allow'
```
Expected output includes (in some order):
- `enabled: true`
- `host: app.preview.gke.trakrf.id`
- `host: app.preview.trakrf.id`
- `name: breakglass-allow` (in middleware list)
- `name: cloudflare-allow` (in middleware list)

- [ ] **Step 3: Render prod env and confirm ingress is DISABLED**

```bash
helm template trakrf-root argocd/root -f argocd/root/values.yaml \
  --set cluster=gke \
  --set breakglassSourceCidr=1.2.3.4/32 \
  --set 'cloudflareIpv4Cidrs={173.245.48.0/20}' \
  --set 'cloudflareIpv6Cidrs={2400:cb00::/32}' \
  2>&1 | awk '/name: trakrf-backend-prod/,0' \
  | grep -E 'enabled: |routes:'
```
Expected: `enabled: false` only; NO `routes:` line in the prod block.

- [ ] **Step 4: Commit**

```bash
git add argocd/root/templates/trakrf-backend.yaml
git commit -m "$(cat <<'EOF'
feat(argocd/root): wire preview ingress into trakrf-backend Application

For env=preview, inject the previewIngressValues helper into the
inline helm.values so the trakrf-backend chart renders two IngressRoutes,
two IPAllowList Middlewares, and one cert-manager Certificate in the
trakrf-preview namespace. Prod stays ingress-off.
EOF
)"
```

---

## Task 10: argocd/root — value placeholders

**Files:**
- Modify: `argocd/root/values.yaml`

- [ ] **Step 1: Append the new placeholders**

After the `mqttProdIp: ""` line at the end of the file, add:

```yaml

# TRA-825 preview ingress origin-lock — populated by scripts/apply-root-app.sh.
# breakglassSourceCidr: resolved at apply time from a dyn DNS hostname
#   (currently opsumo-austin.asuscomm.com); formatted as <ip>/32.
# cloudflareIpv{4,6}Cidrs: pulled from terraform/cloudflare outputs that wrap
#   the cloudflare_ip_ranges data source.
breakglassSourceCidr: ""
cloudflareIpv4Cidrs: []
cloudflareIpv6Cidrs: []
```

- [ ] **Step 2: Verify root chart renders with default empty values (preview block on non-GKE clusters should still parse, even if values are blank)**

```bash
helm template trakrf-root argocd/root -f argocd/root/values.yaml --set cluster=aks 2>&1 | tail -5
```
Expected: no template errors. Exit 0. (On AKS, preview ingress will render with an empty breakglass CIDR — that's OK because nothing applies the AKS root chart with preview ingress wiring, and the AKS cluster is on ice per memory `project_eks_burndown` / `project_cloud_portfolio_strategy`. The render must just not error.)

- [ ] **Step 3: Commit**

```bash
git add argocd/root/values.yaml
git commit -m "$(cat <<'EOF'
feat(argocd/root): add breakglass + cloudflare IP-range placeholders

Populated at install time by scripts/apply-root-app.sh — see next commit.
EOF
)"
```

---

## Task 11: `scripts/apply-root-app.sh` — inject break-glass IP + CF IP ranges

**Files:**
- Modify: `scripts/apply-root-app.sh`

- [ ] **Step 1: Add break-glass resolution + CF-IP capture**

Insert the following block in `scripts/apply-root-app.sh` **immediately before** the `EXTRA_ARGS=()` line (currently around line 89):

```bash
# --- TRA-825 preview ingress origin-lock values -----------------------------
# Break-glass CIDR: resolve home dyn DNS at apply time. Fail loud rather than
# deploy an empty allowlist (which would still pass schema validation but
# render the IngressRoute open to nobody).
BREAKGLASS_HOSTNAME="${BREAKGLASS_HOSTNAME:-opsumo-austin.asuscomm.com}"
BREAKGLASS_IP=$(dig +short "$BREAKGLASS_HOSTNAME" A | tail -1)
if [[ -z "$BREAKGLASS_IP" ]]; then
  echo "FATAL: could not resolve $BREAKGLASS_HOSTNAME — refusing to apply." >&2
  exit 1
fi
BREAKGLASS_CIDR="${BREAKGLASS_IP}/32"

# Cloudflare IP ranges — read from the same Cloudflare tofu workspace that
# owns the Origin Cert. JSON arrays get spliced into helm --set-json below.
CF_IPV4_JSON=$(tofu -chdir=terraform/cloudflare output -json cloudflare_ipv4_cidrs)
CF_IPV6_JSON=$(tofu -chdir=terraform/cloudflare output -json cloudflare_ipv6_cidrs)
# ----------------------------------------------------------------------------
```

- [ ] **Step 2: Add three new `--set` / `--set-json` flags to the `helm upgrade` call**

Find the existing `helm upgrade --install trakrf-root ...` block. Add three lines before the closing `"${EXTRA_ARGS[@]}"`:

```bash
  --set breakglassSourceCidr="$BREAKGLASS_CIDR" \
  --set-json cloudflareIpv4Cidrs="$CF_IPV4_JSON" \
  --set-json cloudflareIpv6Cidrs="$CF_IPV6_JSON" \
```

So the full block reads (showing only the tail for clarity):
```bash
  --set mqttPreviewIp="$MQTT_PREVIEW_IP" \
  --set mqttProdIp="$MQTT_PROD_IP" \
  --set breakglassSourceCidr="$BREAKGLASS_CIDR" \
  --set-json cloudflareIpv4Cidrs="$CF_IPV4_JSON" \
  --set-json cloudflareIpv6Cidrs="$CF_IPV6_JSON" \
  "${EXTRA_ARGS[@]}"
```

- [ ] **Step 3: Bash syntax check**

```bash
bash -n scripts/apply-root-app.sh
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/apply-root-app.sh
git commit -m "$(cat <<'EOF'
feat(apply-root-app): inject breakglass IP + CF IP ranges

Resolves the break-glass home dyn DNS at apply time (fail-loud on resolve
failure) and pulls Cloudflare IPv4/IPv6 ranges from the cloudflare tofu
workspace. Both feed the preview-env Traefik IPAllowList middlewares.
EOF
)"
```

---

## Task 12: End-to-end render verification

**Files:** none (read-only checks)

- [ ] **Step 1: Render trakrf-backend chart with realistic preview inline values**

Use a shell heredoc to feed a full preview values block:

```bash
helm template trakrf-backend-preview helm/trakrf-backend \
  -f helm/trakrf-backend/values.yaml \
  -f helm/trakrf-backend/values-gke.yaml \
  --namespace trakrf-preview \
  --set database.name=trakrf_preview \
  --set 'database.user=trakrf-app-preview' \
  --set 'database.credentialsSecret=trakrf-app-preview-credentials' \
  --set 'database.host=trakrf-db-rw.trakrf-system' \
  --set 'migrate.database=trakrf_preview' \
  --set 'migrate.user=trakrf-migrate-preview' \
  --set 'migrate.credentialsSecret=trakrf-migrate-preview-credentials' \
  --set 'migrate.host=trakrf-db-rw.trakrf-system' \
  --set ingress.enabled=true \
  --set 'ingress.routes[0].name=gke-direct' \
  --set 'ingress.routes[0].host=app.preview.gke.trakrf.id' \
  --set 'ingress.routes[0].secretName=app-preview-gke-trakrf-id-tls' \
  --set 'ingress.routes[0].cert.issue=true' \
  --set 'ingress.routes[0].cert.issuer=letsencrypt-prod' \
  --set 'ingress.routes[0].middlewares[0].name=default-chain' \
  --set 'ingress.routes[0].middlewares[0].namespace=traefik' \
  --set 'ingress.routes[0].middlewares[1].name=breakglass-allow' \
  --set 'ingress.routes[1].name=cloudflare' \
  --set 'ingress.routes[1].host=app.preview.trakrf.id' \
  --set 'ingress.routes[1].secretName=trakrf-id-origin-tls' \
  --set 'ingress.routes[1].cert.issue=false' \
  --set 'ingress.routes[1].middlewares[0].name=default-chain' \
  --set 'ingress.routes[1].middlewares[0].namespace=traefik' \
  --set 'ingress.routes[1].middlewares[1].name=cloudflare-allow' \
  --set ingress.middlewares.breakglass.enabled=true \
  --set 'ingress.middlewares.breakglass.sourceRange[0]=73.0.0.1/32' \
  --set ingress.middlewares.cloudflare.enabled=true \
  --set 'ingress.middlewares.cloudflare.sourceRange[0]=173.245.48.0/20' \
  --set 'ingress.middlewares.cloudflare.sourceRange[1]=2400:cb00::/32' \
  > /tmp/render-preview.yaml 2>&1
echo "exit=$?"
grep -cE '^kind: ' /tmp/render-preview.yaml
```

Expected: `exit=0`, then a count of resource kinds. Should include the base set plus 2× IngressRoute + 2× Middleware + 1× Certificate.

- [ ] **Step 2: Verify all expected resource kinds present**

```bash
grep -E '^kind: ' /tmp/render-preview.yaml | sort | uniq -c
```
Expected counts (in some order):
- `1 kind: Certificate`
- `1 kind: ConfigMap`
- `1 kind: Deployment`
- `2 kind: IngressRoute`
- `1 kind: Job`
- `2 kind: Middleware`
- `1 kind: Secret`
- `1 kind: Service`
- `1 kind: ServiceMonitor`

- [ ] **Step 3: Render the root chart end-to-end with all new values**

```bash
helm template trakrf-root argocd/root -f argocd/root/values.yaml \
  --set cluster=gke \
  --set certManagerIdentityClientId=fake \
  --set tenantId=fake \
  --set subscriptionId=fake \
  --set dnsZoneResourceGroup=fake \
  --set traefikLbIp=34.1.2.3 \
  --set mainResourceGroupName=fake \
  --set gcpProjectId=trakrf-fake \
  --set certManagerGcpServiceAccountEmail=fake@trakrf-fake.iam.gserviceaccount.com \
  --set cloudDnsZoneNameApp=gke-trakrf-app \
  --set cloudDnsZoneNameId=gke-trakrf-id \
  --set mqttPreviewIp=34.1.2.4 \
  --set mqttProdIp=34.1.2.5 \
  --set breakglassSourceCidr=73.0.0.1/32 \
  --set 'cloudflareIpv4Cidrs={173.245.48.0/20,103.21.244.0/22,103.22.200.0/22}' \
  --set 'cloudflareIpv6Cidrs={2400:cb00::/32,2606:4700::/32}' \
  > /tmp/render-root.yaml 2>&1
echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 4: Inspect that the preview Application contains the full preview ingress block in its inline helm.values**

```bash
awk '/name: trakrf-backend-preview/,/^---$/' /tmp/render-root.yaml \
  | grep -E 'enabled: true|app.preview.gke.trakrf.id|app.preview.trakrf.id|breakglass-allow|cloudflare-allow|73.0.0.1/32|173.245.48.0/20'
```
Expected: all six patterns matched, at least once each.

- [ ] **Step 5: Inspect that the prod Application has `ingress.enabled: false` and no routes**

```bash
awk '/name: trakrf-backend-prod/,0' /tmp/render-root.yaml \
  | grep -cE 'enabled: false|routes:'
```
Expected: exactly `1` (the `enabled: false` line; zero `routes:` lines).

If any of Steps 1–5 fail, fix and re-run the affected earlier task — do not paper over the failure with a commit.

- [ ] **Step 6: Clean up scratch files (no commit)**

```bash
rm -f /tmp/render-preview.yaml /tmp/render-root.yaml
```

---

## Task 13: Push branch and open PR

**Files:** none (git/gh operations)

- [ ] **Step 1: Confirm working tree clean and commits look right**

```bash
git status
git log --oneline main..HEAD
```
Expected: clean working tree; ~12 commits ahead of main (one per task, plus the design doc).

- [ ] **Step 2: Push the branch**

```bash
git push -u origin miks2u/tra-825-preview-cutover-gke
```

- [ ] **Step 3: Open the PR**

Memory `feedback_no_ticket_refs_in_public_docs`: no `TRA-` in the PR title or body.

```bash
gh pr create --title "feat(gke): preview ingress + origin-lock for app.preview.trakrf.id cutover" --body "$(cat <<'EOF'
## Summary

Lands the **expose** stage of the preview cutover from Railway + TimescaleDB Cloud onto GKE + CNPG. Both candidate routes reach `trakrf-backend-preview` on GKE; neither user-facing DNS nor TimescaleDB Cloud is touched in this PR — those are intentional human-gated follow-ups (see below).

- **Direct route** `app.preview.gke.trakrf.id` — origin-locked to a home break-glass IP (resolved at apply time from dyn DNS). TLS via a per-host `letsencrypt-prod` Certificate.
- **Cloudflare route** `app.preview.trakrf.id` — origin-locked to Cloudflare's published IP ranges (auto-pulled from `data.cloudflare_ip_ranges`). TLS via a new Cloudflare Origin CA cert (wildcard `*.trakrf.id`, 15-year validity) materialized into a hand-applied Secret with reflector mirrors.
- Preview image pin bumped from `sha-c18ee87` → `sha-67f3dbc` (current platform main).
- No prod ingress wiring — production cutover is a separate ticket.

## Architecture

```
                Cloud DNS gke.trakrf.id wildcard A → 34.x.y.z (Traefik LB)
                                       │
                                       ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  IngressRoute  Host: app.preview.gke.trakrf.id               │
        │    TLS:  app-preview-gke-trakrf-id-tls (cert-manager / LE)    │
        │    Mids: default-chain + breakglass-allow (IPAllowList /32)   │
        ├──────────────────────────────────────────────────────────────┤
        │  IngressRoute  Host: app.preview.trakrf.id                   │
        │    TLS:  trakrf-id-origin-tls (CF Origin CA, reflected)       │
        │    Mids: default-chain + cloudflare-allow (CF IPv4 + IPv6)    │
        └──────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                  Service trakrf-backend (ns trakrf-preview)
```

## What changed

- **terraform/cloudflare**: new `cloudflare_origin_ca_certificate` + `data "cloudflare_ip_ranges"`, four new outputs, `tls` provider added.
- **justfile**: `origin-cert-secret` recipe materialises the Origin Cert into `trakrf-system/trakrf-id-origin-tls` with reflector annotations.
- **helm/trakrf-backend**: `ingress.routes[]` schema; new `middleware.yaml` and `certificate.yaml` templates; `ingressroute.yaml` iterates routes; values-gke cleaned + image pin bumped; chart version 0.2.1 → 0.3.0.
- **argocd/root**: `_helpers.tpl` gains `trakrf-backend.previewIngressValues`; `trakrf-backend.yaml` injects it into the preview Application's inline helm.values only; root values.yaml adds three placeholders.
- **scripts/apply-root-app.sh**: resolves break-glass dyn DNS (fail-loud on lookup error) and pulls CF IP ranges from tofu outputs; passes both into helm via `--set` / `--set-json`.

## Operator playbook (post-merge, in order)

1. `just cloudflare` — mint Origin Cert; refresh CF IP-range outputs.
2. `just origin-cert-secret` — write/refresh the Secret in `trakrf-system`; reflector mirrors it to `trakrf-preview`.
3. `scripts/apply-root-app.sh gke` — re-push root with the new inline values (memory pattern: root-chart template changes need a manual apply).
4. Wait for ArgoCD to reconcile `trakrf-backend-preview`; cert-manager issues `app.preview.gke.trakrf.id` via the existing Cloud DNS solver.
5. Validate the direct route from home:
   ```bash
   curl -sv https://app.preview.gke.trakrf.id/health
   # 200 expected; body includes platform sha-67f3dbc
   ```
6. Validate the CF route end-to-end (origin-only — DNS isn't flipped yet):
   ```bash
   LB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   curl -sv --resolve app.preview.trakrf.id:443:$LB https://app.preview.trakrf.id/health
   # Will 403 from a non-CF IP (correct!) — temporarily add your /32 to
   # cloudflare-allow if you want a green hit before the real flip.
   ```
7. Confirm DB: `kubectl -n trakrf-preview exec deploy/trakrf-backend -- psql ... -tAc 'select current_database()'` → `trakrf_preview`.

## Follow-ups (separate PRs / ops)

- **DNS flip** — small TF PR: `cloudflare_record.app_preview` becomes `type=A`, `content=<traefik LB IP>`, `proxied=true`; drop `var.railway_app_preview_endpoint`.
- **TimescaleDB Cloud `trakrf-preview` teardown** — manual TS Cloud console action. The cost win.
- **Railway preview retire** — blocked on the platform preview-branch auto-track ticket.
- **Cloudflare Authenticated Origin Pulls** — lands with prod cutover; IP allowlist is the preview-grade lock.

## Test plan

- [ ] `tofu -chdir=terraform/cloudflare init -upgrade && tofu plan` — clean plan with two new resources (Origin Cert + tls private key) and a refreshed lock file. No drift elsewhere.
- [ ] `just cloudflare` (after `plan` review) — applies cert + outputs.
- [ ] `just origin-cert-secret` — Secret appears in `trakrf-system`, reflector mirrors to `trakrf-preview`.
- [ ] `scripts/apply-root-app.sh gke` — re-deploys root with break-glass IP + CF ranges.
- [ ] `kubectl -n trakrf-preview get ingressroute,middleware,certificate` — two IngressRoutes, two Middlewares, one Certificate; Cert reaches `Ready=True`.
- [ ] `curl https://app.preview.gke.trakrf.id/health` from home — 200, SHA matches `sha-67f3dbc`.
- [ ] `curl --resolve app.preview.trakrf.id:443:<lb> https://app.preview.trakrf.id/health` from a CF IP source (or temp allowlist a test IP) — 200.
- [ ] `kubectl -n trakrf-preview exec deploy/trakrf-backend -- psql ... -tAc 'select current_database()'` → `trakrf_preview`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Capture the PR URL in the task output**

```bash
gh pr view --json url --jq .url
```

Return the URL to the user.

---

## Self-review checklist (executor — quick scan after Task 13)

- [ ] No `TRA-` ticket refs in any commit message or PR body.
- [ ] Chart version bumped (Task 7) reflects the values schema change.
- [ ] Every `--set 'foo[N]...'` indexing uses single-quotes (zsh-safe).
- [ ] No commits add the Origin Cert key or break-glass IP to the repo.
- [ ] `git log --oneline main..HEAD` shows clean one-task-per-commit history.

---

## Done criteria

- PR opened with the playbook above.
- All 12 implementation commits land cleanly on the branch.
- End-to-end `helm template` of the root chart with realistic values renders the expected resources for `trakrf-backend-preview` and `enabled: false` for `trakrf-backend-prod`.
