# TRA-381 — `eks.trakrf.app` cutover: DNS + IngressRoute + end-to-end verify

Step 5 of [TRA-368](https://linear.app/trakrf/issue/TRA-368). Final integration on top of steps 1–4 (zone promoted, cert-manager + wildcard cert, Traefik on NLB, default middleware chain). Parent design: `docs/superpowers/specs/2026-04-13-trakrf-app-dns-ingress-design.md`.

## Goal

Expose the `trakrf-backend` (React SPA + Go API, single binary) on `https://eks.trakrf.app` via Cloudflare → NLB → Traefik, with WAF + cache rules tuned to the SPA/API split. Railway keeps serving `app.trakrf.id` (prod); `eks.trakrf.app` is a new **demo** surface.

## Components

### 1. Cloudflare (`terraform/cloudflare/`)

**DNS.** New CNAME on the `trakrf.app` zone:

- name: `eks`
- value: NLB hostname (Traefik Service, from step 4)
- proxied: `true` (orange-cloud)

NLB hostname wiring: add `variable "eks_nlb_hostname"` and set it in tfvars. Operator pastes the value once after the Traefik Service provisions the NLB. Rationale: the cloudflare stack has no state dependency on the aws stack, NLB hostname rarely changes, no cross-stack data source plumbing needed.

**WAF.** Enable Cloudflare Free Managed Ruleset on the `trakrf.app` zone, **block mode from day one**. Small traffic + low false-positive rate on the free ruleset make a log-only soak unnecessary.

**Cache rules.** Zone-scoped, matching `hostname eq "eks.trakrf.app"`, in this order:

1. `URI Path starts_with "/api/"` → **bypass cache**
2. `URI Path starts_with "/assets/"` → **cache everything**, edge TTL 1y, respect origin `Cache-Control: immutable` (Vite emits hashed filenames + `immutable`)
3. default fallthrough → standard CF cache behavior (short TTL for `index.html`, icons, manifest)

### 2. Kubernetes (`helm/trakrf-backend/`)

Add `templates/ingressroute.yaml`:

- `kind: IngressRoute` (traefik.io/v1alpha1)
- `entryPoints: [websecure]`
- match: `Host(` + chart value + `)`
- `middlewares: [{ name: default-chain, namespace: traefik }]` (from `helm/traefik-config/`)
- `services: [{ name: trakrf-backend, port: <http> }]`
- `tls.secretName: trakrf-app-wildcard-tls` (wildcard cert from TRA-379, in `trakrf` namespace)
- gated by `values.yaml: ingress.enabled` (default `true`) and `ingress.host` (default `eks.trakrf.app`)

HTTPS redirect, HSTS, and `X-Content-Type-Options` come from `default-chain` — no per-route duplication.

### 3. No changes to

- `trakrf.id` zone — marketing + Railway prod remain untouched
- Traefik deployment or middleware chain (TRA-380 baseline is sufficient)
- cert-manager config or wildcard cert (TRA-379)
- `trakrf-backend` Deployment/Service (only adds IngressRoute)

## Data flow

```
client → CF edge (WAF, cache) → NLB (TCP 443, PROXY proto off; CF IPs trusted)
       → Traefik (TLS terminate via TLSStore, default-chain middleware)
       → trakrf-backend Service → Go binary (serves embedded SPA + /api/*)
```

Real client IP preserved via `CF-Connecting-IP`; Traefik `trustedIPs` already configured for CF ranges in TRA-380.

## Acceptance (from ticket)

- `curl -v https://eks.trakrf.app` → 200, valid cert chain, `cf-ray` header present
- Traefik access log shows real client IP (not CF edge)
- `dig eks.trakrf.app` → CF edge A/AAAA
- `kubectl cert-manager renew -n trakrf trakrf-app-wildcard` → new cert served in ≤5 min, zero downtime
- Response includes `Strict-Transport-Security` + `X-Content-Type-Options` + chain-provided headers
- `curl -I http://eks.trakrf.app` → 301/308 → https

## Out of scope

- Retiring Railway (`app.trakrf.id`) → TRA-339
- Rate limiting, bot management, advanced WAF rulesets — revisit after real traffic exists
- `trakrf-ingester` public exposure — internal only for now

## Risks

- **NLB hostname drift**: if the Traefik Service is recreated and AWS assigns a new NLB, the tfvars value goes stale silently. Mitigation: the acceptance `dig` check catches this on cutover; document the paste step in the ticket.
- **Cache rule ordering**: CF evaluates rules top-to-bottom. `/api/*` bypass must precede the `/assets/*` cache rule (there is no overlap today, but order guards against future path additions).
