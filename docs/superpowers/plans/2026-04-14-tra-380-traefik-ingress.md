# TRA-380 Traefik Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Traefik as the cluster ingress behind an AWS NLB via ArgoCD, with Cloudflare-trusted forwarded-headers and a security-header middleware baseline. No hostname IngressRoutes in this ticket (TRA-381 follow-up).

**Architecture:** Two ArgoCD Applications under `argocd/applications/`:
1. `traefik` — upstream `traefik/traefik` Helm chart, configured via inline `helm.values`. Deploys Traefik Deployment + LoadBalancer Service annotated for AWS NLB.
2. `traefik-config` — in-repo chart at `helm/traefik-config/` containing Traefik CRDs (`Middleware`, `TLSStore`). Kept separate because the upstream chart owns Traefik itself and the CRDs are declared independently once they're installed by the upstream chart.

Both Applications target a new `traefik` namespace. Trusted-IP list is generated from Cloudflare's published ranges and embedded verbatim in `helm.values` (refreshed manually — CF changes ~quarterly). No PROXY protocol. Default TLS store references `trakrf-wildcard-tls` (produced by TRA-379 cert-manager work; name agreed here so TRA-379 matches).

**Tech Stack:** ArgoCD, Helm, Traefik v3 (`traefik/traefik` chart), AWS NLB via `service.beta.kubernetes.io/aws-load-balancer-type: nlb`.

---

## File Structure

- Create `argocd/applications/traefik.yaml` — Application for upstream Traefik chart.
- Create `argocd/applications/traefik-config.yaml` — Application for in-repo config chart.
- Create `helm/traefik-config/Chart.yaml`
- Create `helm/traefik-config/values.yaml` (empty but present for `helm lint`)
- Create `helm/traefik-config/templates/security-headers.yaml` — `Middleware` (headers).
- Create `helm/traefik-config/templates/redirect-https.yaml` — `Middleware` (redirectScheme).
- Create `helm/traefik-config/templates/default-chain.yaml` — `Middleware` (chain).
- Create `helm/traefik-config/templates/tls-store.yaml` — `TLSStore` default.
- Modify `argocd/projects/trakrf.yaml` — add `traefik` namespace + `https://traefik.github.io/charts` sourceRepo.
- Modify `.github/workflows/ci.yml` — add `traefik-config` to `helm` matrix.

---

### Task 1: Extend ArgoCD AppProject

**Files:**
- Modify: `argocd/projects/trakrf.yaml`

- [ ] **Step 1: Add Traefik Helm repo + `traefik` namespace to AppProject**

Edit `argocd/projects/trakrf.yaml`. Under `spec.sourceRepos` add `- "https://traefik.github.io/charts"`. Under `spec.destinations` add:

```yaml
    - server: https://kubernetes.default.svc
      namespace: traefik
```

- [ ] **Step 2: Verify yaml is valid**

Run: `kubectl apply --dry-run=client -f argocd/projects/trakrf.yaml`
Expected: `appproject.argoproj.io/trakrf configured (dry run)`.

- [ ] **Step 3: Commit**

```bash
git add argocd/projects/trakrf.yaml
git commit -m "chore(tra-380): allow traefik ns and helm repo in trakrf AppProject"
```

---

### Task 2: Create in-repo `traefik-config` Helm chart skeleton

**Files:**
- Create: `helm/traefik-config/Chart.yaml`
- Create: `helm/traefik-config/values.yaml`

- [ ] **Step 1: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: traefik-config
description: Traefik Middleware + TLSStore baseline for the cluster
type: application
version: 0.1.0
appVersion: "1.0"
```

- [ ] **Step 2: Write empty `values.yaml`**

```yaml
# Intentionally empty — manifests are static.
```

- [ ] **Step 3: `helm lint` should pass (no templates yet)**

Run: `helm lint helm/traefik-config`
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 4: Commit**

```bash
git add helm/traefik-config/Chart.yaml helm/traefik-config/values.yaml
git commit -m "chore(tra-380): scaffold helm/traefik-config chart"
```

---

### Task 3: Add security-headers Middleware

**Files:**
- Create: `helm/traefik-config/templates/security-headers.yaml`

- [ ] **Step 1: Write the manifest**

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: traefik
spec:
  headers:
    stsSeconds: 63072000
    stsIncludeSubdomains: true
    stsPreload: true
    forceSTSHeader: true
    frameDeny: true
    contentTypeNosniff: true
    referrerPolicy: strict-origin-when-cross-origin
```

- [ ] **Step 2: Lint + template**

Run: `helm lint helm/traefik-config && helm template helm/traefik-config`
Expected: lint passes; rendered output contains `kind: Middleware` and `name: security-headers`.

