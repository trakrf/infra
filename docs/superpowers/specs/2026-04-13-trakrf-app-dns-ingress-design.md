# TrakRF production DNS + ingress + TLS — design

**Status:** approved 2026-04-13
**Scope:** new capability set; follow-on to TRA-351 M1. Spawns its own child tickets.
**Related:** TRA-351 (EKS M1), TRA-362 (External Secrets), TRA-364 (CNPG AZ HA), TRA-339 (Railway sunset).

## Goal

Stand up TrakRF's permanent customer-facing URL architecture and cert/ingress/edge stack on EKS, decoupled from Railway, with a cloud-portable design that carries forward to GKE (TRA-351 M2).

Net-new product surface lives on `trakrf.app`; marketing stays on `trakrf.id`. Initial subdomain `eks.trakrf.app` labels the multicloud-in-progress deploy and coexists with Railway (`app.trakrf.id`) until a formal cutover retires Railway and 301s the old URL.

## Non-goals

- External Secrets / Infisical plumbing (tracked under TRA-362; M1 continues manual `kubectl create` for sensitive material).
- Multi-region failover.
- Application auth / SSO / session policy.
- Public ingress for Grafana / ArgoCD UIs (internal-only for now; port-forward stays the interaction model).
- Migration of TrakRF backend off Railway (separate cutover ticket; this design defines the target, not the migration).

## Architecture

### Zone strategy

- `trakrf.id` → marketing root, managed today in `terraform/cloudflare/`; unchanged.
- **`trakrf.app` promoted from alt-redirect to primary zone.** Remove from `alt-domains.tf` locals map, add `trakrf-app.tf` with `cloudflare_zone` + zone settings + DNS records.
- `trakrf.com`, `getrf.id`, `trakrfid.com` remain alt-redirect zones (no change).
- Initial subdomain: **`eks.trakrf.app`** — explicitly tags the current EKS deploy so `gke.trakrf.app` (or a later `app.trakrf.app` canonical) slots in without confusion during M2 work.
- Later subdomains (not this ticket): `preview.trakrf.app`, `api.trakrf.app`, `app.trakrf.app`.
- **Railway cutover:** 301 `app.trakrf.id` → `app.trakrf.app` via Cloudflare redirect ruleset (same pattern already in `alt-domains.tf`). Lands with Railway sunset, not with this design.

### TLS + cert-manager

- `cert-manager` deployed via ArgoCD (Helm chart, `jetstack/cert-manager`).
- `ClusterIssuer`: ACME Let's Encrypt production, DNS-01 solver via Cloudflare provider.
- New Terraform resource **`cloudflare_api_token.cert_manager`** in `terraform/cloudflare/`, scoped `Zone > DNS > Write` on `trakrf.app` only (same minimum-scope pattern as the existing `traefik_dns` token in `d2ai-infra/bootstrap`).
- Token delivered to the cluster as a k8s Secret. **M1 posture:** manual `kubectl create secret generic cloudflare-api-token --from-literal=api-token=…` — consistent with current CNPG secret posture. **Eventual posture:** External Secrets Operator (TRA-362).
- Cert issued: `Certificate` for `*.trakrf.app` + apex `trakrf.app`, stored in ns `trakrf` or `cert-manager-certs` (decide in plan).

### Ingress — Traefik on AWS NLB

- Traefik deployed via ArgoCD (Helm chart, `traefik/traefik`).
- 2 replicas, pod anti-affinity across AZs, resource requests set for burstable workload.
- Service type `LoadBalancer` with `service.beta.kubernetes.io/aws-load-balancer-type: "nlb"`; NLB provisioned across all public subnets in `us-east-2`.
- CRDs: `IngressRoute` per hostname. First route: `eks.trakrf.app` → `trakrf-backend` service.
- Real-client-IP handling: **trust `CF-Connecting-IP` header**, because Cloudflare is always in front (proxied records). Traefik static config: `entryPoints.websecure.forwardedHeaders.trustedIPs` = published Cloudflare IPv4/IPv6 ranges (`https://www.cloudflare.com/ips-v4`, `/ips-v6`). Do **not** enable PROXY protocol — unnecessary when terminating behind CF.
- Middleware baseline (chain applied to all IngressRoutes by default):
  - Security headers (HSTS preload, X-Frame-Options DENY, X-Content-Type-Options nosniff, Referrer-Policy strict-origin-when-cross-origin).
  - HTTPS redirect on `:80` (defense-in-depth; CF already enforces HTTPS).
- TLS: `tls.secretName` pointing at the wildcard cert from cert-manager.

### Edge — Cloudflare CDN + WAF

