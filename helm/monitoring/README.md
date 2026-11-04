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

Grafana is exposed publicly at <https://grafana.trakrf.id> on GKE prod
(TRA-894; orange-clouded via Cloudflare). The retired EKS host was
grafana.eks.trakrf.app.
Prometheus and Alertmanager remain cluster-internal; use port-forward.

```sh
just grafana-password   # admin password (still the source of truth)
just grafana-ui         # port-forward to :3000 (local/debug)
just prometheus-ui      # port-forward to :9090
```

## Alerting

Alertmanager posts to one Slack channel through an incoming webhook.
Routing lives in `values.yaml` under `alertmanager.config`:

| Alerts | Receiver | Behaviour |
|---|---|---|
| `Watchdog` | `null` | Fires constantly by design; never posted |
| `severity` `info` or `none` | `null` | Advisory only; still listed in the Alertmanager UI |
| `severity: critical` | `slack-critical` | `@channel` ping, red, repeats hourly |
| everything else (`warning`, unlabelled) | `slack-warning` | Normal post, repeats every 12h |

Both Slack receivers send a resolved message when the alert clears. The
message layout is `templateFiles` → `trakrf-slack.tmpl` in `values.yaml`.
`./scripts/test-alertmanager-config.sh` (run in CI) checks the config with
amtool and asserts the routing above.

### Setup

The webhook URL never goes in the values. It lives in the
`alertmanager-slack` Secret, mounted into the pod via
`alertmanager.alertmanagerSpec.secrets` and read through `api_url_file`.

1. In Slack, create an app with an incoming webhook for the alerts channel
   (<https://api.slack.com/apps> → Incoming Webhooks).
2. Put the URL in `.env.local` as `ALERTMANAGER_SLACK_WEBHOOK_URL`.
3. `just alertmanager-secrets`, then `just monitoring-bootstrap gke`.
   Bootstrap refuses to run while the Secret is missing, because the
   Alertmanager pod cannot start without it.

### Rotating the webhook

Regenerate the webhook in Slack, update `.env.local`, and run
`just alertmanager-secrets`. Alertmanager reads the file on every
notification, so no restart or bootstrap is needed; allow about a minute for
the kubelet to refresh the mounted Secret. Then revoke the old webhook.

### Fire-testing

Send a synthetic alert through the live routing (port-forward first):

```sh
kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093
amtool alert add --alertmanager.url=http://localhost:9093 \
  alertname=ManualTest severity=warning namespace=monitoring \
  --annotation=summary="Alertmanager test, please ignore"
```

## Dashboards

JSONs in `dashboards/` are bundled into a sidecar-discoverable ConfigMap
during bootstrap. To add a dashboard, drop the JSON into `dashboards/` and
re-run `just monitoring-bootstrap`.

## ServiceMonitors

App charts own their own ServiceMonitors (e.g. `helm/trakrf-backend/`, `helm/trakrf-mosquitto/`).
The Prometheus operator is configured with `*SelectorNilUsesHelmValues:
false`, so any ServiceMonitor in any namespace is discovered without
release-specific labels.