- [ ] **Step 3: Commit**

```bash
git add helm/traefik-config/templates/security-headers.yaml
git commit -m "feat(tra-380): add security-headers middleware"
```

---

### Task 4: Add HTTPS redirect Middleware

**Files:**
- Create: `helm/traefik-config/templates/redirect-https.yaml`

- [ ] **Step 1: Write the manifest**

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: traefik
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

- [ ] **Step 2: Lint + template**

Run: `helm lint helm/traefik-config && helm template helm/traefik-config | grep -A2 'name: redirect-https'`
Expected: redirectScheme block present.

- [ ] **Step 3: Commit**

```bash
git add helm/traefik-config/templates/redirect-https.yaml
git commit -m "feat(tra-380): add redirect-https middleware"
```

---

### Task 5: Add default chain Middleware

**Files:**
- Create: `helm/traefik-config/templates/default-chain.yaml`

- [ ] **Step 1: Write the manifest**

Chain composes the two middlewares above. Applied by referencing `default-chain@kubernetescrd` from IngressRoutes (done in TRA-381).

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: default-chain
  namespace: traefik
spec:
  chain:
    middlewares:
      - name: security-headers
        namespace: traefik
      - name: redirect-https
        namespace: traefik
```

- [ ] **Step 2: Lint + template**

Run: `helm template helm/traefik-config | grep -A8 'name: default-chain'`
Expected: shows the chain block referencing both child middlewares.

- [ ] **Step 3: Commit**

```bash
git add helm/traefik-config/templates/default-chain.yaml
git commit -m "feat(tra-380): add default chain middleware"
```

---

### Task 6: Add default TLSStore

**Files:**
- Create: `helm/traefik-config/templates/tls-store.yaml`

Secret `trakrf-wildcard-tls` is produced by TRA-379 (cert-manager). Name coordinated here so TRA-379 emits exactly this name. It's fine if the Secret doesn't exist yet — Traefik logs a warning and serves its self-signed cert until the Secret lands.

- [ ] **Step 1: Write the manifest**

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik
spec:
  defaultCertificate:
    secretName: trakrf-wildcard-tls
```

- [ ] **Step 2: Lint + template**

Run: `helm lint helm/traefik-config && helm template helm/traefik-config`
Expected: lint passes; rendered output includes `kind: TLSStore` named `default`.

- [ ] **Step 3: Commit**

```bash
git add helm/traefik-config/templates/tls-store.yaml
git commit -m "feat(tra-380): add default TLSStore referencing wildcard cert"
```

---

### Task 7: Add `traefik-config` to CI helm matrix

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add chart to matrix**

Change line 39 from `chart: [trakrf-backend, trakrf-ingester]` to:

```yaml
        chart: [trakrf-backend, trakrf-ingester, traefik-config]
```

- [ ] **Step 2: Reproduce CI checks locally**

Run: `helm lint helm/traefik-config && helm template helm/traefik-config`
Expected: both pass clean.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci(tra-380): lint + template traefik-config chart"
```

---

### Task 8: Fetch current Cloudflare trusted-IP ranges

**Files:** none (scratch — captured into next task's values)

- [ ] **Step 1: Fetch IPv4 ranges**

Run: `curl -fsSL https://www.cloudflare.com/ips-v4`
Save output. Expect ~15 CIDRs (e.g. `173.245.48.0/20`, `103.21.244.0/22`, `2400:cb00::/32`, ...).

- [ ] **Step 2: Fetch IPv6 ranges**

Run: `curl -fsSL https://www.cloudflare.com/ips-v6`
Save output. Expect ~7 CIDRs.

- [ ] **Step 3: Format as YAML list**

Build one YAML list with every IPv4 + IPv6 CIDR for use in Task 9's `trustedIPs`. No placeholder — the actual list goes verbatim into the values block.

---

### Task 9: Create ArgoCD Application for upstream Traefik chart

**Files:**
- Create: `argocd/applications/traefik.yaml`

- [ ] **Step 1: Find latest `traefik/traefik` chart version**

Run:
```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update traefik
helm search repo traefik/traefik --versions | head
```
Expected: pick the latest stable minor (pin to `"36.*"` or whatever the current stable is). Record version in targetRevision.

- [ ] **Step 2: Write the Application manifest**

