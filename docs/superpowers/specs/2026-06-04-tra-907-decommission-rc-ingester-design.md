# TRA-907 — Decommission Redpanda Connect ingester (broker stays standalone)

**Date:** 2026-06-04
**Ticket:** TRA-907 (blocked-by TRA-900 ✓ merged; follows TRA-920 ✓ live). Related: TRA-828 (self-hosted Mosquitto), TRA-831 (retire RC image), TRA-339 (canceled broker-embed).
**Branch:** `worktree-miks2u+tra-907-decommission-rc-ingester`

## Goal

Now that the in-backend Go subscriber (TRA-900) is live on preview (TRA-920) and is the sole writer of `asset_scans`, retire the redundant Redpanda Connect (RC) ingester. **The Mosquitto broker must survive** — readers and the backend subscriber connect to it at `mqtt.<env>.gke.trakrf.id:8883`.

## The structural problem

The broker is not a standalone release today — it's a **sidecar inside the `trakrf-ingester` chart** (TRA-828's "one pod = RC + broker + exporter"). The RC connect container is the *primary* container; `mosquitto` + `mosquitto-exporter`, the cert-manager `Certificate`, and the `LoadBalancer` Service are `broker.enabled` sidecars. So "remove RC, keep broker" requires restructuring, not just a flag.

**Decision (Mike, hard cut):** extract a standalone `trakrf-mosquitto` chart, delete the `trakrf-ingester` release entirely. A brief broker gap during cutover is acceptable (QoS 0, best-effort — dropped messages are fine).

## Design

### New chart `helm/trakrf-mosquitto/`

A dedicated broker chart. Values flattened (no more `broker.` nesting — the chart *is* the broker). Carries over verbatim-in-spirit from the ingester's broker half:

- `templates/deployment.yaml` — **only** `mosquitto` + `mosquitto-exporter` containers. `strategy: Recreate` (broker holds MQTT sessions; never overlap pods — was the ingester's setting). `reloader.stakater.com/auto: "true"` (bounce on cert/auth Secret rotation — Mosquitto doesn't reload certs on SIGHUP). Volumes: `mosquitto-config`, `mosquitto-tls` (cert Secret), `mosquitto-auth` (`passwd` key), `mosquitto-data` (emptyDir). ARM-tolerant via `values-gke.yaml`.
- `templates/mosquitto-configmap.yaml` — `mosquitto.conf` (per-listener auth; loopback 1883 for the exporter; public TLS 1.2 8883; persistence off). Unchanged.
- `templates/certificate.yaml` — host-specific cert (`commonName`/`dnsNames` = broker hostname), `secretName: trakrf-mqtt-tls`, `letsencrypt-prod`. **Same `secretName`** so the existing cert Secret carries over (cert-manager Secrets aren't ArgoCD-managed → not pruned on app swap → no re-issue gap).
- `templates/mqtt-service.yaml` — `LoadBalancer` on `:8883`, `loadBalancerIP: <static>`, `externalTrafficPolicy: Local`, `cloud.google.com/l4-rbs: "enabled"` (passthrough L4, no SNI — GL-S10 needs it). **Same static IP** the readers/backend already use.
- `templates/service.yaml` — headless metrics Service, now **only** the exporter's `:9234` port (RC's `:4195` endpoint is gone).
- `templates/servicemonitor.yaml` — single exporter endpoint.
- `templates/_helpers.tpl`, `Chart.yaml`, `values.yaml`, `values-gke.yaml`.

### Root app-of-apps

- **Add** `argocd/root/templates/trakrf-mosquitto.yaml` — one Application per env, **GKE-only** (`eq .Values.cluster "gke"` — the broker exists only on GKE; no disabled overlays for AKS/EKS). Injects per-env `hostname: mqtt.<env>.gke.trakrf.id` + `loadBalancerIP: <mqttIp>` via inlineValues (the existing Tofu-sourced `envs.<env>.mqttIp` flows in unchanged via `apply-root-app.sh`).
- **Delete** `argocd/root/templates/trakrf-ingester.yaml`.
- AppProject (`argocd/projects/trakrf.yaml`) needs **no change** — in-repo `sourceRepos` + `trakrf-preview`/`trakrf-prod` destinations already permitted.

