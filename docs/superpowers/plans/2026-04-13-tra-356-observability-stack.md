# TRA-356 Observability Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap kube-prometheus-stack into a `monitoring` namespace and wire CNPG + trakrf-ingester metrics into Prometheus + Grafana.

**Architecture:** Helm-managed bootstrap (mirrors `argocd-bootstrap`) of upstream `prometheus-community/kube-prometheus-stack`. App charts own their own ServiceMonitors; the stack discovers them across all namespaces because selectors are configured with `*SelectorNilUsesHelmValues: false`. Dashboards loaded via Grafana sidecar through ConfigMaps labeled `grafana_dashboard=1`.

**Tech Stack:** Helm 3, kube-prometheus-stack chart `83.4.1` (app v0.90.1), Redpanda Connect 4.40.0 (Prometheus exporter built in), CNPG operator metrics, Grafana sidecar dashboards.

**Spec:** [docs/superpowers/specs/2026-04-13-tra-356-observability-stack-design.md](../specs/2026-04-13-tra-356-observability-stack-design.md)

---

## File map

**Created:**
- `helm/monitoring/values.yaml` — kube-prometheus-stack overrides
- `helm/monitoring/README.md` — bootstrap + access docs
- `helm/monitoring/manifests/cnpg-servicemonitor.yaml` — ServiceMonitor for CNPG (CNPG isn't our chart, so it lives here)
- `helm/monitoring/dashboards/cnpg.json` — CNPG dashboard (Grafana ID 20417 export)
- `helm/monitoring/dashboards/redpanda-connect.json` — minimal hand-rolled dashboard
- `helm/monitoring/manifests/dashboards-configmap.yaml` — wraps the JSONs as a sidecar-discoverable ConfigMap
- `helm/trakrf-ingester/templates/service.yaml`
- `helm/trakrf-ingester/templates/servicemonitor.yaml`

**Modified:**
- `justfile` — add `monitoring-bootstrap`, `grafana-ui`, `grafana-password`, `prometheus-ui`
- `helm/trakrf-ingester/values.yaml` — add `metrics.enabled`, `serviceMonitor.enabled`, metrics port
- `helm/trakrf-ingester/templates/configmap.yaml` — add `metrics:`/`http:` blocks to `connect.yaml`
- `helm/trakrf-ingester/templates/deployment.yaml` — expose `metrics` container port
- `helm/README.md` — link to `helm/monitoring/README.md`

---

## Verification model

This is infra-as-config. There are no unit tests; verification is `helm lint`, `helm template` rendering review, and live `kubectl` checks against the cluster. Each task ends with explicit verification commands and expected output.

---

## Task 1: Scaffold `helm/monitoring/` with pinned chart values

**Files:**
- Create: `helm/monitoring/values.yaml`

- [ ] **Step 1: Create the values file**

```yaml
# helm/monitoring/values.yaml
# Overrides for prometheus-community/kube-prometheus-stack.
# Pinned chart version is enforced by `just monitoring-bootstrap`, not here.

fullnameOverride: kube-prometheus-stack

# Discover ServiceMonitors / PodMonitors / PrometheusRules in any namespace,
# without requiring our app charts to add a release-specific label.
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    scrapeConfigSelectorNilUsesHelmValues: false
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi

grafana:
  defaultDashboardsEnabled: true
  persistence:
    enabled: true
    storageClassName: gp3
    size: 5Gi
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
    datasources:
      enabled: true
```

- [ ] **Step 2: Lint by rendering**

Run:
```bash
helm template kps prometheus-community/kube-prometheus-stack \
  --version 83.4.1 -n monitoring -f helm/monitoring/values.yaml >/dev/null
echo "render exit: $?"
```
Expected: `render exit: 0`

- [ ] **Step 3: Commit**

```bash
git add helm/monitoring/values.yaml
git commit -m "feat(tra-356): pin kube-prometheus-stack values"
```

---

## Task 2: Add justfile targets for bootstrap and UI access

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Append targets**

Append to the end of `justfile`:

```make
# Install kube-prometheus-stack into monitoring namespace
monitoring-bootstrap:
    @echo "Adding prometheus-community Helm repo..."
    @helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    @helm repo update prometheus-community
    @echo "Installing kube-prometheus-stack into monitoring namespace..."
    @helm upgrade --install kube-prometheus-stack \
      prometheus-community/kube-prometheus-stack \
      --version 83.4.1 \
      --namespace monitoring --create-namespace \
      -f helm/monitoring/values.yaml
    @echo "Waiting for Grafana to be ready..."
    @kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=300s
    @echo "Applying out-of-chart manifests (CNPG ServiceMonitor, dashboards)..."
    @kubectl apply -n monitoring -f helm/monitoring/manifests/

# Fetch Grafana admin password
grafana-password:
    @kubectl get secret kube-prometheus-stack-grafana -n monitoring \
      -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Port-forward Grafana UI to :3000 on all interfaces
grafana-ui:
    @echo "Grafana at http://<host-ip>:3000 (admin / \$(just grafana-password))"
    @kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 --address 0.0.0.0

# Port-forward Prometheus UI to :9090 on all interfaces
prometheus-ui:
    @echo "Prometheus at http://<host-ip>:9090"
    @kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 --address 0.0.0.0
```

- [ ] **Step 2: Verify just parses targets**

Run: `just --list | grep -E 'monitoring-bootstrap|grafana|prometheus-ui'`
Expected: four lines listing the new targets.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "feat(tra-356): add monitoring/grafana/prometheus just targets"
```

---

## Task 3: Add CNPG ServiceMonitor manifest

CNPG operator + clusters expose Prometheus metrics on the operator service `cnpg-controller-manager-metrics-service` in the `cnpg-system` namespace, and on each cluster's `<cluster>-r/-rw/-ro` services (port `metrics`, path `/metrics`). We ship a ServiceMonitor that targets both.

**Files:**
- Create: `helm/monitoring/manifests/cnpg-servicemonitor.yaml`

- [ ] **Step 1: Write the manifest**

```yaml
# helm/monitoring/manifests/cnpg-servicemonitor.yaml
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cnpg-operator
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: cnpg
spec:
  namespaceSelector:
    matchNames: ["cnpg-system"]
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  endpoints:
    - port: metrics
      interval: 30s
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-cluster-trakrf-db
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: cnpg
spec:
  namespaceSelector:
    matchNames: ["trakrf"]
  selector:
    matchLabels:
      cnpg.io/cluster: trakrf-db
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
```

> CNPG cluster pods expose metrics on a named port `metrics` (default 9187). The PodMonitor avoids needing a per-cluster Service.

- [ ] **Step 2: Validate YAML**

Run: `kubectl apply --dry-run=client -f helm/monitoring/manifests/cnpg-servicemonitor.yaml`
Expected: `servicemonitor.monitoring.coreos.com/cnpg-operator created (dry run)` and `podmonitor.monitoring.coreos.com/cnpg-cluster-trakrf-db created (dry run)`.

> If the CRDs aren't installed yet (cluster has no kube-prometheus-stack), `--dry-run=client` still validates schema-free; this passes. The live apply happens in Task 8.

- [ ] **Step 3: Commit**

```bash
git add helm/monitoring/manifests/cnpg-servicemonitor.yaml
git commit -m "feat(tra-356): add CNPG operator + cluster pod/service monitors"
```

---

## Task 4: Wire Redpanda Connect metrics into ingester ConfigMap

**Files:**
- Modify: `helm/trakrf-ingester/values.yaml`
- Modify: `helm/trakrf-ingester/templates/configmap.yaml`
- Modify: `helm/trakrf-ingester/templates/deployment.yaml`

- [ ] **Step 1: Add metrics defaults to values.yaml**

Append to `helm/trakrf-ingester/values.yaml` (above `nodeSelector`):

```yaml
# Prometheus metrics exposed by Redpanda Connect's built-in HTTP server.
metrics:
  enabled: true
  port: 4195

serviceMonitor:
  enabled: true
  interval: 30s
  scrapeTimeout: 10s
```

- [ ] **Step 2: Add metrics + http blocks to connect.yaml**

In `helm/trakrf-ingester/templates/configmap.yaml`, replace the `connect.yaml: |` block body with:

```yaml
  connect.yaml: |
    {{- if .Values.metrics.enabled }}
    http:
      address: 0.0.0.0:{{ .Values.metrics.port }}
      enabled: true
      root_path: /
      debug_endpoints: false

    metrics:
      prometheus: {}
    {{- end }}

    input:
      mqtt:
        urls:
          - ${MQTT_URL}
        client_id: ${MQTT_CLIENT_ID:-trakrf-ingester}
        connect_timeout: 30s
        topics:
          - ${MQTT_TOPIC}

    pipeline:
      processors: []

    output:
      sql_raw:
        driver: postgres
        dsn: ${PG_URL}
        query: "INSERT INTO trakrf.identifier_scans (message_topic, message_data) VALUES ($1, $2)"
        args_mapping: 'root = [ meta("mqtt_topic"), this.string() ]'
```

- [ ] **Step 3: Expose container port in deployment.yaml**

In `helm/trakrf-ingester/templates/deployment.yaml`, insert this block immediately after the `imagePullPolicy:` line of the `ingester` container:

```yaml
          {{- if .Values.metrics.enabled }}
          ports:
            - name: metrics
              containerPort: {{ .Values.metrics.port }}
              protocol: TCP
          {{- end }}
```

- [ ] **Step 4: Lint and render**

Run:
```bash
helm lint helm/trakrf-ingester
helm template helm/trakrf-ingester | grep -E 'name: metrics|prometheus: \{\}|address: 0.0.0.0:4195'
```
Expected: lint passes; grep shows the metrics port name, `prometheus: {}`, and HTTP address line.

- [ ] **Step 5: Commit**

```bash
git add helm/trakrf-ingester/values.yaml \
        helm/trakrf-ingester/templates/configmap.yaml \
        helm/trakrf-ingester/templates/deployment.yaml
git commit -m "feat(tra-356): expose Redpanda Connect metrics on :4195"
```

---

## Task 5: Add ingester Service exposing the metrics port

**Files:**
- Create: `helm/trakrf-ingester/templates/service.yaml`

- [ ] **Step 1: Write the Service template**

```yaml
{{- if .Values.metrics.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "trakrf-ingester.fullname" . }}
  labels:
    {{- include "trakrf-ingester.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  clusterIP: None  # headless — no virtual IP needed for scrape
  selector:
    {{- include "trakrf-ingester.selectorLabels" . | nindent 4 }}
  ports:
    - name: metrics
      port: {{ .Values.metrics.port }}
      targetPort: metrics
      protocol: TCP
{{- end }}
```

- [ ] **Step 2: Render and verify**

Run:
```bash
helm template helm/trakrf-ingester | yq 'select(.kind == "Service") | .metadata.name + " port=" + (.spec.ports[0].port | tostring)'
```
Expected: `trakrf-ingester port=4195`

> If `yq` isn't installed, fall back to `helm template helm/trakrf-ingester | grep -A2 'kind: Service'`.

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-ingester/templates/service.yaml
git commit -m "feat(tra-356): add ingester Service for metrics port"
```

---

## Task 6: Add ingester ServiceMonitor

**Files:**
- Create: `helm/trakrf-ingester/templates/servicemonitor.yaml`

- [ ] **Step 1: Write the ServiceMonitor**

```yaml
{{- if and .Values.metrics.enabled .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "trakrf-ingester.fullname" . }}
  labels:
    {{- include "trakrf-ingester.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "trakrf-ingester.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: metrics
      path: /metrics
      interval: {{ .Values.serviceMonitor.interval }}
      scrapeTimeout: {{ .Values.serviceMonitor.scrapeTimeout }}
{{- end }}
```

- [ ] **Step 2: Render and verify**

Run:
```bash
helm template helm/trakrf-ingester | grep -A4 'kind: ServiceMonitor'
```
Expected: shows `kind: ServiceMonitor`, name `trakrf-ingester`, and `port: metrics`.

- [ ] **Step 3: Lint**

Run: `helm lint helm/trakrf-ingester`
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-ingester/templates/servicemonitor.yaml
git commit -m "feat(tra-356): add ingester ServiceMonitor"
```

---

## Task 7: Add dashboard ConfigMap (CNPG + Redpanda Connect)

The Grafana sidecar watches all namespaces for ConfigMaps with label `grafana_dashboard=1` and loads any JSON keys as dashboards.

**Files:**
- Create: `helm/monitoring/dashboards/cnpg.json`
- Create: `helm/monitoring/dashboards/redpanda-connect.json`
- Create: `helm/monitoring/manifests/dashboards-configmap.yaml`

- [ ] **Step 1: Fetch CNPG dashboard JSON**

Run:
```bash
mkdir -p helm/monitoring/dashboards
curl -fsSL "https://grafana.com/api/dashboards/20417/revisions/latest/download" \
  -o helm/monitoring/dashboards/cnpg.json
jq '.title' helm/monitoring/dashboards/cnpg.json
```
Expected: a non-empty title string (e.g. `"CloudNativePG"`).

> If the download 404s, the ID has changed — search grafana.com for "CloudNativePG", grab a current cluster dashboard ID, and substitute.

- [ ] **Step 2: Hand-roll a minimal Redpanda Connect dashboard**

Write `helm/monitoring/dashboards/redpanda-connect.json`:

```json
{
  "title": "Redpanda Connect — trakrf-ingester",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Input messages received (rate/s)",
      "gridPos": { "h": 5, "w": 6, "x": 0, "y": 0 },
      "targets": [
        { "expr": "sum(rate(input_received{job=\"trakrf-ingester\"}[5m]))" }
      ]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Output messages sent (rate/s)",
      "gridPos": { "h": 5, "w": 6, "x": 6, "y": 0 },
      "targets": [
        { "expr": "sum(rate(output_sent{job=\"trakrf-ingester\"}[5m]))" }
      ]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "Output errors (rate/s)",
      "gridPos": { "h": 5, "w": 6, "x": 12, "y": 0 },
      "targets": [
        { "expr": "sum(rate(output_error{job=\"trakrf-ingester\"}[5m]))" }
      ]
    },
    {
      "id": 4,
      "type": "timeseries",
      "title": "Input vs output rate",
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 5 },
      "targets": [
        { "expr": "sum(rate(input_received{job=\"trakrf-ingester\"}[5m]))", "legendFormat": "input" },
        { "expr": "sum(rate(output_sent{job=\"trakrf-ingester\"}[5m]))", "legendFormat": "output" },
        { "expr": "sum(rate(output_error{job=\"trakrf-ingester\"}[5m]))", "legendFormat": "errors" }
      ]
    }
  ]
}
```

> Metric names follow Redpanda Connect's Prometheus exporter (`input_received`, `output_sent`, `output_error`). If actual metric names differ at runtime, the panels show "no data" — fix by inspecting the live `/metrics` output (Task 9 verifies).

- [ ] **Step 3: Wrap dashboards as a sidecar ConfigMap**

Create `helm/monitoring/manifests/dashboards-configmap.yaml`:

```yaml
# Generated stub — see README. The actual ConfigMap is built at apply-time
# from helm/monitoring/dashboards/*.json by `just monitoring-bootstrap`.
# This file exists so kubectl apply -f helm/monitoring/manifests/ has
# something to wrap the JSONs into.
```

…actually use `kubectl create configmap --dry-run=client -o yaml` to generate it during bootstrap instead. Update `justfile` `monitoring-bootstrap` target by inserting these lines BEFORE the existing `kubectl apply -n monitoring -f helm/monitoring/manifests/` line:

```make
    @echo "Building dashboards ConfigMap from helm/monitoring/dashboards/..."
    @kubectl create configmap kube-prometheus-stack-dashboards \
      --namespace monitoring \
      --from-file=helm/monitoring/dashboards/ \
      --dry-run=client -o yaml \
      | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
      | kubectl apply -f -