Replace `<IPV4_CIDRS>` / `<IPV6_CIDRS>` with the ranges from Task 8. Replace `<CHART_VERSION_PIN>` with the pin from Step 1 (e.g. `"36.*"`).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
spec:
  project: trakrf
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: "<CHART_VERSION_PIN>"
    helm:
      values: |
        deployment:
          replicas: 2
        podDisruptionBudget:
          enabled: true
          minAvailable: 1
        affinity:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  topologyKey: topology.kubernetes.io/zone
                  labelSelector:
                    matchLabels:
                      app.kubernetes.io/name: traefik
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
        service:
          type: LoadBalancer
          annotations:
            service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
            service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
            service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
            service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
            service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "HTTP"
            service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/ping"
            service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "traffic-port"
        ports:
          web:
            port: 8000
            exposedPort: 80
            protocol: TCP
          websecure:
            port: 8443
            exposedPort: 443
            protocol: TCP
            tls:
              enabled: true
          ping:
            port: 8082
            expose:
              default: true
            exposedPort: 80
            protocol: TCP
        ping:
          enabled: true
          entryPoint: ping
        additionalArguments:
          - "--entryPoints.websecure.forwardedHeaders.trustedIPs=<IPV4_CIDRS_COMMA_JOINED>,<IPV6_CIDRS_COMMA_JOINED>"
          - "--entryPoints.web.forwardedHeaders.trustedIPs=<IPV4_CIDRS_COMMA_JOINED>,<IPV6_CIDRS_COMMA_JOINED>"
        providers:
          kubernetesCRD:
            enabled: true
            allowCrossNamespace: true
          kubernetesIngress:
            enabled: false
        ingressRoute:
          dashboard:
            enabled: false
        logs:
          access:
            enabled: true
        metrics:
          prometheus:
            enabled: true
            serviceMonitor:
              enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Notes:
- `trustedIPs` passed via `additionalArguments` (Traefik CLI) because the Helm chart doesn't expose `forwardedHeaders.trustedIPs` as a first-class value in a structured way. Join the CIDR list with commas, no spaces.
- Health-check is `/ping` on the dedicated `ping` entryPoint so NLB TG health checks don't require TLS.
- `ServerSideApply=true` matches the `trakrf-db` Application pattern — Traefik CRDs are large and SSA avoids last-applied-config size limits.

- [ ] **Step 3: Dry-run validate**

Run: `kubectl apply --dry-run=client -f argocd/applications/traefik.yaml`
Expected: `application.argoproj.io/traefik configured (dry run)`.

- [ ] **Step 4: Commit**

```bash
git add argocd/applications/traefik.yaml
git commit -m "feat(tra-380): argocd application for traefik on nlb with cf trusted ips"
```

---

### Task 10: Create ArgoCD Application for `traefik-config`

**Files:**
- Create: `argocd/applications/traefik-config.yaml`

- [ ] **Step 1: Write the manifest**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: trakrf
  source:
    repoURL: https://github.com/trakrf/infra.git
    targetRevision: main
    path: helm/traefik-config
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Sync-wave `1` ensures this syncs after the `traefik` Application (wave `0`) so Traefik CRDs exist before Middlewares/TLSStore are applied.

- [ ] **Step 2: Dry-run validate**

Run: `kubectl apply --dry-run=client -f argocd/applications/traefik-config.yaml`
Expected: `application.argoproj.io/traefik-config configured (dry run)`.

- [ ] **Step 3: Commit**

```bash
git add argocd/applications/traefik-config.yaml
git commit -m "feat(tra-380): argocd application for traefik-config middleware chart"
```

---

### Task 11: Sync and verify in-cluster

**Files:** none (runtime verification)

- [ ] **Step 1: Ensure ArgoCD picks up the new Applications**

The root app-of-apps is already `automated: true, selfHeal: true` (`argocd/root.yaml`), so merging to main will sync. For pre-merge verification on a push-to-branch flow, run locally from the feature branch:

```bash
kubectl apply -f argocd/applications/traefik.yaml
kubectl apply -f argocd/applications/traefik-config.yaml
```

- [ ] **Step 2: Wait for Traefik rollout**

Run: `kubectl rollout status deployment/traefik -n traefik --timeout=180s`
Expected: `deployment "traefik" successfully rolled out`.

- [ ] **Step 3: Confirm NLB provisioned**

Run: `kubectl get svc -n traefik traefik -o wide`
Expected: `EXTERNAL-IP` column shows `<name>.elb.us-east-2.amazonaws.com`. May take 1–2 min.

- [ ] **Step 4: Wait for NLB DNS to resolve**

Run:
```bash
NLB=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
until dig +short "$NLB" | grep -qE '^[0-9]'; do echo waiting for NLB DNS; sleep 10; done
echo "NLB: $NLB"
```
Expected: prints NLB hostname with resolving A records.

- [ ] **Step 5: Hit NLB on 443 with Host header**

