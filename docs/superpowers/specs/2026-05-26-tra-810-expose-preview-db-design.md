# TRA-810 — Expose preview CNPG primary for external psql (FDW pull-migration dev)

**Status:** Design
**Date:** 2026-05-26
**Related:** TRA-810 (M3 cutover — logical migration via FDW pull), TRA-828 (MQTT broker static-IP + DNS pattern this mirrors), TRA-829 (`gke.trakrf.id` zone foundation this consumes), TRA-461 (Traefik LB pattern this also mirrors)

## Context

TRA-810 designates the M3 data cutover from TimescaleDB Cloud to GKE-CNPG as **logical migration** (schema-then-data via `postgres_fdw` pull) rather than physical `pg_dump/restore`. Cloud-side baggage (`timescaledb_toolkit`, `tsdbadmin`-family roles in `_timescaledb_catalog.bgw_job`) makes a restore awkward, and the data volume is small enough (≪ 1k rows total, a few thousand `tag_scan` rows on preview at most) that performance considerations don't drive the design.

Developing the FDW migration needs a workflow where a separate Claude Code instance on the platform side iterates on `CREATE EXTENSION postgres_fdw / CREATE SERVER / CREATE USER MAPPING / IMPORT FOREIGN SCHEMA / INSERT INTO local SELECT FROM foreign` against the preview database, validates results, and refines. Today that requires a `kubectl port-forward` running per session — clunky, sequential, breaks if the agent restarts. A persistent external endpoint is cleaner.

The FDW pull direction (CNPG-preview → TSDB Cloud) is **outbound** and already works — GKE pods have egress to the public internet, TSDB Cloud is publicly reachable on the standard Postgres TLS port, and no NetworkPolicy gates the trakrf-system ns. This ticket only needs to handle the **inbound** psql-client direction.

## Decision

Mirror the MQTT broker pattern (TRA-828): one Tofu-provisioned static external IP, one Cloud DNS A record under `gke.trakrf.id` (`db.preview.gke.trakrf.id`), one helm-rendered `Service type=LoadBalancer` selecting CNPG's primary pod with the IP pinned via `spec.loadBalancerIP`. Source allowlist via `loadBalancerSourceRanges` reuses the breakglass dyn-DNS CIDR (`opsumo-austin.asuscomm.com → /32`) that the apply script already resolves for the preview ingress IPAllowList. `externalTrafficPolicy: Local` preserves the client source IP so the LB-level allowlist actually means something.

Preview-only by structure. The chart's `externalPreview.enabled` defaults to `false`; the root chart sets it `true` and wires the IP/sourceRanges only when `cluster=gke`. The Service template guards on both `enabled=true` AND a non-empty `loadBalancerIP`, so prod and non-GKE overlays can never accidentally surface a public Postgres endpoint.

TLS is CNPG's operator-managed server certificate (signed by the `trakrf-db-ca` Secret in the chart's namespace). Clients connect with `sslmode=verify-ca sslrootcert=<ca>` after pulling the CA — fine for a developer-iteration use case where the human bootstraps once. Bumping to a cert-manager-issued cert for `db.preview.gke.trakrf.id` so plain `verify-full` works without an out-of-band CA copy is a small follow-up if the friction matters, but not blocking.

Role bootstrap stays minimal: `CREATE EXTENSION postgres_fdw` requires superuser, so the platform CC instance gets the CNPG-generated `trakrf-db-superuser` secret for preview only. A dedicated `trakrf-dev-preview` role with pre-granted `USAGE ON FOREIGN DATA WRAPPER postgres_fdw` is cleaner long-term but slower to bootstrap; preview is the right scope to trust with the broader keys and torch if needed.

## Out of scope

- Prod external endpoint — prod stays in-cluster-only by structure. Any future prod data plane exposure is a different ticket with different controls.
- cert-manager-issued Postgres server cert under `db.preview.gke.trakrf.id` — not blocking the dev use case; follow-up if `verify-full` ergonomics matter later.
- Dedicated `trakrf-dev-preview` role with FDW privileges pre-granted via the migrate runner — over-engineering for a preview-only sandbox during M3 dev.
- The actual FDW pull SQL — that's the platform-side ticket (TRA-810 itself; this is the infra-side enabler).
- `db.{env}.gke.trakrf.id` for envs beyond preview — preview is the only consumer today.

