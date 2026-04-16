# Monitoring (kube-prometheus-stack)

Helm-bootstrapped observability stack: Prometheus, Grafana, Alertmanager,
node-exporter, kube-state-metrics. Deployed to the `monitoring` namespace.

Bootstrapped via Helm rather than ArgoCD because (a) ArgoCD itself is a
consumer of these metrics — circular bootstrap — and (b) the chart's CRDs
have historically been awkward under ArgoCD ownership. ArgoCD adoption is
tracked as an M2 follow-up.

## Bootstrap

```sh
just monitoring-bootstrap
```

Idempotent — safe to re-run. Pulls the chart at the version pinned in
`justfile` and applies overrides from `values.yaml`, then applies the
out-of-chart manifests in `manifests/` (CNPG ServiceMonitor + dashboards
ConfigMap).

## Access

Grafana is exposed publicly at <https://grafana.eks.trakrf.app> (TRA-386).
Prometheus and Alertmanager remain cluster-internal; use port-forward.

```sh
just grafana-password   # admin password (still the source of truth)
just grafana-ui         # port-forward to :3000 (local/debug)
just prometheus-ui      # port-forward to :9090
```

## Dashboards

JSONs in `dashboards/` are bundled into a sidecar-discoverable ConfigMap
during bootstrap. To add a dashboard, drop the JSON into `dashboards/` and
re-run `just monitoring-bootstrap`.

## ServiceMonitors

App charts own their own ServiceMonitors (e.g. `helm/trakrf-ingester/`).
The Prometheus operator is configured with `*SelectorNilUsesHelmValues:
false`, so any ServiceMonitor in any namespace is discovered without
release-specific labels.
