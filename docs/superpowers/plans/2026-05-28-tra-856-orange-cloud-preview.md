# TRA-856 Orange-cloud preview + remove IP allowlist — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve `app.preview.trakrf.id` through the Cloudflare edge (edge TLS + WAF + DDoS), lock the GKE origin to Cloudflare, and remove the operator-`/32` IP allowlist — unblocking the docs preview build.

**Architecture:** Cloudflare-front (orange cloud) → GKE Traefik origin. CF terminates TLS with an ACM advanced cert (`*.preview.trakrf.id`), runs WAF/DDoS, and proxies to the origin over the existing Cloudflare Origin Cert. The public Traefik route swaps its IP allowlist from `breakglass-allow` (operator `/32`) to `cloudflare-allow` (CF CIDRs), with private-CA Authenticated Origin Pulls (mTLS) as the drift-proof primary lock (staged). The grey `app.preview.gke.trakrf.id` direct/test route keeps `breakglass-allow`.

**Tech Stack:** OpenTofu + Cloudflare provider v4 (`~> 4.0`), Helm (trakrf-backend chart), ArgoCD root chart (`scripts/apply-root-app.sh`), Traefik IngressRoute/Middleware/TLSOption CRDs.

**Apply mechanics:** Cloudflare resources via `just cloudflare` (tofu). Helm/middleware via ArgoCD root — `scripts/apply-root-app.sh gke` after merge (root-chart edits do NOT auto-sync). Never push to main; PR + `gh pr merge --merge`.

---

## Phase 0 — Fast unblock (separate small PR)

Goal: docs preview build green in minutes by removing the operator `/32` gate from the public preview route (interim: fully-open grey — acceptable on pre-launch preview, no prod data). This is exactly the "open `app.preview` to the world" + "free up docs" directive.

### Task 0.1: Remove breakglass-allow from the preview public route

**Files:**
- Modify: `argocd/root/templates/_helpers.tpl` (the `trakrf-id-direct` route in `trakrf-backend.ingressValues`, ~lines 111-120)

- [ ] **Step 1: Edit the route's middleware list**

In the `trakrf-id-direct` route block, remove the `breakglass-allow` entry so only the shared chain remains:

```yaml
    - name: trakrf-id-direct
      host: app.{{ .env }}.trakrf.id
      secretName: app-{{ .env }}-trakrf-id-tls
      cert:
        issue: true
        issuer: letsencrypt-prod
      middlewares:
        - name: default-chain
          namespace: traefik
        # breakglass-allow removed (TRA-856): public route opened ahead of
        # the orange-cloud flip; cloudflare-allow + AOP added in Phase 1.
```

Leave the `gke-direct` route's `breakglass-allow` untouched.

- [ ] **Step 2: Render to verify the middleware is gone from the public route**

Run:
```bash
helm template argocd/root --show-only templates/trakrf-backend.yaml 2>/dev/null | grep -n "breakglass-allow\|cloudflare-allow\|app.preview.trakrf.id" || true
```
Expected: `app.preview.trakrf.id` route present; `breakglass-allow` no longer associated with it (still present on the gke-direct route).
(If `helm template` on the root chart is impractical due to inline-values plumbing, instead verify by inspecting the rendered `_helpers.tpl` logic and proceed — the live check is Step 5.)

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/_helpers.tpl
git commit -m "fix(tra-856): drop operator /32 from app.preview public route (unblock docs)"
```

- [ ] **Step 4: PR + merge**

```bash
git push -u origin miks2u/tra-856-orange-cloud-preview-environment-and-remove-ip-allowlist
gh pr create --title "fix(TRA-856): open app.preview.trakrf.id — drop operator /32 (unblock docs build)" --body "<phase-0 body>"
gh pr merge --merge
```

- [ ] **Step 5: Apply via ArgoCD root and verify the allowlist is gone**

```bash
scripts/apply-root-app.sh gke
# wait for the trakrf-backend-preview app to sync
kubectl --context=gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1 -n trakrf-preview \
  get ingressroute trakrf-backend-trakrf-id-direct -o json \
  | python3 -c 'import sys,json; [print(r["match"], [m["name"] for m in r.get("middlewares",[])]) for r in json.load(sys.stdin)["spec"]["routes"]]'