### Delete the RC chart

Remove `helm/trakrf-ingester/` entirely (chart, templates, all overlays). This drops the RC connect container, its `connect.yaml` ConfigMap (the raw `INSERT INTO trakrf.tag_scans`), the RC `mqtt.*`/`database.*` values, and the RC `:4195` metrics.

### Backend hardening (folded in per TRA-920 follow-up)

`helm/trakrf-backend/templates/deployment.yaml`: add `strategy: Recreate` **gated on `.Values.mqtt.host`**. While MQTT ingestion is on (preview now; prod at cutover), a RollingUpdate surge would briefly run two subscribing pods → double-written `asset_scans` (distinct `received_at` → distinct `(timestamp,org,asset)` PKs that `ON CONFLICT` can't dedup). Recreate trades a brief deploy gap for single-subscriber correctness. MQTT-off envs keep zero-downtime RollingUpdate. `$share` shared-subscriptions is the durable fix (future).

### Housekeeping (stale `trakrf-ingester` references)

- Delete `helm/monitoring/dashboards/redpanda-connect.json` (RC dashboard — dead once RC is gone; dashboards are globbed into a Grafana ConfigMap by a `just` recipe, not ArgoCD-synced, so removal is safe and reconciles on next bootstrap).
- Comment/text updates: `helm/monitoring/README.md`, `helm/monitoring/values-gke.yaml`, `helm/README.md`, `argocd/root/values.yaml` header, `justfile` (`mosquitto-secrets` recipe comments), `docs/backups.md` + `docs/db-migration.md` runbooks (writer is now `trakrf-backend`; broker is `trakrf-mosquitto`).
- `terraform/gcp/mqtt.tf` + `outputs.tf`: the static-IP resource `description`/comments name "trakrf-ingester" → "trakrf-mosquitto". **In-place description change only — no IP recreation.** Reconciles on the next `tofu apply`; flagged in the PR.

## Cutover & continuity

- **Static IP preserved:** the LB IP is a Tofu-reserved address; the new `trakrf-mosquitto-mqtt` Service requests the same `loadBalancerIP`, so GCP re-attaches it. Two Services can't hold one reserved IP simultaneously → the old `trakrf-ingester` app/Service must be pruned **before** the new Service is created. With a hard cut this is acceptable; if ArgoCD races the same-IP claim, manually delete the old app first (`kubectl -n argocd delete app trakrf-ingester-{preview,prod}`) then sync.
- **Cert preserved:** same `secretName: trakrf-mqtt-tls`; cert-manager Secret survives the app swap (not ArgoCD-pruned), so no ACME re-issue gap.
- **Auth Secret unchanged:** `trakrf-mosquitto-auth` (`just mosquitto-secrets`, Reflector-mirrored) — both brokers and the backend keep using it.
- **Deploy steps:** merge PR → re-run `scripts/apply-root-app.sh gke` → ArgoCD prunes `trakrf-ingester-{preview,prod}`, creates `trakrf-mosquitto-{preview,prod}` → verify broker pods Running, `:8883` reachable on the same IP, readers reconnect, backend stays `subscribed`, `asset_scans` keep flowing.

## Verification (in-PR)

- `helm lint helm/trakrf-mosquitto` + `helm template` renders broker/exporter/cert/LB-service/configmap/servicemonitor; LB Service has the static IP and `:8883`; cert `secretName: trakrf-mqtt-tls`.
- Root chart `cluster=gke`: emits `trakrf-mosquitto-preview` + `trakrf-mosquitto-prod` Applications with per-env hostname + LB IP; **no** `trakrf-ingester-*` apps.
- Root chart `cluster=aks`: emits **no** `trakrf-mosquitto-*` apps (GKE-only).
- Backend: `strategy: Recreate` renders when `mqtt.host` set; absent otherwise.
- `grep -r trakrf-ingester` returns only historical spec/plan docs.

## Out of scope

- `$share` shared subscriptions / multi-replica (future; the durable fix for both the rollout overlap and steady-state scale-out).
- Broker-embed (mochi) — decided against (TRA-339).
- A replacement Grafana dashboard for Mosquitto (optional follow-up; exporter metrics still flow to Prometheus).
