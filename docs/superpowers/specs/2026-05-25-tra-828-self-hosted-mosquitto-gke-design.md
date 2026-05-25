# TRA-828 — Self-hosted Mosquitto broker on GKE (off EMQX Cloud)

**Status:** Design
**Date:** 2026-05-25
**Related:** TRA-823 (multi-env DB tenancy, per-env fan-out pattern this ticket extends), TRA-461 (GKE cert-manager Cloud DNS solver), TRA-368 (Cloudflare DNS-01 token pattern — available but unused), TRA-544 (node pool split), TRA-825 (GKE preview cutover), TRA-827 (GL-S10 TLS diagnostic), TRA-339 (canceled embedded mochi-mqtt), TRA-826 (canceled self-host EMQX spike)

## Context

EMQX Cloud Serverless is multi-tenant and SNI-routed. The GL-S10 BLE gateway firmware (minimal mbedTLS build) sends no SNI and is TLS 1.2 only, so it can never connect to EMQX Serverless. The CS463 fleet still reaches EMQX, but the broker remains the only customer-facing service routed through a third-party tenant — a residual integration risk now that GKE multi-env tenancy (TRA-823) has just shipped and the rest of the data plane is fully self-hosted.

A single-tenant self-hosted broker has no SNI dependency; Mosquitto, self-hosted EMQX, and embedded mochi-mqtt would all connect from the GL-S10. Mosquitto is the pragmatic pick: smaller operational surface than EMQX, no clustering need at current scale, and a stable upstream image (`eclipse-mosquitto`).

This ticket folds the broker into the in-flight GKE migration push alongside TRA-823's per-env tenancy. Home-lab scale, no customer dependencies, single CC-dispatchable build.

## Decision

Standalone Mosquitto, co-located with Redpanda Connect as a **sidecar pod (one pod, two containers per env)** in the existing `helm/trakrf-ingester` chart. Fanned out per-env to match TRA-823: one ingester+broker pod in `trakrf-preview`, one in `trakrf-prod`. Each env gets its own LoadBalancer Service, static GCP IP, host-specific public ACME cert, and DNS name.

Sidecar over separate pods because Redpanda Connect is low-churn and hot-reloadable, and Kubernetes restarts containers individually, so an ingester crash or redeploy doesn't bounce the broker. Split them only if a second first-class consumer appears (backend subscribing for live mustering presence) or the broker needs clustering — at which point it's a one-line change of the ingester's connection target from `localhost` to the broker Service DNS.

Per-env brokers (rather than one shared broker) because it aligns end-state with TRA-823's tenancy model and keeps the failure blast radius scoped to a single env. The per-env DNS naming follows the existing `<role>.<env>.[scope.]trakrf.id` convention: `mqtt.preview.gke.trakrf.id`, `mqtt.prod.gke.trakrf.id`.

Foreclosed alternatives:
- Embedded mochi-mqtt broker in the Go backend — mochi doesn't cluster, incompatible with multi-replica backend (canceled TRA-339).
- Self-hosted EMQX — single-node EMQX is all the operational weight with none of the HA payoff (canceled TRA-826).

## Out of scope

- Wildcard `*.gke.trakrf.id` cert — host-specific only, per the GL-S10 mbedTLS caveat (inconsistent wildcard SAN matching in minimal-firmware TLS clients).
- Cloudflare DNS-01 token solver — TRA-368 pattern available; not needed here.
- HA / multi-replica broker.
- Backups / WAL on the broker (no persistence anyway).
- PVC / persistence — current device traffic is QoS 0, persistence is inert. Add back when QoS 1+ and a real durability driver show up.
- Per-env broker user/password split. Single user/password mirrored across both envs for now; per-env split deferred until a real driver exists.
- Grafana dashboard for broker metrics. Metrics will be live in Prometheus immediately via the `mosquitto-exporter` sidecar; dashboard follows in a separate ticket.
- Web hosts migration to `.id` (`app.gke.trakrf.app`, `docs.*` stay on `.app` for now). The `gke.trakrf.app` zone and its wildcard cert are left in place; retirement is a follow-up.
- EMQX Cloud decommission. Worth doing eventually as housekeeping (the dormant deployment is still internet-reachable with creds that have appeared in logs), but $0/mo idle, no urgency, no soak gate. Follow-up ticket.
- Pre-cutover verification of the CS463 broker→DB write path beyond a quick `tag_scans` query. If recent rows are absent, this ticket also doubles as a repair; flag in the PR description, don't block.
- Explicit broker pinning to on-demand pool. GKE default pool is on-demand today; revisit when TRA-544's spot pool actually lands.