```
Expected: route `Host(\`app.preview.trakrf.id\`)` middlewares = `['default-chain']` (no `breakglass-allow`).

- [ ] **Step 6: Verify docs build unblocks**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://app.preview.trakrf.id/api/openapi.yaml   # expect 200 from any network
```
Then ping the `docs` agent to re-trigger the preview build and confirm `f2216b1 → c973871` green. (Or trigger via CF Pages API as done during diagnosis.)

---

## Phase 1 — Orange cloud (main PR)

### Task 1.1: ACM advanced certificate for *.preview.trakrf.id

**Files:**
- Create: `terraform/cloudflare/acm-preview.tf`

- [ ] **Step 1: Confirm ACM subscription is enabled on the zone**

ACM (~$10/mo) must be active before an advanced cert pack will create. Check:
```bash
just s3-ls >/dev/null 2>&1  # ensure env loaded
ZID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=trakrf.id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZID/subscription" | python3 -m json.tool
```
Expected: an Advanced Certificate Manager subscription present. **If absent, this is a billing enablement that may not be doable via tofu — surface to Mike and enable in dashboard before proceeding.** (Record the finding either way.)

- [ ] **Step 2: Write the advanced cert pack resource**

```hcl
# terraform/cloudflare/acm-preview.tf
# TRA-856: Advanced cert for the two-label preview host. Free Universal SSL
# covers trakrf.id + *.trakrf.id only; app.preview.trakrf.id needs ACM.
# Revives the intent of canceled TRA-388 in the GKE/trakrf.id world.
resource "cloudflare_certificate_pack" "preview_advanced" {
  zone_id               = var.zone_id
  type                  = "advanced"
  hosts                 = ["preview.trakrf.id", "*.preview.trakrf.id"]
  validation_method     = "txt"
  validity_days         = 90
  certificate_authority = "google"
  cloudflare_branding   = false

  lifecycle {
    create_before_destroy = true
  }
}
```
(Confirm `var.zone_id` is the trakrf.id zone variable used by the records in `main.tf`; if records use a different reference, match it.)

- [ ] **Step 3: tofu plan**

```bash
tofu -chdir=terraform/cloudflare init -reconfigure -backend-config=backend.conf >/dev/null
tofu -chdir=terraform/cloudflare plan -target=cloudflare_certificate_pack.preview_advanced
```
Expected: 1 resource to add. Note any validation-record requirement in the plan output.

- [ ] **Step 4: Apply the cert pack and wait for active**

```bash
just cloudflare   # or: tofu -chdir=terraform/cloudflare apply -target=cloudflare_certificate_pack.preview_advanced
```
Poll status until `active` (TXT validation is automatic for a CF-hosted zone):
```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZID/ssl/certificate_packs?status=all" | python3 -c 'import sys,json;[print(p["status"],p.get("hosts")) for p in json.load(sys.stdin)["result"]]'
```
Expected: a pack covering `*.preview.trakrf.id` reaches `active`.

- [ ] **Step 5: Commit**

```bash
git add terraform/cloudflare/acm-preview.tf
git commit -m "feat(tra-856): ACM advanced cert for *.preview.trakrf.id"
```

### Task 1.2: Flip app.preview.trakrf.id to orange + swap origin lock to cloudflare-allow (lockstep)

**Files:**
- Modify: `terraform/cloudflare/main.tf` (`cloudflare_record.app_preview`, ~lines 56-63)
- Modify: `argocd/root/templates/_helpers.tpl` (`trakrf-id-direct` route — add `cloudflare-allow`)

> Lockstep ordering (CORRECTED): flip DNS to orange **first**, THEN apply `cloudflare-allow`. Applying `cloudflare-allow` while the record is still grey would lock the origin to CF CIDRs while real traffic still arrives direct (non-CF) → 403 for everyone, including the operator. Flipping orange first leaves a brief safe window (proxied, origin still open) before the lock lands — no outage. Prereq for the flip: ACM cert active AND Bot Fight Mode off / security_level ≤ medium (so the orange host never challenges header-less API clients).

- [ ] **Step 1: Add cloudflare-allow to the public route**

In `_helpers.tpl` `trakrf-id-direct` route, set middlewares to the shared chain + `cloudflare-allow` (the `cloudflare` Middleware is already emitted by the helper with `cloudflareIpv{4,6}Cidrs`):

```yaml
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: cloudflare-allow   # TRA-856: origin reachable only via CF edge
```

- [ ] **Step 2: Flip the DNS record to proxied**

In `main.tf`, edit `cloudflare_record.app_preview`:

```hcl
resource "cloudflare_record" "app_preview" {
  zone_id = var.zone_id
  name    = "app.preview"
  type    = "A"
  content = "34.56.243.51"
  proxied = true # TRA-856: orange-cloud — CF edge TLS (ACM) + WAF/DDoS; origin locked to CF
  comment = "GKE preview origin via Cloudflare edge (orange; ACM cert; AOP/cloudflare-allow origin lock)"
}
```
Update the now-stale grey-cloud comment block above it (lines ~43-55).

- [ ] **Step 3: Validate + plan**

```bash
tofu -chdir=terraform/cloudflare plan -target=cloudflare_record.app_preview
```
Expected: in-place update, `proxied: false -> true`.

- [ ] **Step 4: Commit**

```bash
git add terraform/cloudflare/main.tf argocd/root/templates/_helpers.tpl
git commit -m "feat(tra-856): orange-cloud app.preview.trakrf.id + cloudflare-allow origin lock"
```

- [ ] **Step 5: Flip DNS to orange FIRST, then apply cloudflare-allow**

Prereqs already met: ACM cert active (Task 1.1) AND Bot Fight Mode off / security_level ≤ medium (Task 1.3). Then:

```bash
just cloudflare                 # flip DNS proxied=true (origin still open — brief safe window)
# verify edge is serving before locking the origin:
curl -s -D - -o /dev/null https://app.preview.trakrf.id/api/openapi.yaml | grep -iE "^HTTP|cf-ray"   # expect 200 + cf-ray
scripts/apply-root-app.sh gke   # NOW add cloudflare-allow — origin becomes CF-only
# confirm route middlewares include cloudflare-allow:
kubectl --context=gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1 -n trakrf-preview get ingressroute trakrf-backend-trakrf-id-direct -o json | python3 -c 'import sys,json;[print([m["name"] for m in r.get("middlewares",[])]) for r in json.load(sys.stdin)["spec"]["routes"]]'
```
(Order matters: applying `cloudflare-allow` while the record is still grey would 403 all direct traffic. Flipping orange first leaves only a brief proxied-but-origin-open window — safe.)

- [ ] **Step 6: Verify edge path**

```bash
curl -s -D - -o /dev/null https://app.preview.trakrf.id/api/openapi.yaml | grep -iE "^HTTP|cf-ray|server"   # expect 200 + cf-ray header (traversed edge)
```

### Task 1.3: Confirm managed WAF active + conditional challenge-skip

**Files:**
- Modify/Create: `terraform/cloudflare/trakrf-id-waf.tf` (mirror `trakrf-app.tf:66` managed-WAF pattern for the trakrf.id zone if not already present)

- [ ] **Step 1: Check whether a managed WAF ruleset already exists on the trakrf.id zone**

```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZID/rulesets" | python3 -c 'import sys,json;[print(r["phase"],r["name"]) for r in json.load(sys.stdin)["result"]]'
```

- [ ] **Step 2: If absent, add the Free Managed Ruleset (mirror trakrf-app.tf:66)**

```hcl
# terraform/cloudflare/trakrf-id-waf.tf
resource "cloudflare_ruleset" "trakrf_id_managed_waf" {
  zone_id     = var.zone_id
  name        = "Managed WAF entrypoint"
  description = "Executes Cloudflare Free Managed Ruleset on trakrf.id traffic"
  kind        = "zone"
  phase       = "http_request_firewall_managed"
  rules {
    action      = "execute"
    description = "Free Managed Ruleset"
    expression  = "true"
    enabled     = true
    action_parameters { id = "77454fe2d30c4220b5701f6fdfb893ba" }
  }
}
```
`tofu -chdir=terraform/cloudflare plan` → expect 1 add; `just cloudflare` to apply.

- [ ] **Step 3: Probe for an interactive challenge on the spec path (header-less)**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -A "" https://app.preview.trakrf.id/api/openapi.yaml
curl -s -o /dev/null -w "%{http_code}\n" -A "" https://app.preview.trakrf.id/openapi.yaml
```
Expected: 200 (or 301→200 for the root alias). If either returns 403/503 with a CF challenge body, proceed to Step 4; otherwise the managed ruleset isn't challenging header-less GETs and **no skip rule is needed — record that and skip Step 4.**

- [ ] **Step 4 (only if challenged): Add an action-scoped challenge-skip**

```hcl
# Appended to trakrf-id-waf.tf — action-scoped: skips interactive challenge on
# the public-spec/API paths only. Does NOT disable the managed OWASP ruleset.
resource "cloudflare_ruleset" "trakrf_id_skip_challenge" {
  zone_id     = var.zone_id
  name        = "Skip interactive challenge on public API/spec"
  description = "Header-less codegen/build clients can't pass JS/Managed Challenge"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  rules {
    action      = "skip"
    description = "openapi + /api/* on app.preview"
    expression  = "(http.host eq \"app.preview.trakrf.id\" and (starts_with(http.request.uri.path, \"/api/\") or http.request.uri.path in {\"/openapi.json\" \"/openapi.yaml\"}))"
    enabled     = true
    action_parameters { ruleset = "current" }   # skip remaining custom-phase rules; adjust to skip specific managed challenge if dashboard shows the challenge originates there
    logging { enabled = true }
  }
}
```
`just cloudflare`, then re-run Step 3 probes → expect 200. (Confirm in dashboard which product/phase issued the challenge and tune the skip target accordingly — do not broaden to skip the managed OWASP ruleset.)

- [ ] **Step 5: One-time cache purge of the spec path**

```bash
curl -s -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZID/purge_cache" \
  --data '{"files":["https://app.preview.trakrf.id/api/openapi.yaml","https://app.preview.trakrf.id/api/openapi.json"]}'
```

- [ ] **Step 6: Commit**

```bash
git add terraform/cloudflare/trakrf-id-waf.tf
git commit -m "feat(tra-856): managed WAF on trakrf.id + action-scoped challenge-skip for public API/spec"
```

### Task 1.4: Acceptance verification (the launch gate)

- [ ] **Step 1: Edge reachability + spec**

```bash
curl -s -D - -o /dev/null https://app.preview.trakrf.id/api/openapi.yaml | grep -iE "^HTTP|cf-ray"   # 200 + cf-ray
```

- [ ] **Step 2: API round-trip from non-operator path with a valid token**

From a non-operator host (CI runner / cloud shell — NOT 136.60.72.154): mint a token and read assets.
```bash
TOKEN=$(curl -s -X POST https://app.preview.trakrf.id/api/v1/oauth/token -d 'grant_type=client_credentials&client_id=...&client_secret=...' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" https://app.preview.trakrf.id/api/v1/assets   # expect 200
```
(Coordinate test client_credentials with platform.)

- [ ] **Step 3: Direct-to-origin refused**

```bash
curl -s -o /dev/null -w "%{http_code}\n" --resolve app.preview.trakrf.id:443:34.56.243.51 https://app.preview.trakrf.id/api/openapi.yaml   # expect refused/403 (cloudflare-allow rejects non-CF source)
```

- [ ] **Step 4: WAF events visible** — confirm in the Cloudflare dashboard (Security → Events) that requests to `app.preview.trakrf.id` appear.

- [ ] **Step 5: docs build green** — ping `docs`; confirm `f2216b1 → c973871`.

### Task 1.5: PR + merge + Linear

- [ ] **Step 1:** `gh pr create` for the Phase-1 branch; paste the diff for platform's four-point review (AOP CA = private not global [or note AOP deferred], action-scoped challenge-skip incl root aliases, cloudflare-allow scoping, two-part probe). Include the launch implication (prod inherits at TRA-375).
- [ ] **Step 2:** After platform review + `tofu plan` clean, `gh pr merge --merge`.
- [ ] **Step 3:** Move TRA-856 to In Review / Done as appropriate; note AOP status (in this PR or fast-follow).

---

## Phase 2 — Authenticated Origin Pulls (private-CA mTLS) [staged; in-scope unless wiring proves fiddly]

> Land while `cloudflare-allow` still works as backstop; verify mTLS, then it is primary (CIDR demoted). Never flip both locks at once. If the Traefik `TLSOption` + CA-upload wiring is heavier than the launch window allows, split this to a fast-follow ticket and ship Phase 1 with CIDR-lock (satisfies the AC).

### Task 2.1: Generate private CA + client cert (kept out of git)

- [ ] **Step 1:** Generate a private CA + a client cert/key with the `tls` provider (already required) or `openssl`. Store key material in the secret store (NOT committed). Document where.

### Task 2.2: Upload CA to Cloudflare + enable per-hostname AOP

- [ ] **Step 1:** `cloudflare_authenticated_origin_pulls_certificate` (per-zone, upload the client cert) + `cloudflare_authenticated_origin_pulls` (enable for `app.preview.trakrf.id`). `tofu plan`/`just cloudflare`.

### Task 2.3: Traefik TLSOption requiring the private CA

- [ ] **Step 1:** Create a Traefik `TLSOption` (e.g. `helm/traefik-config/templates/aop-clientauth.yaml`) with `clientAuth.clientAuthType: RequireAndVerifyClientCert` and `clientAuth.secretNames` → the PRIVATE CA cert (NOT Cloudflare's global AOP CA). Reference it from the preview public IngressRoute's `tls.options`. Apply via ArgoCD.

### Task 2.4: Verify mTLS lock, then add monitoring

- [ ] **Step 1:** Confirm a request through the CF edge still 200s (CF presents the client cert); confirm a direct origin hit without the cert is rejected at TLS. Then add the AOP CA + ACM cert expiry to the same cert-expiry monitoring as the LE/edge certs, and write the lockstep CA-rotation runbook (silent CA expiry → all-CF-traffic 403; same outage class this ticket removes).

---

## Self-review notes

- **Spec coverage:** inventory (0.1/1.x verify), ACM (1.1), DNS flip (1.2), origin lock CIDR (1.2) + AOP (Phase 2), WAF managed + action-scoped skip (1.3), cache purge (1.3 Step 5), all five acceptance criteria (1.4), out-of-scope items untouched. ✔
- **Known execution-time unknowns (intentional, with verify steps):** ACM billing enablement (1.1 Step 1), whether a challenge actually fires (1.3 Step 3 gates 1.3 Step 4), exact skip action_parameters target (tuned in dashboard). These are genuine apply-observe-adjust loops, not placeholders.
- **Lockstep ordering** between helm `cloudflare-allow` and the DNS flip is called out in 1.2 to avoid a self-inflicted 403 window.
