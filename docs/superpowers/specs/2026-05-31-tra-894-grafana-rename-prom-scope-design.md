# TRA-894 — Grafana → grafana.trakrf.id + scope prod Prometheus to prod

**Status:** approved-for-autonomous-build (user authorized spec→plan→build→PR without per-gate approval; hold before merge)
**Date:** 2026-05-31
**Ticket:** TRA-894 (High)

## Problem

Two bundled changes on the shared GKE prod cluster:

1. **Grafana host.** The GKE prod cutover (TRA-375) left `grafana.gke.trakrf.id`
   unreachable. The `.gke.` qualifier was a pre-Cloudflare-ACM workaround (needed
   when only the delegated `gke.trakrf.id` Cloud DNS zone could issue a public
   cert for a GKE host). Now that GKE *is* prod, the qualifier is redundant: a
   single-label `grafana.trakrf.id` is covered by Cloudflare Universal SSL
   (`*.trakrf.id`) at the edge and by the existing CF Origin CA cert
   (`trakrf-id-origin-tls`, SAN `*.trakrf.id`) at the origin — the same orange
   pattern already used for `app.trakrf.id`.

2. **Prometheus scope.** Preview and prod share one GKE cluster and one
   kube-prometheus-stack (in `monitoring`). The Prometheus CR runs with
   `*SelectorNilUsesHelmValues: false` and **no namespace selector**, so it
   discovers ServiceMonitors cluster-wide. `trakrf-backend` and `trakrf-ingester`
   emit a ServiceMonitor into *every* env namespace, so prod Prometheus currently
   scrapes the `trakrf-preview` targets. Preview is intentionally unmonitored;
   its volatility should not enter prod monitoring.

## Outcome

- `https://grafana.trakrf.id` reachable, valid TLS, login works (no redirect loop).
- `grafana.gke.trakrf.id` retired at the routing + cert layer.
- Prod Prometheus discovers no `trakrf-preview` targets.

## Current-state facts (verified)

- **Grafana today:** grey-cloud. `grafana.gke.trakrf.id` resolves via the
  `*.gke.trakrf.id` **wildcard** A record in Cloud DNS (`terraform/gcp/dns.tf`
  `gke_id_wildcard`) → Traefik LB. TLS = LE cert from
  `helm/monitoring/manifests-gke/grafana-id-certificate.yaml` (Cloud DNS solver),
  referenced by `grafana-id-ingressroute.yaml` (`secretName: grafana-gke-trakrf-id-tls`).
  There is **no host-specific** `grafana.gke.trakrf.id` DNS record — nothing to
  delete in Terraform; the wildcard stays (serves other `.gke.id` hosts).
- **Orange pattern (`app.trakrf.id`):** CF record `proxied=true` → CF edge owns
  TLS (Universal SSL for the single-label host, **no ACM needed**) + WAF + DDoS;
  CF→origin leg is SSL "strict" and the origin presents the CF Origin CA cert
  `trakrf-id-origin-tls`. **No Let's Encrypt** on the orange leg (LE renewal would
  fail behind an origin lock and there's no CF DNS-01 token). The origin secret is
  created by `just origin-cert-secret` in `trakrf-system` and **reflected** by
  emberstack/reflector — today only into `trakrf-preview`,`trakrf-prod`.
- **Monitoring apply path:** `monitoring` is **Helm-bootstrapped, not Argo-synced**
  (`just monitoring-bootstrap gke`): helm upgrade with `values.yaml` +
  `values-gke.yaml`, then `kubectl apply --server-side` of `manifests/` and
  `manifests-gke/`. The recipe does **not** prune, so retiring a manifest requires
  an explicit `kubectl delete`.
- **Preview scrape leak source:** `trakrf-backend`/`trakrf-ingester` Apps install
  into `trakrf-<env>` (confirmed `trakrf-preview` / `trakrf-prod`); each emits a
  ServiceMonitor in its own namespace.

## Design

### Part 1 — Grafana rename (orange)

Mirror the `app.trakrf.id` orange pattern; Grafana is internal/single-user.

1. **DNS** — `terraform/cloudflare/main.tf`: add `cloudflare_record.grafana`
   (`name = "grafana"`, `type = A`, `content = var.gke_traefik_lb_ip`,
   `proxied = true`) in the `trakrf.id` zone.
2. **Edge TLS** — none to provision: Universal SSL already covers `*.trakrf.id`
   (single label). No ACM advanced cert (unlike two-label `*.preview.trakrf.id`).
