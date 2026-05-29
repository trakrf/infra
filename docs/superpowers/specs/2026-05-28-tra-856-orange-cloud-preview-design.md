# TRA-856 — Orange-cloud preview environment + remove IP allowlist

**Status:** Design
**Date:** 2026-05-28
**Ticket:** TRA-856 (related: TRA-375 prod cutover epic; precedent: TRA-388 ACM (canceled, EKS-era), TRA-381 EKS orange cutover)
**Repo:** trakrf/infra

## Problem

`app.preview.trakrf.id` is grey-clouded (Cloudflare DNS-only, `proxied = false`) and gated by a Traefik `breakglass-allow` IPAllowList middleware whose source range is a single operator `/32` (`136.60.72.154/32`). The entire host — including the meant-to-be-public `/api/openapi.yaml` — is reachable only from that one IP.

This surfaced as the **docs preview build freeze**: the Docusaurus/redocusaurus build live-fetches `https://app.preview.trakrf.id/api/openapi.yaml` at build time. From Cloudflare Pages' build egress (not the operator IP) that fetch returns **403**, so every preview build since 2026-05-24 failed and Cloudflare Pages kept serving the last-good artifact (commit `f2216b1`, ~4 days stale). The app itself is exonerated — `/api/openapi.{json,yaml}` is registered bare/unauthenticated above all auth middleware (platform-confirmed); the 403 is purely the Traefik IPAllowList.

The fix is the long-settled ingress stance: **public customer-facing names go orange (Cloudflare owns CDN/WAF/DDoS); grey origin subdomains (`gke.trakrf.id`, `mqtt.gke.trakrf.id`) stay direct.** This ticket executes that for the preview environment. Prod is out of scope (TRA-375).

## Goal

`app.preview.trakrf.id` served through the Cloudflare edge (edge TLS + WAF + DDoS), origin locked so it is only reachable via Cloudflare, and the operator `/32` allowlist removed from the public route. This unblocks the docs build (live-fetch works from any network) and matches the intended production posture.

## Scope (preview only)

1. **Hostname inventory** — confirm the in-scope set before flipping. Known public host: `app.preview.trakrf.id`. Verify no other `*.preview.trakrf.id` HTTP siblings need the same treatment.
2. **Edge TLS (ACM)** — provision a Cloudflare Advanced Certificate for `app.preview.trakrf.id` / `*.preview.trakrf.id`. Free Universal SSL covers only `trakrf.id` + `*.trakrf.id` (one label deep); the two-label `app.preview.trakrf.id` fails the edge TLS handshake without an advanced cert. ~$10/mo ACM subscription. (GKE-era revival of canceled TRA-388.)
3. **DNS flip** — set `app.preview.trakrf.id` `proxied = true` in `terraform/cloudflare/` (source of truth is tofu, not the dashboard).
4. **Origin lock** — replace the operator-`/32` `breakglass-allow` on the public preview route. End state: **per-hostname Authenticated Origin Pulls (mTLS) backed by a PRIVATE CA we control**, with the Cloudflare-CIDR `cloudflare-allow` IPAllowList as backstop. Staged (see Sequencing).
5. **WAF** — confirm the managed ruleset is active for the preview host, and add an **action-scoped challenge-skip** (Bot Fight / JS / Managed *Challenge* only) on `/api/*` plus the root `/openapi.json` and `/openapi.yaml` aliases — header-less build/codegen clients can't pass an interactive challenge. OWASP/SQLi/XSS managed rules stay ON for the write surface. **"Skip challenge" ≠ "skip WAF."**
6. **Cache** — one-time purge of `/api/openapi.*` after the flip (clears any stale 403 cached during the breakglass window).

## Out of scope

- Production cutover to orange cloud (TRA-375) and the prod `app.trakrf.id` route enablement.
- `mqtt.gke.trakrf.id` / any non-HTTP ingress — stays grey, direct. (Structurally impossible to orange-cloud anyway: `gke.trakrf.id` is a delegated Cloud DNS subzone, not in the Cloudflare zone.)
- Backend hardening follow-ups owned by platform: prefer `CF-Connecting-IP` over XFF-first-hop (`auth.go:444`, `orgs/me.go:140`, `logger/middleware.go:29`) now that `proxied=true` makes XFF-first-hop spoofable; and a global `MaxBytesReader` body-size backstop.

## Architecture

### Per-host end state

| Host | Cloud | Edge TLS | Origin lock | Purpose |
|---|---|---|---|---|
| `app.preview.trakrf.id` | 🟠 orange | ACM advanced cert | AOP (private-CA mTLS) + `cloudflare-allow` backstop | public preview API |
| `app.preview.gke.trakrf.id` | ⚪ grey | LE via cert-manager DNS-01 (WI/Cloud DNS) | `breakglass-allow` (operator `/32`) | direct origin / test / break-glass |
| `mqtt.gke.trakrf.id`, `*.gke.trakrf.id` | ⚪ grey (Cloud DNS) | n/a | n/a | non-HTTP / direct |

**Request path (orange):** client → CF edge (TLS via ACM cert; WAF/DDoS) → CF→origin over the existing Cloudflare Origin Cert (`origin-cert.tf` already issued with SANs `trakrf.id`, `*.trakrf.id`, `*.preview.trakrf.id`) → GKE Traefik. Origin refuses any connection not presenting the AOP client cert (and, as backstop, not from a Cloudflare CIDR).