## Architecture

```
Tofu (terraform/gcp/db.tf)
  google_compute_address.db_preview         (static EXTERNAL regional IP, PREMIUM tier)
                          │
                          ▼
Tofu (terraform/gcp/dns.tf)
  google_dns_record_set.db_preview          (db.preview.gke.trakrf.id → static IP)
                          │
                          ▼
scripts/apply-root-app.sh (gke branch)
  reads tofu output db_preview_ip
  passes --set dbPreviewIp=$DB_PREVIEW_IP into the root chart
                          │
                          ▼
argocd/root/templates/trakrf-db.yaml (cluster=gke)
  inlineValues: externalPreview.{enabled, loadBalancerIP, sourceRanges}
  sourceRanges populated from the breakglass dyn-DNS CIDR
                          │
                          ▼
helm/trakrf-db/templates/external-service-preview.yaml
  apiVersion: v1, kind: Service, type: LoadBalancer
  loadBalancerIP: <db_preview_ip>
  loadBalancerSourceRanges: [<breakglass-cidr>]
  externalTrafficPolicy: Local
  selector:
    cnpg.io/cluster: trakrf-db
    cnpg.io/instanceRole: primary
                          │
                          ▼
GKE provisions an external L4 LB tied to the static IP, NEG'd to the
primary CNPG pod. Failover: when CNPG promotes a new primary, its label
flips and the LB target tracks automatically.
                          │
                          ▼
External psql client:
  psql "host=db.preview.gke.trakrf.id user=postgres dbname=trakrf_preview \
        sslmode=verify-ca sslrootcert=/tmp/trakrf-db-ca.crt"
```

## Verification (post-merge, on GKE)

Manual:

1. `just gcp` to apply the tofu changes (creates static IP + A record).
2. `scripts/apply-root-app.sh gke` to re-render the root chart and pick up the new Service.
3. `kubectl -n trakrf-system get svc trakrf-db-preview-external` — `EXTERNAL-IP` matches the tofu IP.
4. `dig +short db.preview.gke.trakrf.id` — returns the tofu IP.
5. `kubectl -n trakrf-system get secret trakrf-db-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/trakrf-db-ca.crt`
6. Pull the superuser password: `kubectl -n trakrf-system get secret trakrf-db-superuser -o jsonpath='{.data.password}' | base64 -d`
7. From a host on the breakglass CIDR: `PGPASSWORD=… psql "host=db.preview.gke.trakrf.id user=postgres dbname=trakrf_preview sslmode=verify-ca sslrootcert=/tmp/trakrf-db-ca.crt" -c '\dt'`
8. From a host NOT on the breakglass CIDR: same command should hang/timeout, confirming the source-range filter works.

## Risks + mitigations

- **Public Postgres surface.** Mitigated by `loadBalancerSourceRanges` plus `externalTrafficPolicy: Local` (so the source-IP check happens on the source-IP, not the kube-proxy-masqueraded one). If the breakglass dyn-DNS host moves, the apply script re-resolves on every run; until then the allowlist is stale. Acceptable for preview.
- **Failover lag.** The Service selector tracks `cnpg.io/instanceRole: primary` — CNPG repoints the label on failover, but during the gap there's no backend. Single-instance preview cluster makes this a non-issue today; if preview scales to multi-instance, expect a brief connection refused during promotion.
- **CNPG operator-managed CA isn't browser-trusted.** `verify-full` requires `sslrootcert` to be the CA Secret. Documented in the verification steps; if friction grows, cert-manager-issued is the upgrade path.
- **Superuser creds in a developer agent.** Scoped to preview, separate password from prod, easy to rotate via the CNPG Secret. If we ever expand the pattern to a non-preview env we revisit the role model.
- **DB destroyed during cluster rebuild.** The static IP has `prevent_destroy = true` so the LB IP and DNS record survive cluster rebuilds; the LB Service inside k8s gets recreated by helm/argo. Same shape as the MQTT and Traefik IPs.
