# TRA-493 — Enable Traefik Prometheus scrape + ServiceMonitor

**Date:** 2026-04-24
**Linear:** [TRA-493](https://linear.app/trakrf/issue/TRA-493/enable-traefik-prom-scrape-servicemonitor) (parent: TRA-492)
**Status:** design approved, ready for plan

## Problem

Traefik emits Prometheus metrics on its `metrics` entryPoint by default (port 9100), but nothing scrapes them today. We get no per-service HTTP histograms (`traefik_service_request_duration_seconds_bucket`) for anything behind the proxy. Adding scrape is the highest coverage/effort ratio signal we can add — it instruments every service ingress without touching app code.

## Goals

- Prometheus scrapes Traefik on every cluster where ArgoCD syncs this repo.
- kube-prometheus-stack discovers the Traefik ServiceMonitor without special label surgery.
- Verified on GKE demo.

## Non-goals (carried from ticket)

- No Grafana dashboard (separate task).
- No latency alerts (need baseline first).
- No scrape-interval tuning.

## Approach

**Chart-native.** The upstream Traefik v39 chart ships a first-class ServiceMonitor template and a dedicated metrics Service — both gated off by default. Turning them on is a 4-line addition to the inline helm values in `argocd/root/templates/traefik.yaml`. No new YAML in `helm/traefik-config/`, no new manifests in `helm/monitoring/`.

Rejected alternative: hand-roll a ServiceMonitor in `helm/traefik-config/templates/`. Downsides — two charts coordinated by port name, more YAML to maintain, a cross-release Service selector. Chart-native is strictly simpler.

## Change set

In `argocd/root/templates/traefik.yaml`, append to the shared inline `helm.values` block (outside the cluster-specific `if eq` guards):

```yaml
metrics:
  prometheus:
    service:
      enabled: true       # create dedicated ClusterIP metrics Service
    serviceMonitor:
      enabled: true       # create ServiceMonitor targeting that Service
```

No other file changes.

## Why this works with no label surgery

`helm/monitoring/values.yaml` already sets `serviceMonitorSelectorNilUsesHelmValues: false`, so kube-prometheus-stack discovers ServiceMonitors in any namespace regardless of labels. The chart creates the SM in the `traefik` namespace (where the Traefik release lives); Prometheus picks it up automatically.

## Data flow

1. Traefik pod exposes `/metrics` on its `metrics` entryPoint (port 9100) — already running, just not scraped.
2. Chart-native dedicated Service (`metrics.prometheus.service.enabled=true`) routes port 9100 → Traefik pods; ClusterIP only, not exposed on the LB.
3. Chart-native ServiceMonitor (`metrics.prometheus.serviceMonitor.enabled=true`) selects that Service.
4. kube-prometheus-stack Prometheus scrapes. Metrics appear with `service=~"trakrf-.+"` labels (the chart's `addServicesLabels` defaults to true).

## Rollout & verification

- Merge PR to main. ArgoCD auto-syncs on every cluster where the root app is installed (currently GKE + AKS). EKS was destroyed 2026-04-21 — no root app runs there, so nothing to sync.
- **Verify on GKE demo only** (per cloud portfolio strategy — AKS is on ice).
  From any pod in `trakrf` namespace:

  ```
  kubectl exec -n trakrf <pod> -- \
    wget -qO- 'http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query?query=traefik_service_requests_total'
  ```

  Expect: non-empty result set, `service=~"trakrf-.+"` labels present.

  Confirm target UP:

  ```
  kubectl exec -n trakrf <pod> -- \
    wget -qO- 'http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/targets?state=active' \
    | grep traefik
  ```

- AKS: change applied via ArgoCD but NOT verified. Parity via the overlay pattern + chart-native SM is sufficient.
- If GKE fails: revert the commit. The change is additive, no partial state to clean up.

## Risks

- **LB exposure creep:** `metrics.prometheus.service.enabled` creates a *separate* ClusterIP Service — metrics do NOT become reachable on the public LB. Verified from chart values.yaml.
- **CRD availability:** ServiceMonitor requires `monitoring.coreos.com/v1`. kube-prometheus-stack installs this ahead of Traefik via ArgoCD sync-wave ordering (already in place). Chart has `metrics.prometheus.disableAPICheck` escape hatch if needed.
- **Cluster-specific failure:** change is identical on GKE/AKS/EKS — no per-cluster branch in the values. No cluster-specific failure modes anticipated.

## References

- Traefik helm chart v39.0.8 values: `metrics.prometheus.service`, `metrics.prometheus.serviceMonitor`, `ports.metrics`.
- kube-prometheus-stack values: `helm/monitoring/values.yaml` — wide-open SM discovery already configured.
- Existing SM patterns: `helm/trakrf-backend/templates/servicemonitor.yaml`, `helm/trakrf-ingester/templates/servicemonitor.yaml` (not used here but informed the rejected alternative).