```

Delete the placeholder `helm/monitoring/manifests/dashboards-configmap.yaml` — it's no longer needed.

- [ ] **Step 4: Sanity-check the dry-run pipeline**

Run:
```bash
kubectl create configmap kube-prometheus-stack-dashboards \
  --namespace monitoring \
  --from-file=helm/monitoring/dashboards/ \
  --dry-run=client -o yaml | head -20
```
Expected: a ConfigMap manifest with `data:` keys `cnpg.json` and `redpanda-connect.json`.

- [ ] **Step 5: Commit**

```bash
git add helm/monitoring/dashboards/ justfile
git rm -f helm/monitoring/manifests/dashboards-configmap.yaml 2>/dev/null || true
git commit -m "feat(tra-356): add CNPG + Redpanda Connect dashboards"
```

---

## Task 8: Write `helm/monitoring/README.md`

**Files:**
- Create: `helm/monitoring/README.md`
- Modify: `helm/README.md`

- [ ] **Step 1: Write the README**

```markdown
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

```sh
just grafana-password   # admin password
just grafana-ui         # port-forward to :3000
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
```

- [ ] **Step 2: Update `helm/README.md`**

Append to `helm/README.md`:

```markdown

## Monitoring

See `helm/monitoring/README.md` for the kube-prometheus-stack bootstrap.
```