- All `trakrf.app` DNS records **proxied** (orange-cloud).
- `eks.trakrf.app` → CNAME to the NLB hostname that AWS returns (`*.elb.us-east-2.amazonaws.com`).
- Cloudflare Managed Rules (WAF) enabled on `trakrf.app` zone.
- Cache rules:
  - `/api/*` → bypass cache.
  - Static asset paths (resolved during implementation) → aggressive edge caching with appropriate TTLs.
- CDN is edge-global by default; single-region origin latency only affects cache misses and API calls.

### Region + HA

- M1: EKS in `us-east-2`, multi-AZ node groups, multi-AZ NLB, single region.
- M2: GKE in `us-central1` (analog; portable Helm + ArgoCD layer unchanged).
- Known in-region HA gap: CNPG single-replica with AZ-pinned PV — tracked under **TRA-364**, deferred.

## Data flow

```
customer → Cloudflare edge (CF WAF, CF CDN, TLS termination)
         → CNAME eks.trakrf.app
         → AWS NLB (multi-AZ, L4)
         → Traefik pods (Deployment, multi-AZ)
         → IngressRoute dispatch by Host header
         → trakrf-backend Service → pods
```

cert-manager runs out-of-band: on cert request/renewal, creates a TXT record under `_acme-challenge.trakrf.app` via the Cloudflare API token, ACME solver verifies, LetsEncrypt issues, cert lands in k8s Secret, Traefik picks up the new material.

## Error handling / operational notes

- **NLB health:** Traefik exposes `/ping` on the web entryPoint; NLB target group uses HTTP health checks against this.
- **Cert renewal failures:** cert-manager surfaces events + metrics. Alert wiring lands with Prometheus stack (TRA-356). Non-blocking for this design.
- **CF outage:** since CF is on the hot path, a CF-wide outage takes the app offline. Acceptable risk for M1 given CF WAF/CDN value; documented trade-off. Mitigation path if it becomes real: switch records to gray-cloud (DNS-only) and expose NLB directly — requires a cert re-issue flow because CF edge certs would no longer apply; the Let's Encrypt cert is in-cluster on Traefik so the flip is viable.
- **Real-client-IP poisoning:** `CF-Connecting-IP` trust is contingent on Traefik restricting `trustedIPs` to Cloudflare ranges. If a request arrives directly at the NLB bypassing CF, headers from that request are untrusted and will be stripped. Implementation must keep the trusted-IP list in sync with CF's published ranges (quarterly at most — rare churn).

## Test plan / acceptance

- `curl -v https://eks.trakrf.app` → HTTP 200 from backend, cert chain valid, `cf-ray` header present.
- Traefik access log: `ClientAddr` (or equivalent) shows the real client IP, not a CF edge IP.
- `dig eks.trakrf.app` → Cloudflare edge A/AAAA records.
- Force cert-manager renewal (`kubectl cert-manager renew`); verify new cert served within 5 minutes, zero downtime.
- Security headers present on response (`Strict-Transport-Security`, `X-Content-Type-Options`, etc.).
- `curl` against `http://eks.trakrf.app` redirects 301/308 to `https://`.

## Implementation ticket split (children under TRA-351 or a new epic)

Ordering reflects dependency chain; first 4 can proceed mostly in parallel until step 5.

1. **Promote `trakrf.app` zone** — `terraform/cloudflare/`: remove from alt-domains locals, add `trakrf-app.tf` with zone + settings + (empty) records block. Plan-only first, apply once the full chain is ready to avoid a zone with no records.
2. **Cloudflare API token for cert-manager** — `terraform/cloudflare/`: new `cloudflare_api_token.cert_manager`, scoped `Zone > DNS > Write` on `trakrf.app` only. Sensitive output.
3. **cert-manager via ArgoCD** — Helm chart + Application manifest in `argocd/`, `ClusterIssuer` with Cloudflare DNS-01 solver, manual Secret delivery for token (consistent with current CNPG pattern).
4. **Traefik via ArgoCD** — Helm chart + Application manifest in `argocd/`, NLB service, middleware baseline, wildcard cert `Certificate` resource.
5. **`eks.trakrf.app` cutover** — DNS CNAME to NLB hostname, IngressRoute for trakrf-backend, verify end-to-end per acceptance criteria.
6. **Railway sunset redirect** — ships with the eventual migration ticket (not this effort): Cloudflare redirect ruleset 301 `app.trakrf.id` → `app.trakrf.app`.

## Open questions / deferred decisions

- **Wildcard vs per-host certs.** Default to wildcard `*.trakrf.app` for simplicity; revisit if a compliance ask requires per-host.
- **ArgoCD ingress exposure.** Port-forward stays the interaction model for M1. Revisit when ArgoCD Notifications / external consumers need webhook ingress.
- **Grafana public URL.** Out of scope here; tracked with TRA-356 follow-ups.
