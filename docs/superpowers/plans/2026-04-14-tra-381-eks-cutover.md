# TRA-381 — `eks.trakrf.app` Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose `trakrf-backend` on `https://eks.trakrf.app` via Cloudflare → NLB → Traefik, with WAF enabled and SPA/API-tuned cache rules.

**Architecture:** Three surfaces — Terraform (DNS + WAF + cache rules in `terraform/cloudflare/`), Helm (IngressRoute added to `helm/trakrf-backend/`), then end-to-end verification from the acceptance checklist. TLS is served automatically by the default TLSStore (wildcard cert in `traefik` ns from TRA-379).

**Tech Stack:** OpenTofu + Cloudflare provider 4.x, Traefik v3 CRDs, cert-manager, ArgoCD.

**Spec:** `docs/superpowers/specs/2026-04-14-tra-381-eks-cutover-design.md`

**Branch:** `feat/tra-381-eks-cutover` (already created, spec committed)

---

## Preconditions

- [ ] Verify Traefik Service NLB is provisioned and grab hostname

```bash
kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Expected: something like `k8s-traefik-abc123-xxx.elb.us-east-2.amazonaws.com`. Record this value — it becomes `eks_nlb_hostname` in tfvars (Task 1).

- [ ] Verify wildcard cert is Ready

```bash
kubectl -n traefik get certificate trakrf-app-wildcard
```

Expected: `READY=True`.

- [ ] Verify TLSStore default references `trakrf-wildcard-tls`

```bash
kubectl -n traefik get tlsstore default -o yaml | grep secretName
```

Expected: `secretName: trakrf-wildcard-tls`.

---

## Task 1: Add `eks_nlb_hostname` variable and CNAME record

**Files:**
- Modify: `terraform/cloudflare/variables.tf`
- Modify: `terraform/cloudflare/trakrf-app.tf`
- Modify: `terraform/cloudflare/trakrf-app.auto.tfvars` (create if absent — check first)

### Steps

- [ ] **Step 1.1: Add variable declaration**

Append to `terraform/cloudflare/variables.tf`:

```hcl
variable "eks_nlb_hostname" {
  type        = string
  description = "AWS NLB hostname fronting the EKS Traefik Service (eks.trakrf.app CNAME target)"
}
```

- [ ] **Step 1.2: Set the value in tfvars**

Check for an existing tfvars file:

```bash
ls terraform/cloudflare/*.tfvars 2>/dev/null
```

If `terraform.tfvars` or `*.auto.tfvars` exists, append `eks_nlb_hostname = "<value-from-preconditions>"` there. Otherwise create `terraform/cloudflare/terraform.tfvars` with that single line plus any other required vars already in use (check `terraform/cloudflare/backend.conf` and existing plan output for required vars).

- [ ] **Step 1.3: Add CNAME resource**

Append to `terraform/cloudflare/trakrf-app.tf`:

```hcl
# eks.trakrf.app — EKS demo environment (TRA-381).
# CNAME to the Traefik NLB hostname, orange-cloud proxied for WAF + cache.
resource "cloudflare_record" "eks_trakrf_app" {
  zone_id = cloudflare_zone.trakrf_app.id
  name    = "eks"
  type    = "CNAME"
  content = var.eks_nlb_hostname
  ttl     = 1 # automatic when proxied
  proxied = true
  comment = "TRA-381 — EKS demo: Cloudflare → NLB → Traefik → trakrf-backend"
}
```

Note: in cloudflare provider 4.x, the field is `content` (not `value`). Verify by checking an existing CNAME in `trakrf-app.tf` or `alt-domains.tf`.

- [ ] **Step 1.4: Plan**

```bash
just cloudflare-plan 2>/dev/null || tofu -chdir=terraform/cloudflare plan -out=tfplan
```

Expected: one `+ cloudflare_record.eks_trakrf_app` addition, zero destroys.

- [ ] **Step 1.5: Apply**

```bash
tofu -chdir=terraform/cloudflare apply tfplan
```

- [ ] **Step 1.6: Verify DNS**

```bash
dig +short eks.trakrf.app
```

Expected: Cloudflare edge IPs (104.x.x.x / 172.x.x.x range), **not** the NLB hostname — orange-cloud is on.

- [ ] **Step 1.7: Commit**

```bash
git add terraform/cloudflare/variables.tf terraform/cloudflare/trakrf-app.tf terraform/cloudflare/*.tfvars
git commit -m "feat(tra-381): CNAME eks.trakrf.app → NLB (proxied)"
```

---

## Task 2: Enable Cloudflare Free Managed Ruleset (WAF)

**Files:**
- Modify: `terraform/cloudflare/trakrf-app.tf`

Cloudflare's Free Managed Ruleset is deployed on the zone via a `cloudflare_ruleset` resource of kind `zone`, phase `http_request_firewall_managed`, executing `action: execute` on the managed ruleset ID `efb7b8c949ac4650a09736fc376e9aee` (the stable ID for the Free Managed Ruleset).

### Steps

- [ ] **Step 2.1: Add ruleset resource**

Append to `terraform/cloudflare/trakrf-app.tf`:

```hcl
# WAF — Cloudflare Free Managed Ruleset (TRA-381).
# Block mode from day one (low FP rate, minimal traffic, greenfield demo).
resource "cloudflare_ruleset" "trakrf_app_managed_waf" {
  zone_id     = cloudflare_zone.trakrf_app.id
  name        = "Managed WAF entrypoint"
  description = "Executes Cloudflare Free Managed Ruleset on all zone traffic"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules {
    action      = "execute"
    description = "Free Managed Ruleset"
    expression  = "true"
    enabled     = true
    action_parameters {
      id = "efb7b8c949ac4650a09736fc376e9aee"
    }
  }
}
```

- [ ] **Step 2.2: Plan, apply, verify**

```bash
tofu -chdir=terraform/cloudflare plan -out=tfplan
tofu -chdir=terraform/cloudflare apply tfplan
```

Expected plan: one `+ cloudflare_ruleset.trakrf_app_managed_waf`.

Verify in dashboard: Security → WAF → Managed rules shows "Cloudflare Free Managed Ruleset" deployed. (No easy CLI check — dashboard is authoritative.)

- [ ] **Step 2.3: Smoke test WAF**

```bash
curl -sI "https://eks.trakrf.app/?id=1%20OR%201=1" | head -5
```

Expected: After the rest of the plan is applied, a 403 from CF on obvious SQLi patterns. (If WAF is in place but no backend yet, this may still return a CF error page — acceptable for now.)

- [ ] **Step 2.4: Commit**

```bash
git add terraform/cloudflare/trakrf-app.tf
git commit -m "feat(tra-381): enable CF Free Managed Ruleset on trakrf.app"
```

---

## Task 3: Cache rules for `/api/*` bypass and `/assets/*` aggressive

**Files:**
- Modify: `terraform/cloudflare/trakrf-app.tf`

Cache rules live in the `http_request_cache_settings` phase on a zone ruleset. Rule order matters — `/api/*` bypass must evaluate before the `/assets/*` cache-everything rule, though they don't overlap today.

### Steps

- [ ] **Step 3.1: Add cache ruleset**

Append to `terraform/cloudflare/trakrf-app.tf`:

```hcl
# Cache rules — SPA/API split on eks.trakrf.app (TRA-381).
resource "cloudflare_ruleset" "trakrf_app_cache_rules" {
  zone_id     = cloudflare_zone.trakrf_app.id
  name        = "eks.trakrf.app cache policy"
  description = "Bypass cache on /api/*, aggressive edge cache on /assets/*"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules {
    action      = "set_cache_settings"
    description = "Bypass cache on API"
    expression  = "(http.host eq \"eks.trakrf.app\" and starts_with(http.request.uri.path, \"/api/\"))"
    enabled     = true
    action_parameters {
      cache = false
    }
  }

  rules {
    action      = "set_cache_settings"
    description = "Aggressive edge cache on hashed SPA assets"
    expression  = "(http.host eq \"eks.trakrf.app\" and starts_with(http.request.uri.path, \"/assets/\"))"
    enabled     = true
    action_parameters {
      cache = true
      edge_ttl {
        mode    = "override_origin"
        default = 31536000 # 1 year
      }
      browser_ttl {
        mode    = "respect_origin"
      }
    }
  }
}
```

- [ ] **Step 3.2: Plan, apply**

```bash
tofu -chdir=terraform/cloudflare plan -out=tfplan
tofu -chdir=terraform/cloudflare apply tfplan
```

Expected: one `+ cloudflare_ruleset.trakrf_app_cache_rules` with two rules.

- [ ] **Step 3.3: Commit**

```bash
git add terraform/cloudflare/trakrf-app.tf
git commit -m "feat(tra-381): cache rules - /api bypass, /assets edge 1y"
```

---

## Task 4: Add IngressRoute to `trakrf-backend` chart

**Files:**
- Create: `helm/trakrf-backend/templates/ingressroute.yaml`
- Modify: `helm/trakrf-backend/values.yaml`

TLS: the IngressRoute does **not** set `tls.secretName`. The TLSStore `default` in the `traefik` namespace already serves `trakrf-wildcard-tls` as the default certificate for any TLS-enabled route. We just enable TLS with `tls: {}`.

Middleware reference crosses namespaces (IngressRoute in `trakrf`, middleware in `traefik`), so we use the Traefik cross-namespace CRD reference syntax: `name: default-chain, namespace: traefik`.

### Steps

- [ ] **Step 4.1: Add ingress values**

Modify `helm/trakrf-backend/values.yaml`. Append after the `service:` block (around line ~20):

```yaml
# Public ingress (Traefik IngressRoute CRD). TRA-381.
ingress:
  enabled: true
  host: eks.trakrf.app
  # Default chain (security-headers + redirect-https) lives in helm/traefik-config.
  middlewares:
    - name: default-chain
      namespace: traefik
```

- [ ] **Step 4.2: Create the IngressRoute template**

Create `helm/trakrf-backend/templates/ingressroute.yaml`:

```yaml
{{- if .Values.ingress.enabled -}}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ include "trakrf-backend.fullname" . }}
  labels:
    {{- include "trakrf-backend.labels" . | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .Values.ingress.host }}`)
      kind: Rule
      {{- with .Values.ingress.middlewares }}
      middlewares:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      services:
        - name: {{ include "trakrf-backend.fullname" . }}
          port: {{ .Values.service.port }}
  tls: {}
{{- end }}
```

Notes:
- `tls: {}` (empty object) tells Traefik the route is TLS-terminated; with no `secretName`, it uses the TLSStore default (`trakrf-wildcard-tls`).
- Service port references `values.service.port` (8080) which matches the existing Service template's `port:` field.

- [ ] **Step 4.3: Lint and template locally**

```bash
helm lint helm/trakrf-backend
helm template trakrf-backend helm/trakrf-backend | grep -A30 "kind: IngressRoute"
```

Expected: lint passes. Rendered IngressRoute shows `host: eks.trakrf.app`, middleware reference to `default-chain`/`traefik`, service `trakrf-backend:8080`, `tls: {}`.

- [ ] **Step 4.4: Commit**

```bash
git add helm/trakrf-backend/values.yaml helm/trakrf-backend/templates/ingressroute.yaml
git commit -m "feat(tra-381): IngressRoute for eks.trakrf.app"
```

- [ ] **Step 4.5: ArgoCD sync**

Push the branch (still scoped to the feature branch — do not merge yet if you want to validate first). For an in-cluster test before merge, you can sync the existing ArgoCD `trakrf-backend` Application against this branch, or merge-to-main and let auto-sync apply it. Repo convention is `--merge` PRs.

Preferred path per repo convention:

```bash
git push -u origin feat/tra-381-eks-cutover
gh pr create --fill --base main
```

Then after merge, wait for ArgoCD to sync (or `argocd app sync trakrf-backend`).

- [ ] **Step 4.6: Verify the IngressRoute landed**

```bash
kubectl -n trakrf get ingressroute trakrf-backend -o yaml
```

Expected: `Host(\`eks.trakrf.app\`)` match rule, middleware `default-chain@traefik`.

---

## Task 5: End-to-end acceptance verification

All checks from the TRA-381 acceptance criteria. Run each and record output in the ticket.

### Steps

- [ ] **Step 5.1: HTTPS 200 with valid cert + cf-ray**

```bash
curl -vI https://eks.trakrf.app 2>&1 | grep -E "HTTP/|cf-ray|subject|issuer"
```

Expected: `HTTP/2 200`, `cf-ray:` header present, issuer `Let's Encrypt`, subject CN covering `*.trakrf.app`.

- [ ] **Step 5.2: Real client IP in Traefik access log**

Make a request, then check logs:

```bash
MY_IP=$(curl -s ifconfig.me)
curl -s https://eks.trakrf.app/healthz >/dev/null
kubectl -n traefik logs -l app.kubernetes.io/name=traefik --tail=20 | grep "$MY_IP"
```

Expected: your real IP appears as `ClientAddr` or `X-Forwarded-For`, not a Cloudflare edge IP (103.21.x / 172.70.x range).

- [ ] **Step 5.3: DNS resolves to CF edge**

```bash
dig eks.trakrf.app +short
```

Expected: Cloudflare IP ranges (104.x / 172.x), not NLB.

- [ ] **Step 5.4: Force cert renewal, zero-downtime cert swap**

```bash
kubectl cert-manager renew -n traefik trakrf-app-wildcard
```

In another terminal, run a 5-minute watcher:

```bash
for i in $(seq 1 60); do
  curl -sI https://eks.trakrf.app | head -1
  echo "cert serial: $(echo | openssl s_client -servername eks.trakrf.app -connect eks.trakrf.app:443 2>/dev/null | openssl x509 -noout -serial)"
  sleep 5
done
```

Expected: every request returns 200, cert serial changes within 5 minutes, no error lines.

- [ ] **Step 5.5: Security headers present**

```bash
curl -sI https://eks.trakrf.app | grep -iE "strict-transport-security|x-content-type-options|x-frame-options|referrer-policy"
```

Expected: HSTS with long max-age, `x-content-type-options: nosniff`, plus any others defined in `helm/traefik-config/templates/security-headers.yaml`.

- [ ] **Step 5.6: HTTP → HTTPS redirect**

```bash
curl -sI http://eks.trakrf.app | head -2
```

Expected: `308` (or `301`) with `location: https://eks.trakrf.app/`.

- [ ] **Step 5.7: Cache rule smoke tests**

```bash
# /api/* should be MISS/BYPASS
curl -sI "https://eks.trakrf.app/api/healthz" | grep -i cf-cache-status

# /assets/<hashed> should be HIT after a warm-up request
ASSET=$(curl -s https://eks.trakrf.app/ | grep -oE '/assets/[^"]+\.js' | head -1)
curl -sI "https://eks.trakrf.app$ASSET" >/dev/null # warm
curl -sI "https://eks.trakrf.app$ASSET" | grep -iE "cf-cache-status|cache-control"
```

Expected: `/api/*` → `cf-cache-status: BYPASS` or `DYNAMIC`; `/assets/*` → `HIT` on the second request.

- [ ] **Step 5.8: Paste verification output into TRA-381 and close**

---

## Self-review (done before handoff)

- Spec coverage: CNAME ✓ (Task 1), WAF ✓ (Task 2), cache rules ✓ (Task 3), IngressRoute ✓ (Task 4), every acceptance bullet ✓ (Task 5).
- No placeholders. All code blocks complete.
- Type/name consistency: wildcard secret `trakrf-wildcard-tls` (matches `certificate.yaml`, corrects the spec's `trakrf-app-wildcard-tls` typo); cert is named `trakrf-app-wildcard` (Certificate metadata.name), secret is `trakrf-wildcard-tls`.
- Spec correction applied: IngressRoute relies on TLSStore default (no explicit `secretName`), which is more accurate than the spec's "TLS: `secretName: trakrf-app-wildcard-tls`".