- [ ] **Step 3: Commit**

```bash
git add helm/monitoring/README.md helm/README.md
git commit -m "docs(tra-356): document monitoring bootstrap"
```

---

## Task 9: Live deploy + verify on cluster

This task runs against the live EKS cluster. Skip if no cluster access.

- [ ] **Step 1: Bootstrap the stack**

Run: `just monitoring-bootstrap`
Expected: Helm install completes, Grafana rollout succeeds within 5 minutes, kubectl apply outputs `servicemonitor/cnpg-operator created` and `podmonitor/cnpg-cluster-trakrf-db created` and `configmap/kube-prometheus-stack-dashboards created`.

- [ ] **Step 2: Confirm pods Ready**

Run: `kubectl get pods -n monitoring`
Expected: all pods `Running` and `READY 1/1` (or `2/2` for Grafana with sidecars).

- [ ] **Step 3: Upgrade ingester chart to expose metrics**

Run:
```bash
helm upgrade --install trakrf-ingester helm/trakrf-ingester \
  -n trakrf -f <your values.secret.yaml>
kubectl rollout status deployment/trakrf-ingester -n trakrf --timeout=120s
```
Expected: rollout completes; `kubectl get svc trakrf-ingester -n trakrf` shows port `4195`.

- [ ] **Step 4: Curl the ingester metrics endpoint**

