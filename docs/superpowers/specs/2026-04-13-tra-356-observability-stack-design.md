# TRA-356: Observability Stack (kube-prometheus-stack)

**Status:** Design approved 2026-04-13
**Linear:** [TRA-356](https://linear.app/trakrf/issue/TRA-356)
**Parent:** TRA-351 (M1)

## Goal

Stand up Prometheus, Grafana, and Alertmanager on the EKS cluster so we can
see cluster + CNPG health and produce a screenshot/link for the M1 README.

## Non-goals

- ArgoCD adoption of the chart — tracked as a separate M2 follow-up ticket.
- TrakRF backend custom metrics + dashboard — backend has no `/metrics`
  endpoint today; tracked as a separate follow-up ticket.
- TrakRF-specific business metrics for the ingester (scan counts by site,
  etc.) — only generic Redpanda Connect metrics are in scope here.
- External alert routing (Slack, PagerDuty, email).
- Long-term metrics storage / Thanos.
- Public ingress for Grafana.

## Approach

Helm-bootstrap the upstream `prometheus-community/kube-prometheus-stack`
chart into a new `monitoring` namespace via a `just monitoring-bootstrap`
target, mirroring the existing `argocd-bootstrap` pattern. Deferring ArgoCD
adoption avoids the well-documented CRD ownership friction noted in
`memory/project_argocd_lessons.md`; ArgoCD itself is a consumer of these
metrics, so a Helm-managed bootstrap also dodges the circular dependency.

## Layout

```
helm/
  monitoring/
    values.yaml              # pinned chart version + overrides
    README.md                # bootstrap + access instructions
```

The chart itself is not vendored — `helm install` pulls it from the
`prometheus-community` repo with a pinned version.

## Configuration overrides (`helm/monitoring/values.yaml`)

- **Prometheus**
  - PVC: 20Gi, gp3 storage class
  - Retention: 15d
  - `serviceMonitorSelectorNilUsesHelmValues: false` so ServiceMonitors in
    other namespaces (e.g. `trakrf`) are picked up without label gymnastics
  - Same for `podMonitorSelector` / `ruleSelector`
- **Grafana**
  - Admin password from generated secret (chart default)
  - Default dashboards on (cluster, nodes, kubelet, etc.)
  - Sidecar dashboards enabled, label `grafana_dashboard=1`
  - Persistence: 5Gi gp3 (preserves saved dashboards across pod restarts)
- **Alertmanager**
  - Deployed, no receivers configured (alerts visible in UI only)
  - PVC: 2Gi
- **node-exporter / kube-state-metrics:** chart defaults

## ServiceMonitors / dashboards

**Convention:** each app chart owns its own `Service` + `ServiceMonitor`
(gated by a `serviceMonitor.enabled` value). The kube-prometheus-stack
selectors are configured with `*SelectorNilUsesHelmValues: false` so any
ServiceMonitor in any namespace is auto-discovered — no label gymnastics.

- **CNPG:** ship a `ServiceMonitor` (in `helm/monitoring/` as a side
  manifest, since CNPG isn't our chart) targeting CNPG's exported metrics
  endpoint in `trakrf` ns. CNPG also ships a `PodMonitor`; we'll prefer the
  operator's own service endpoint.
- **trakrf-ingester:** extend the existing chart:
  - Add `metrics: prometheus: {}` and `http: { address: 0.0.0.0:4195 }` to
    the rendered `connect.yaml` ConfigMap.
  - Expose container port `4195` (named `metrics`).
  - New `templates/service.yaml` (ClusterIP, port `4195` → `metrics`).
  - New `templates/servicemonitor.yaml` gated by `serviceMonitor.enabled`
    (default `true`), scrape path `/metrics`, interval `30s`.
- **Dashboards** (loaded via Grafana sidecar, label `grafana_dashboard=1`):
  - CNPG community dashboard (Grafana ID 20417).
  - Redpanda Connect / Benthos community dashboard (e.g. ID 20655 — confirm
    current ID during build; otherwise hand-roll a minimal one with
    `input_received`, `output_sent`, `output_error`, `processor_latency`).

## Justfile additions

```
# Install kube-prometheus-stack into monitoring namespace
monitoring-bootstrap:
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update prometheus-community
    helm upgrade --install kube-prometheus-stack \
      prometheus-community/kube-prometheus-stack \
      --version <pinned> \
      --namespace monitoring --create-namespace \
      -f helm/monitoring/values.yaml
    kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=180s

# Port-forward Grafana UI to :3000
grafana-ui:
    @echo "Grafana at http://<host-ip>:3000 (admin / <just grafana-password>)"
    kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 --address 0.0.0.0

# Fetch Grafana admin password
grafana-password:
    @kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Port-forward Prometheus UI to :9090
prometheus-ui:
    kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 --address 0.0.0.0
```

## Verification

1. `just monitoring-bootstrap` completes; all pods Ready in `monitoring` ns.
2. `just grafana-ui` → log in, default Kubernetes dashboards render with
   live data.
3. CNPG + Redpanda Connect dashboards loaded automatically; show live data
   for `trakrf-db` and `trakrf-ingester`.
4. Prometheus targets page: CNPG operator + cluster, trakrf-ingester,
   kube-state-metrics, node-exporter, kubelet — all `UP`.
5. Capture screenshots (cluster overview, CNPG, ingester) for M1 README.

## Follow-ups (separate Linear tickets)

- ArgoCD adoption of `kube-prometheus-stack` (M2).
- Add `/metrics` endpoint to TrakRF backend (`prometheus/client_golang`)
  + ServiceMonitor + custom dashboard.
- Alertmanager receiver wiring (Slack/email) once a destination is chosen.
- Ingress / Cloudflare Tunnel for Grafana (post-M1, demo polish).