3. **Origin TLS** — reuse `trakrf-id-origin-tls`. Extend the reflector namespace
   annotations in the `just origin-cert-secret` recipe to add `monitoring`, so the
   secret lands in the `monitoring` ns where the Grafana IngressRoute can reference
   it.
4. **IngressRoute** — `helm/monitoring/manifests-gke/grafana-id-ingressroute.yaml`:
   `Host(\`grafana.trakrf.id\`)`, `tls.secretName: trakrf-id-origin-tls`, keep the
   `default-chain` middleware (traefik ns). Refresh the comment.
5. **Retire LE cert** — delete `grafana-id-certificate.yaml`; the orange leg uses
   the Origin CA cert, so the per-host LE Certificate is no longer needed.
6. **Grafana root URL** — `helm/monitoring/values-gke.yaml`: set
   `grafana.ini.server.domain` + `root_url` to `grafana.trakrf.id` (stale root_url
   causes login redirect loops).
7. **Docs** — update the README "Access" line to `grafana.trakrf.id`.

**No origin IP-lock (cloudflare-allow) in this change.** Grafana is grey/unlocked
today; going orange already adds CF WAF/DDoS and is strictly better. Adding the
`cloudflare-allow` middleware needs it reachable from `monitoring` plus a lockstep
apply order. Tracked as a deferred hardening follow-up, out of this ticket's scope.

### Part 2 — Prometheus namespace scoping

In `helm/monitoring/values-gke.yaml` (GKE-only: only GKE co-locates preview+prod),
set the target-discovery namespace selectors on the Prometheus CR to exclude
`trakrf-preview`:

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorNamespaceSelector: &notPreview
      matchExpressions:
        - { key: kubernetes.io/metadata.name, operator: NotIn, values: [trakrf-preview] }
    podMonitorNamespaceSelector: *notPreview
    probeNamespaceSelector: *notPreview
    scrapeConfigNamespaceSelector: *notPreview
```

- Excludes monitor **objects** living in `trakrf-preview` (the preview backend +
  ingester ServiceMonitors). Prod app SMs (`trakrf-prod`) and all infra monitors
  (`monitoring`, `cnpg-system`, `traefik`, …) are untouched.
- `kubernetes.io/metadata.name` is auto-set by Kubernetes on every namespace
  (GA), so the `NotIn` expression is reliable and needs no namespace labeling.
- Exclude-list (NotIn preview) over allow-list (only prod): robust against future
  infra namespaces silently dropping out of monitoring.
- `ruleNamespaceSelector` left untouched — preview PrometheusRules produce alerts,
  not scrape targets, and are out of scope.

## Alternatives considered

- **Grey-cloud grafana.trakrf.id + LE via HTTP-01.** Rejected: ticket framing
  ("Universal wildcard covers it") implies orange/edge TLS; and HTTP-01 while
  orange+strict deadlocks (origin needs the cert before CF will complete the
  origin handshake to serve the challenge). The Origin CA cert sidesteps this.
- **Allow-list of prod namespaces** for Prometheus. Rejected as brittle (see above).
- **Renaming the IngressRoute resource / manifest file** to drop `-id`. Rejected:
  Argo doesn't sync monitoring (kubectl does), and renaming forces a delete+recreate
  blip for cosmetic gain. Keep the resource name `grafana-id`; only content changes.

## Manual apply steps (post-merge, operator-run; documented in PR)

These are not auto-applied (monitoring is not Argo-synced; the origin secret is a
`just` recipe):

1. `just origin-cert-secret` — re-materialize + re-annotate so reflector mirrors
   `trakrf-id-origin-tls` into `monitoring`.
2. `just cloudflare` — create the `grafana.trakrf.id` A record (proxied).
3. `just monitoring-bootstrap gke` — apply new Grafana root_url + IngressRoute +
   Prometheus namespace selectors.
4. `kubectl delete certificate grafana-gke-trakrf-id -n monitoring` — retire the
   old LE cert (recipe does not prune).

## Verification

- `curl -sSI https://grafana.trakrf.id` → 200/302 with a valid (CF Universal) cert;
  browser login succeeds with no redirect loop.
- `grafana.gke.trakrf.id` no longer routes to Grafana (404/no matching route).
- Prometheus targets/service-discovery page shows **no** `namespace="trakrf-preview"`
  targets; prod (`trakrf-prod`) + infra targets still present.

## Out of scope

- `cloudflare-allow` origin lock for Grafana (deferred hardening).
- The stale `namespaceSelector: ["trakrf"]` on the `cnpg-cluster-trakrf-db`
  PodMonitor (pre-TRA-849 ns name) — separate latent issue.