Run:
```bash
kubectl port-forward -n trakrf svc/trakrf-ingester 4195:4195 &
PF=$!
sleep 2
curl -s localhost:4195/metrics | grep -E '^(input_received|output_sent|output_error)' | head
kill $PF
```
Expected: at least one matching metric line. **If none match, inspect the actual metric names in the full `/metrics` output and update `helm/monitoring/dashboards/redpanda-connect.json` accordingly, then re-bootstrap and re-commit.**

- [ ] **Step 5: Verify Prometheus targets**

Run: `just prometheus-ui` (in another shell), open `http://<host>:9090/targets`.
Expected: targets `cnpg-operator`, `cnpg-cluster-trakrf-db`, `trakrf-ingester`, plus the chart defaults — all `UP`.

- [ ] **Step 6: Verify Grafana dashboards**

Run: `just grafana-ui`, log in with `just grafana-password`.
Expected: under Dashboards → Browse, both `CloudNativePG` and `Redpanda Connect — trakrf-ingester` appear and render data.

- [ ] **Step 7: Capture screenshots**

Save screenshots of: cluster overview default dashboard, CNPG dashboard, Redpanda Connect dashboard. Stash under `docs/screenshots/m1/` (create dir).

- [ ] **Step 8: Commit screenshots**

```bash
git add docs/screenshots/m1/
git commit -m "docs(tra-356): add M1 observability screenshots"
```