### Components touched

- **`terraform/cloudflare/main.tf`** — `cloudflare_record.app_preview`: `proxied = false → true`; update the comment.
- **`terraform/cloudflare/`** (new file, e.g. `acm.tf`) — `cloudflare_certificate_pack` (type `advanced`) for `*.preview.trakrf.id` + `app.preview.trakrf.id`. NOTE: the ACM subscription itself is a billing enablement on the zone and may need to be turned on out-of-band (dashboard/billing) before the advanced cert pack will create; flag during implementation.
- **`terraform/cloudflare/`** (new, e.g. `waf.tf`) — `cloudflare_ruleset` adding an action-scoped challenge-skip custom rule for `(http.host eq "app.preview.trakrf.id" and (starts_with(http.request.uri.path, "/api/") or http.request.uri.path in {"/openapi.json" "/openapi.yaml"}))`. Confirm the zone's managed WAF ruleset is deployed.
- **AOP origin lock** — private CA material (generated, kept out of git / in the secret store), uploaded via `cloudflare_authenticated_origin_pulls_certificate` + enabled per-hostname via `cloudflare_authenticated_origin_pulls` for `app.preview.trakrf.id`. Traefik side: a `TLSOption` with `clientAuth.clientAuthType: RequireAndVerifyClientCert` and `clientAuth.secretNames` referencing the private CA, referenced from the preview public IngressRoute. **Use the PRIVATE-CA / per-hostname variant only — never Cloudflare's global/shared AOP cert (it proves "some CF customer," not "our zone" — an illusory lock).**
- **`argocd/root/templates/_helpers.tpl`** (`trakrf-backend.ingressValues`) — split origin lock by route purpose: the public `trakrf-id-direct` route (`app.<env>.trakrf.id`) uses `cloudflare-allow` (+ AOP TLSOption); the `gke-direct` route (`app.<env>.gke.trakrf.id`) keeps `breakglass-allow`. Because prod's `trakrf-id-direct` route is gated off (`appTrakrfIdRouteEnabled=false` until TRA-375), this template change affects preview only today.
- **Operational (runbook, not IaC):** one-time `/api/openapi.*` cache purge; add the ACM cert + AOP CA expiry to the same cert-expiry monitoring as the edge/LE certs, with a lockstep CA-rotation runbook (a silent AOP CA expiry would 403 all CF traffic — the same outage class this ticket removes).

## Sequencing (Decision: B — staged)

**Phase 0 — fast unblock (minutes):** remove the `breakglass-allow` middleware from the preview public route so the host is reachable (fully-open grey). The docs build goes green immediately and the BB cycle unblocks. Acceptable transient exposure: pre-launch preview, no production data.

**Phase 1 — durable orange end state:** provision ACM cert (additive, safe to land ahead) → flip DNS `proxied=true` → swap the public route to `cloudflare-allow` → add private-CA AOP as primary lock (CIDR demoted to backstop), verifying mTLS works before relying on it (never flip both locks at once) → add WAF challenge-skip rule → purge cache.

Apply ordering within Phase 1 matters: the ACM cert must be active before the DNS flip (else edge TLS errors), and the route must move to `cloudflare-allow` in lockstep with the DNS flip (a CF-proxied request whose origin still enforces the operator `/32` would 403 even for the operator).

## Acceptance criteria

- [ ] Off-allowlist client reaches `https://app.preview.trakrf.id` → 200, response carries `cf-ray` (traversed the CF edge).
- [ ] Header-less GET of `https://app.preview.trakrf.id/api/openapi.yaml` through the edge → 200; docs preview build advances `f2216b1 → c973871` (current `preview` tip) and goes green.
- [ ] A non-operator host with a valid `client_credentials` token can mint at `/api/v1/oauth/token` AND read `/api/v1/assets` → 200 (the launch gate — proves the API surface is reachable, not just the spec).
- [ ] Header-less GET of root aliases `/openapi.yaml` / `/openapi.json` is not interactively challenged at the edge.
- [ ] Direct-to-origin HTTPS (bypassing CF, hitting `34.56.243.51`) is refused — AOP mTLS rejects, CIDR backstop rejects.
- [ ] WAF events for `app.preview.trakrf.id` observable in the Cloudflare dashboard; managed ruleset confirmed active.
- [ ] `tofu plan` clean; ArgoCD root re-synced (`scripts/apply-root-app.sh`) so the helm middleware change takes effect.

## Risks / notes

- **ACM billing enablement** may be a manual prerequisite to the advanced cert pack creating via tofu.
- **AOP CA lifecycle** introduces a new drift vector replacing CIDR drift — mitigated by expiry monitoring + lockstep rotation runbook.
- **Apply mechanics:** CF resources via `tofu` (`just cloudflare`); helm/middleware via ArgoCD root (`scripts/apply-root-app.sh <cluster>` after merge — root chart edits don't auto-sync).
- If private-CA AOP wiring (CA upload + Traefik `TLSOption`) proves fiddly under time pressure, split it to a fast-follow ticket and ship Phase 1 with `cloudflare-allow` CIDR-lock alone (satisfies the AC's "origin allowlist scoped to Cloudflare IPs OR origin pull cert"); AOP remains the intended end state.