Run:
```bash
curl -ksv -H 'Host: eks.trakrf.app' "https://$NLB/" 2>&1 | tee /tmp/traefik-probe.txt
```
Expected:
- TLS handshake completes (Traefik default cert is fine — wildcard from TRA-379 not in yet).
- HTTP/1.1 404 response (no IngressRoute matches).
- Response headers include: `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`.

**Caveat:** security headers only apply when the `default-chain` middleware is attached to an IngressRoute. A pure 404 from Traefik's catch-all will NOT carry those headers — they ride on matched IngressRoutes, not 404s. This is expected behavior for TRA-380. If verification of headers is required here, attach a minimal catch-all IngressRoute temporarily (see Step 6); otherwise defer header verification to TRA-381 when `eks.trakrf.app` goes live and document this in the PR description.

- [ ] **Step 6: (Optional) Temporary header-verification IngressRoute**

If you want to prove the middleware chain is wired before TRA-381, apply a throwaway IngressRoute pointing at a noop service and delete it before merge:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: probe
  namespace: traefik
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`probe.local`)
      kind: Rule
      services:
        - name: traefik
          port: 80
      middlewares:
        - name: default-chain
          namespace: traefik
  tls: {}
```

Apply, curl with `-H 'Host: probe.local'`, confirm headers, delete. Do **not** commit this manifest.

- [ ] **Step 7: Confirm `/ping` health check**

Run: `curl -sv "http://$NLB/ping"`
Expected: `HTTP/1.1 200 OK`, body `OK`. (NLB target group must be healthy for this to answer.)

- [ ] **Step 8: Check Traefik logs for trusted-IP parsing errors**

Run: `kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=200 | grep -iE 'error|trusted'`
Expected: no errors about `trustedIPs` parsing; CIDR list logged on boot.

---

### Task 12: Open PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin $(git branch --show-current)
```

- [ ] **Step 2: Create PR**

Title: `feat(tra-380): traefik via argocd on nlb with cf trusted ips`

Body must include:
- Summary of the two Applications.
- Note about wildcard cert `trakrf-wildcard-tls` coming from TRA-379.
- Verification transcript from Task 11 (NLB hostname, 404 response, `/ping` 200).
- Caveat about security headers only being present on matched IngressRoutes (TRA-381).
- Test plan checklist.

Run:
```bash
gh pr create --title "feat(tra-380): traefik via argocd on nlb with cf trusted ips" --body "$(cat <<'EOF'
## Summary
- Adds `argocd/applications/traefik.yaml` — upstream `traefik/traefik` Helm chart, 2 replicas, AZ anti-affinity, LoadBalancer Service annotated for AWS NLB, CF IP ranges as `entryPoints.*.forwardedHeaders.trustedIPs`, `/ping` enabled for NLB TG health checks.
- Adds `argocd/applications/traefik-config.yaml` + `helm/traefik-config/` — Middleware chain (HSTS preload, frameDeny, nosniff, strict-origin-when-cross-origin, redirect :80→https) and default TLSStore referencing `trakrf-wildcard-tls` (TRA-379 will produce this Secret).
- Extends trakrf AppProject with `traefik` namespace + traefik helm repo.
- CI: helm lint/template now covers `traefik-config`.

## Deferred
- No IngressRoute for `eks.trakrf.app` — TRA-381.
- `trakrf-wildcard-tls` Secret — TRA-379. Traefik serves its self-signed cert until then; no runtime failure.

## Test plan
- [x] `helm lint helm/traefik-config` passes.
- [x] `kubectl get svc -n traefik traefik` shows NLB hostname.
- [x] `curl -k -H 'Host: eks.trakrf.app' https://<nlb>/` → Traefik 404.
- [x] `/ping` returns 200 on NLB.
- [ ] Security headers verified on matched IngressRoute (deferred to TRA-381).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Report URL back to user.

---

## Self-Review Notes

- **CF IP list freshness:** baked verbatim into `traefik.yaml` values. If/when CF publishes a new range, refresh with a follow-up PR (memory-worthy: CF ranges churn roughly quarterly).
- **Header verification gap:** Traefik's built-in 404 handler does not run middlewares; plan documents this explicitly (Task 11 Step 5 caveat). Avoid claiming headers are verified unless Step 6 was run.
- **CRD ordering:** `traefik-config` depends on Traefik CRDs installed by the upstream chart. Solved via `argocd.argoproj.io/sync-wave` annotation.
- **ArgoCD controller OOM risk:** Traefik chart is much smaller than kube-prometheus-stack (argocd lessons memory); controller resources are fine.
- **No PROXY protocol:** confirmed per spec — would double-decode since CF doesn't send PROXY headers over plain TCP to an NLB.