---

## Task 10: Open PR

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin worktree-tra-356
gh pr create --title "feat(tra-356): kube-prometheus-stack observability" \
  --body "$(cat <<'EOF'
## Summary
- Bootstraps kube-prometheus-stack via Helm into `monitoring` ns
- Adds CNPG operator + cluster pod/service monitors
- Wires Redpanda Connect Prometheus exporter on ingester (`:4195`) + ServiceMonitor
- Loads CNPG and Redpanda Connect dashboards via Grafana sidecar
- New `just` targets: `monitoring-bootstrap`, `grafana-ui`, `grafana-password`, `prometheus-ui`

Spec: `docs/superpowers/specs/2026-04-13-tra-356-observability-stack-design.md`

## Test plan
- [x] `helm lint` passes for monitoring + ingester
- [x] `helm template` renders cleanly
- [x] Live: all pods Ready in `monitoring`
- [x] Live: Prometheus targets `UP` for CNPG + ingester
- [x] Live: dashboards render with data
- [x] Screenshots captured for M1 README

Closes TRA-356.
EOF
)"
```

- [ ] **Step 2: Note follow-up tickets to file (post-merge)**

- "Adopt kube-prometheus-stack into ArgoCD" (M2)
- "Add `/metrics` endpoint to TrakRF backend + ServiceMonitor + dashboard"

---

## Self-review

- **Spec coverage:** every spec section maps to a task — chart values (T1), justfile (T2), CNPG monitors (T3), ingester metrics + Service + ServiceMonitor (T4–T6), dashboards (T7), README (T8), live verification (T9). Non-goals (ArgoCD adoption, backend metrics, alert routing, ingress) are explicitly deferred in T10 step 2.
- **Placeholders:** none. The one runtime unknown (exact Redpanda Connect metric names) is handled with an explicit "if names differ, inspect and update" branch in T9 step 4 — not a TBD.
- **Type/name consistency:** chart name `kube-prometheus-stack` (via `fullnameOverride`), Grafana svc `kube-prometheus-stack-grafana`, Prometheus svc `kube-prometheus-stack-prometheus`, secret `kube-prometheus-stack-grafana` — all consistent across tasks. ConfigMap name `kube-prometheus-stack-dashboards` consistent T7↔T9.