## DNS + cert architecture

**Delegate `gke.trakrf.id` as a parallel subzone from Cloudflare to Google Cloud DNS, alongside the existing `gke.trakrf.app` zone (which remains untouched).**

The fresh `gke.trakrf.id` label orphans nothing. The existing GKE cert-manager Cloud DNS DNS-01 solver (Workload Identity, from TRA-461) extends to the new zone with a one-line IAM binding addition and a second solver entry in the ClusterIssuer. The broker is the only host in this ticket that needs a GKE-issued public ACME cert. Browser-facing services (`app.*`, `docs.*`) sit behind Cloudflare proxy and use CF edge certs + CF Origin Certs on the GKE origin — they never need a GKE-issued public cert. CF can't proxy MQTT (Spectrum-tier enterprise only), and the GL-S10 validates the broker cert directly against its fixed trust store (ISRG Root X1), so a CF Origin Cert won't work for it.

The GL-S10 stock trust store includes ISRG Root X1, so a public ACME (Let's Encrypt) cert validates out of the box with zero device-side cert push.

## End-state architecture

```
trakrf-preview ns                          trakrf-prod ns
┌──────────────────────────────────┐       ┌──────────────────────────────────┐
│ Deployment trakrf-ingester (1 pod)│      │ Deployment trakrf-ingester (1 pod)│
│ ┌────────────────────────────┐   │       │ ┌────────────────────────────┐   │
│ │ container: ingester (RPC)  │   │       │ │ container: ingester (RPC)  │   │
│ │   MQTT_URL=mqtt://lo:1883  │   │       │ │   MQTT_URL=mqtt://lo:1883  │   │
│ │   → trakrf-db-rw.…-system  │   │       │ │   → trakrf-db-rw.…-system  │   │
│ ├────────────────────────────┤   │       │ ├────────────────────────────┤   │
│ │ container: mosquitto       │   │       │ │ container: mosquitto       │   │
│ │   :1883 plain (loopback)   │   │       │ │   :1883 plain (loopback)   │   │
│ │   :8883 TLS (LB-only)      │   │       │ │   :8883 TLS (LB-only)      │   │
│ ├────────────────────────────┤   │       │ ├────────────────────────────┤   │
│ │ container: mosquitto-      │   │       │ │ container: mosquitto-      │   │
│ │   exporter (sapcc)         │   │       │ │   exporter (sapcc)         │   │
│ │   :9234 /metrics           │   │       │ │   :9234 /metrics           │   │
│ │   subscribes lo:1883 $SYS/#│   │       │ │   subscribes lo:1883 $SYS/#│   │
│ └────────────────────────────┘   │       │ └────────────────────────────┘   │
├──────────────────────────────────┤       ├──────────────────────────────────┤
│ Service trakrf-mqtt              │       │ Service trakrf-mqtt              │
│   type: LoadBalancer, TCP/8883   │       │   type: LoadBalancer, TCP/8883   │
│   loadBalancerIP = static IP A   │       │   loadBalancerIP = static IP B   │
│ Service trakrf-ingester (metrics │       │ Service trakrf-ingester (metrics │
│   headless: 4195 + 9234)         │       │   headless: 4195 + 9234)         │
│ Certificate mqtt.preview.gke.…   │       │ Certificate mqtt.prod.gke.…      │
└──────────────────────────────────┘       └──────────────────────────────────┘
        ↑                                            ↑
mqtt.preview.gke.trakrf.id (Cloud DNS)     mqtt.prod.gke.trakrf.id (Cloud DNS)
```

Key properties:
- One pod per env, three containers (ingester + broker + exporter). Containers restart independently.
- Broker plain `:1883` listener bound to `127.0.0.1` only — never reachable from the cluster network. Ingester and exporter reach it as loopback. Authenticated (no anonymous loopback access).
- Broker TLS `:8883` listener bound to all interfaces; only reachable via the per-env LoadBalancer Service. TLS 1.2+ enabled.
- Mosquitto terminates TLS. No L7 ingress, no Traefik, no SNI in front. Avoids the EMQX Serverless failure mode.
- Per-env distinct `mqtt.clientId` already follows the existing GKE overlay pattern (`feedback_mqtt_clientid_per_cluster`).

## Component changes

### Terraform (`terraform/gcp/`)

`dns.tf` — additions:
- New `google_dns_managed_zone "gke_trakrf_id"` (resource name `gke-trakrf-id`, dns_name `gke.trakrf.id.`, `prevent_destroy = true` matching `gke_trakrf_app`).
- `google_dns_record_set` A records for `mqtt.preview.gke.trakrf.id.` and `mqtt.prod.gke.trakrf.id.` pointing at the new static IPs below.
- No apex/wildcard A records on `.id` (only broker hosts on `.id` for now).

`mqtt.tf` (new) — two `google_compute_address` resources, regional `EXTERNAL`, one per env (`mqtt-preview`, `mqtt-prod`).

`cert_manager.tf` — addition: second `google_dns_managed_zone_iam_member` granting the existing `cert_manager` SA `roles/dns.admin` on the `gke-trakrf-id` zone (binding lives on the zone).

`outputs.tf` — export `dns_nameservers_id` (NS for new zone), `cloud_dns_zone_name_id`, `mqtt_preview_ip`, `mqtt_prod_ip`.

### Terraform (`terraform/cloudflare/`)

`gcp-delegation.tf` — addition: second `cloudflare_record` block delegating `gke.trakrf.id` NS records to the new GCP zone's nameservers. Delegation lives on the `trakrf.id` CF zone (parallel to the existing `gke.trakrf.app` delegation on the `trakrf.app` zone).

### Helm (`helm/cert-manager-config/`)

`templates/clusterissuer.yaml` — when `solver: cloudDNS`, render a solver entry per item in a new `cloudDNS.zones` list (each entry has `hostedZoneName` + `dnsZoneName`). Each entry maps to one `solvers[].dns01.cloudDNS` block with a matching `selector.dnsZones`. Removes the singular `cloudDNS.hostedZoneName` / `cloudDNS.dnsZoneName` fields.

`values-gke.yaml` — replace the singular cloudDNS block with a list of two entries: one for `gke.trakrf.app` (existing), one for `gke.trakrf.id` (new). `project` and `cloudDNS.zones[*].hostedZoneName` stay placeholder-injected by `scripts/apply-root-app.sh`. The wildcard `Certificate` block for `gke.trakrf.app` stays as-is; no `.id` wildcard.

### Helm (`helm/trakrf-ingester/`)

`values.yaml` — additions:
```yaml
broker:
  enabled: true
  image:
    repository: eclipse-mosquitto
    tag: "2.0.21"           # pin exact in plan
  hostname: ""              # set per-env via inlineValues
  loadBalancerIP: ""        # set per-env via inlineValues
  authSecret: trakrf-mosquitto-auth
  certSecret: trakrf-mqtt-tls
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { cpu: 250m, memory: 256Mi }
  exporter:
    enabled: true
    image:
      repository: sapcc/mosquitto-exporter
      tag: "0.8.0"          # pin exact in plan
    port: 9234
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits:   { cpu: 50m, memory: 64Mi }

mqtt:
  user: trakrf-ingester     # non-secret; password from broker.authSecret
  host: localhost           # ingester reaches broker via loopback
  port: 1883
  # MQTT_URL composed in-template via $(VAR) env interpolation; no MQTT_URL Secret.
```

`templates/deployment.yaml` — modifications:
- Ingester container: drop the `MQTT_URL` env entry sourced from `trakrf-mqtt-credentials`. Replace with `MQTT_USER` + `MQTT_PASSWORD` env entries pulled from `broker.authSecret`, then compose `MQTT_URL` via `$(VAR)` env interpolation: `mqtt://$(MQTT_USER):$(MQTT_PASSWORD)@{{ .Values.mqtt.host }}:{{ .Values.mqtt.port }}`. (Pattern from `feedback_k8s_dsn_composition`.)
- Add `mosquitto` container (gated on `.Values.broker.enabled`): `eclipse-mosquitto` image, no args, mounts `mosquitto-config` (ConfigMap, ro), `mosquitto-tls` (cert Secret, ro), `mosquitto-auth` (auth Secret, ro), `mosquitto-data` (emptyDir, rw). Container `securityContext` with `runAsUser: 1883`, `runAsGroup: 1883`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`. TCP readiness/liveness probe on `8883`. Port `mqtts: 8883`.
- Add `mosquitto-exporter` container (gated on `.Values.broker.enabled && .Values.broker.exporter.enabled`): subscribes to `tcp://localhost:1883`, env from `broker.authSecret` (`username` + `password` literal keys). Exposes `:9234` named `mqtt-metrics`. Same securityContext template as ingester. HTTP readiness probe on `/metrics`.
- Pod annotation `reloader.stakater.com/auto: "true"` on the Deployment template — covers both `broker.certSecret` and `broker.authSecret`. Stakater Reloader is not yet deployed; it gets a new Application at sync wave `-1` (see `argocd/root/templates/reloader.yaml` below). Reflector (already at wave `-1`) is a different operator and stays.
- Add volumes: `mosquitto-config` (ConfigMap `trakrf-ingester-mosquitto`), `mosquitto-tls` (Secret `broker.certSecret`), `mosquitto-auth` (Secret `broker.authSecret`), `mosquitto-data` (emptyDir).

`templates/mosquitto-configmap.yaml` (new) — `mosquitto.conf`:
```
per_listener_settings true

listener 1883 127.0.0.1
allow_anonymous false
password_file /mosquitto/auth/passwd

listener 8883 0.0.0.0
protocol mqtt
certfile /mosquitto/tls/tls.crt
keyfile  /mosquitto/tls/tls.key
tls_version tlsv1.2
allow_anonymous false
password_file /mosquitto/auth/passwd

persistence false
persistence_location /mosquitto/data/
log_dest stdout
```

`templates/mqtt-service.yaml` (new) — gated on `.Values.broker.enabled`:
- `type: LoadBalancer`, `protocol: TCP`, port `8883` → `mqtts`.
- `loadBalancerIP: {{ .Values.broker.loadBalancerIP }}`.
- `externalTrafficPolicy: Local` for clean source IPs in broker logs.
- GKE passthrough L4 — confirm exact annotation in plan (likely `cloud.google.com/l4-rbs: "enabled"` or none required; default L4 NetLB for `protocol: TCP` Services is passthrough).

`templates/certificate.yaml` (new) — `cert-manager.io/v1 Certificate`, gated on `.Values.broker.enabled`:
- `secretName: {{ .Values.broker.certSecret }}`, `issuerRef` → existing `letsencrypt-prod` ClusterIssuer.
- `commonName` + single-entry `dnsNames` from `.Values.broker.hostname`.
- ECDSA P-256, `rotationPolicy: Always` (mirrors `helm/cert-manager-config` Certificate).

`templates/service.yaml` — extend the existing headless metrics Service to expose two ports:
```yaml
ports:
  - name: metrics
    port: 4195
    targetPort: metrics
  - name: mqtt-metrics
    port: 9234
    targetPort: mqtt-metrics
```

`templates/servicemonitor.yaml` — extend `endpoints` to a two-entry list (`metrics` + `mqtt-metrics`), same scrape interval/timeout as today.

`values-gke.yaml` — no changes (broker container pinning to on-demand pool deferred per Out of scope).

### ArgoCD root (`argocd/root/`)

`templates/trakrf-ingester.yaml` — extend per-env `$values` to include `broker.hostname` and `broker.loadBalancerIP` pulled from `$.Values.mqttPreviewIp` / `$.Values.mqttProdIp` and the templated per-env hostname:
```
broker:
  hostname: mqtt.{env}.gke.trakrf.id
  loadBalancerIP: {ip}
```

`templates/reloader.yaml` (new) — Stakater Reloader Application at sync wave `-1`, mirroring the reflector pattern.

`values.yaml` — add placeholders: `mqttPreviewIp: ""`, `mqttProdIp: ""`.

`templates/cert-manager-config.yaml` — extend inlineValues to pass the new cloudDNS zones list (both `.app` and `.id` entries) instead of singular fields.

### Scripts (`scripts/apply-root-app.sh`)

Extend the GKE branch to read two new tofu outputs (`mqtt_preview_ip`, `mqtt_prod_ip`) and the new zone outputs (`cloud_dns_zone_name_id`), and inject them into the root Application's `helm.values`. The cert-manager-config zones list is built from both `cloud_dns_zone_name` (existing `.app`) and `cloud_dns_zone_name_id` (new `.id`).

### Secrets (`justfile`)

`mosquitto-secrets` recipe (new):
1. Require `MOSQUITTO_USER` and `MOSQUITTO_PASSWORD` in `.env.local`. Reject if either is unset.
2. Run `mosquitto_passwd -b -c /tmp/passwd "$MOSQUITTO_USER" "$MOSQUITTO_PASSWORD"` inside a throwaway `eclipse-mosquitto` container (host binary not assumed).
3. `kubectl create secret generic trakrf-mosquitto-auth -n trakrf-system --from-file=passwd=/tmp/passwd --from-literal=username="$MOSQUITTO_USER" --from-literal=password="$MOSQUITTO_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -`.
4. Annotate the Secret for reflector to mirror into `trakrf-preview` + `trakrf-prod` (same annotation set TRA-823's `db-secrets` recipe uses).
5. Idempotent — re-running rotates if env vars changed; Stakater Reloader bounces both env pods.

The `passwd` file key feeds Mosquitto (`password_file`). The `username` / `password` literal keys feed the ingester via `$(VAR)` env interpolation and the exporter via `env`.

`ingester-secrets` recipe (retire): `trakrf-mqtt-credentials` Secret no longer used. Recipe deleted; recipe README/help updated. Stale Secrets in `trakrf-preview` + `trakrf-prod` deleted as a one-shot post-cutover step (not via the recipe).

`.env.local.sample` — add `MOSQUITTO_USER=trakrf-ingester` and `MOSQUITTO_PASSWORD=` (placeholder; generated with `openssl rand -hex 32` per `feedback_db_password_alphabet`).

## Apply ordering

This is load-bearing. The first DNS-01 challenge fails if the zone isn't publicly resolvable when cert-manager tries.

1. `tofu -chdir=terraform/gcp apply` — creates zone, static IPs, IAM binding.
2. `tofu -chdir=terraform/cloudflare apply` — delegates `gke.trakrf.id` NS to Cloud DNS.
3. `dig +trace mqtt.preview.gke.trakrf.id` — confirm public NS resolution works (NXDOMAIN until the A record is the expected resolution path; the test is that the NS chain reaches Cloud DNS).
4. `scripts/apply-root-app.sh gke` — re-pulls outputs into root chart inlineValues (cert-manager-config zone list, ingester broker hostname/IP).
5. `just mosquitto-secrets` — creates auth Secret in `trakrf-system`; reflector mirrors to env namespaces. Verify with `kubectl get secret -n trakrf-preview trakrf-mosquitto-auth`.
6. ArgoCD reconciles: ClusterIssuer updates → per-env `Certificate` resources apply → DNS-01 succeeds (Cloud DNS via Workload Identity) → `trakrf-mqtt-tls` Secrets land → Deployments roll with mosquitto + exporter sidecars → LB Services provision and bind to static IPs.
7. Smoke from a host with `mosquitto_pub`:
   ```
   mosquitto_pub -h mqtt.preview.gke.trakrf.id -p 8883 --capath /etc/ssl/certs \
     -u "$MOSQUITTO_USER" -P "$MOSQUITTO_PASSWORD" \
     -t trakrf.id/smoke/reads -m '{"ping":1}'
   ```
   Confirm row in `trakrf_preview.trakrf.tag_scans`. Repeat for prod.

## Device cutover

Pre-cutover check (per spec's own caveat — the CS463 → DB write path may have been silently dark):
```
kubectl exec -n trakrf-system trakrf-db-1 -- psql -U postgres -d trakrf_preview \
  -c "SELECT message_topic, created_at FROM trakrf.tag_scans
      WHERE message_topic LIKE '%cs463-21%'
      ORDER BY created_at DESC LIMIT 10;"
```
Empty or stale rows → this ticket also doubles as a repair. Flag in the PR description; don't block.

Sequence:
1. Repoint devices to **preview broker first** (home-lab 2× CS463 + 1× GL-S10). Confirm rows land in `trakrf_preview.trakrf.tag_scans`. Soak ~24h.
2. Once preview is clean, repoint a subset (or all, given home-lab scale) to prod broker. Confirm rows in `trakrf_prod.trakrf.tag_scans`.
3. EMQX Cloud teardown is housekeeping — separate follow-up ticket.

## Rollback

- **Devices:** revert MQTT target to the old EMQX hostname/creds (still live, $0/mo idle).
- **Cluster:** revert the PR commit; ArgoCD reconciles, Certificates GC, reflector mirror cleans up.
- **Tofu:** prefer to leave the new zone, IPs, and IAM in place even on a code revert (additive, no cost impact). Tear them down only if the rollback is permanent.

## Constraints (carry into the build)

- L4 LoadBalancer Service on 8883, no L7 ingress, nothing doing SNI-based routing in front of the broker.
- TLS 1.2+ on the broker listener. GL-S10 is 1.2-only; a 1.3-only listener fails it.
- Host-specific cert per env, not wildcard.
- Stateless broker (no PVC). `mosquitto-data` is emptyDir solely to satisfy `persistence_location` even when `persistence false`.
- cert-manager + Stakater Reloader on the cert Secret. Renewal transparent to devices.
- Sequence: delegate subzone → confirm public NS resolution → apply Certificate. Skipping the resolution check makes the first issuance fail.

## File inventory

New:
- `terraform/gcp/mqtt.tf`
- `helm/trakrf-ingester/templates/mosquitto-configmap.yaml`
- `helm/trakrf-ingester/templates/mqtt-service.yaml`
- `helm/trakrf-ingester/templates/certificate.yaml`
- `argocd/root/templates/reloader.yaml`
- `docs/superpowers/specs/2026-05-25-tra-828-self-hosted-mosquitto-gke-design.md` (this file)

Modified:
- `terraform/gcp/dns.tf`
- `terraform/gcp/cert_manager.tf`
- `terraform/gcp/outputs.tf`
- `terraform/cloudflare/gcp-delegation.tf`
- `helm/cert-manager-config/templates/clusterissuer.yaml`
- `helm/cert-manager-config/values-gke.yaml`
- `helm/trakrf-ingester/values.yaml`
- `helm/trakrf-ingester/templates/deployment.yaml`
- `helm/trakrf-ingester/templates/service.yaml`
- `helm/trakrf-ingester/templates/servicemonitor.yaml`
- `argocd/root/templates/trakrf-ingester.yaml`
- `argocd/root/templates/cert-manager-config.yaml`
- `argocd/root/values.yaml`
- `scripts/apply-root-app.sh`
- `justfile`
- `.env.local.sample`

Retired (deleted from `justfile`; Secret cleaned post-cutover):
- `just ingester-secrets` recipe
- `trakrf-mqtt-credentials` Secret in `trakrf-preview` + `trakrf-prod`
