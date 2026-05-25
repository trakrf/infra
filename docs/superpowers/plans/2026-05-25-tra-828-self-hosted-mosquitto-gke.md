# TRA-828 — Self-hosted Mosquitto broker on GKE (off EMQX Cloud) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace EMQX Cloud Serverless with self-hosted Mosquitto sidecars in `trakrf-ingester` pods on GKE, fanned out per env (`preview`, `prod`) with per-env L4 LoadBalancers, host-specific public ACME certs, and Prometheus metrics — so the GL-S10 (no-SNI, TLS-1.2-only) can reach a broker again.

**Architecture:** One `trakrf-ingester` pod per env, three containers (Redpanda Connect ingester + Mosquitto + sapcc/mosquitto-exporter). Mosquitto terminates TLS at `:8883` on a per-env passthrough L4 LoadBalancer; plain `:1883` is bound to `127.0.0.1` for the loopback consumers (ingester + exporter). cert-manager issues a host-specific Let's Encrypt cert per env via the existing GKE Cloud DNS Workload Identity solver (TRA-829 zone foundation). Stakater Reloader bounces pods on cert/auth Secret rotation.

**Tech Stack:** OpenTofu (GCP + Cloudflare providers), Helm (in-repo `trakrf-ingester`, `cert-manager-config`, `argocd/root` app-of-apps), ArgoCD, cert-manager, GKE Workload Identity, `eclipse-mosquitto:2.0.21`, `sapcc/mosquitto-exporter:0.8.0`, Stakater Reloader.

**Spec:** `docs/superpowers/specs/2026-05-25-tra-828-self-hosted-mosquitto-gke-design.md`

**Out of band before sync (manual operator steps, not in the PR):**
1. `tofu -chdir=terraform/gcp apply` (creates static IPs + IAM zone binding addition)
2. `tofu -chdir=terraform/cloudflare apply` (no-op — `gke.trakrf.id` already delegated by TRA-829)
3. `just mosquitto-secrets` (after `.env.local` has `MOSQUITTO_USER` + `MOSQUITTO_PASSWORD`)
4. `scripts/apply-root-app.sh gke` (re-pulls Tofu outputs into root chart inlineValues, including new per-env `mqttPreviewIp`/`mqttProdIp`)
5. Per `feedback_root_chart_needs_manual_bump`, this script run is required for changes under `argocd/root/templates/*` to take effect.

---

## File Inventory

### Created
- `terraform/gcp/mqtt.tf` — two `google_compute_address` resources for per-env broker LBs.
- `helm/trakrf-ingester/templates/mosquitto-configmap.yaml`
- `helm/trakrf-ingester/templates/mqtt-service.yaml`
- `helm/trakrf-ingester/templates/certificate.yaml`
- `argocd/root/templates/reloader.yaml`

### Modified
- `terraform/gcp/outputs.tf` — `mqtt_preview_ip`, `mqtt_prod_ip` outputs.
- `terraform/gcp/dns.tf` — A records `mqtt.preview.gke.trakrf.id`, `mqtt.prod.gke.trakrf.id`.
- `helm/trakrf-ingester/values.yaml` — `broker.*`, refactor `mqtt.*`.
- `helm/trakrf-ingester/values-gke.yaml` — enable broker; per-env hostname/IP come via inlineValues.
- `helm/trakrf-ingester/values-aks.yaml` — `broker.enabled: false`, `replicaCount: 0` (dormant clusters).
- `helm/trakrf-ingester/values-eks.yaml` — same.
- `helm/trakrf-ingester/templates/deployment.yaml` — add sidecars, swap MQTT env wiring, add Reloader annotation.
- `helm/trakrf-ingester/templates/service.yaml` — add `mqtt-metrics` port.
- `helm/trakrf-ingester/templates/servicemonitor.yaml` — scrape `mqtt-metrics`.
- `argocd/root/templates/trakrf-ingester.yaml` — per-env `broker.hostname`, `broker.loadBalancerIP`, `mqtt.clientId`.
- `argocd/root/values.yaml` — `mqttPreviewIp`, `mqttProdIp` placeholders.
- `scripts/apply-root-app.sh` — read & inject `mqtt_preview_ip` / `mqtt_prod_ip`.
- `justfile` — `mosquitto-secrets` recipe (new), delete `ingester-secrets` recipe.
- `.env.local.sample` — add `MOSQUITTO_USER`, `MOSQUITTO_PASSWORD`; drop `MQTT_URL`.
- `README.md` — replace `just ingester-secrets` → `just mosquitto-secrets`; update narrative.
- `helm/README.md` (if it references the legacy recipe).

### Retired (deleted)
- `justfile` `ingester-secrets` recipe.
- `trakrf-mqtt-credentials` Secret (cleanup is a post-cutover manual step, not in PR).

---

## Task 1: Terraform — per-env broker static IPs

**Files:**
- Create: `terraform/gcp/mqtt.tf`
- Modify: `terraform/gcp/outputs.tf`

- [ ] **Step 1: Create `terraform/gcp/mqtt.tf`**

```hcl
# Static regional EXTERNAL IPs for per-env Mosquitto LoadBalancers (TRA-828).
# One per env (preview, prod) so DNS A records and Helm loadBalancerIP can be
# wired before the LB Service exists. Matches the traefik LB pattern in
# traefik_lb.tf — regional, EXTERNAL, IPv4.

resource "google_compute_address" "mqtt_preview" {
  name         = "mqtt-preview"
  description  = "Static IP for trakrf-ingester preview MQTT LoadBalancer (TRA-828)"
  region       = var.region
  address_type = "EXTERNAL"
  labels       = local.common_labels
}

resource "google_compute_address" "mqtt_prod" {
  name         = "mqtt-prod"
  description  = "Static IP for trakrf-ingester prod MQTT LoadBalancer (TRA-828)"
  region       = var.region
  address_type = "EXTERNAL"
  labels       = local.common_labels
}
```

- [ ] **Step 2: Append outputs to `terraform/gcp/outputs.tf`**

Append at end of file:

```hcl

# TRA-828 — per-env MQTT broker static IPs. Consumed by:
#   - terraform/gcp/dns.tf A records for mqtt.{env}.gke.trakrf.id
#   - scripts/apply-root-app.sh -> argocd/root values -> trakrf-ingester per-env LB IP

output "mqtt_preview_ip" {
  description = "Static IP for the preview MQTT LoadBalancer (mqtt.preview.gke.trakrf.id)"
  value       = google_compute_address.mqtt_preview.address
}

output "mqtt_prod_ip" {
  description = "Static IP for the prod MQTT LoadBalancer (mqtt.prod.gke.trakrf.id)"
  value       = google_compute_address.mqtt_prod.address
}
```

- [ ] **Step 3: Validate format**

Run: `tofu -chdir=terraform/gcp fmt -check -diff`
Expected: exit 0; no diff. If diff, run without `-check`, then re-run check.

- [ ] **Step 4: Validate syntax**

Run: `tofu -chdir=terraform/gcp validate`
Expected: `Success! The configuration is valid.` (may require `tofu init` first if backend not set up locally — that's fine; `validate` works post-init or with `-json` with no backend).

If init is needed (no R2 creds in this session), skip validate and rely on `helm template` + later end-to-end smoke. Note in commit message that local validate was skipped.

- [ ] **Step 5: Commit**

```bash
git add terraform/gcp/mqtt.tf terraform/gcp/outputs.tf
git commit -m "feat(tra-828): per-env MQTT broker static IPs (preview, prod)"
```

---

## Task 2: Terraform — per-env DNS A records

**Files:**
- Modify: `terraform/gcp/dns.tf`

- [ ] **Step 1: Append per-env broker A records**

Append to `terraform/gcp/dns.tf` after the existing `gke_id_wildcard` block:

```hcl

# TRA-828 — Per-env broker A records on dedicated static IPs (not the wildcard,
# which points at Traefik). DNS for the device-facing Mosquitto LoadBalancers.
resource "google_dns_record_set" "mqtt_preview" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = "mqtt.preview.${google_dns_managed_zone.gke_trakrf_id.dns_name}"
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.mqtt_preview.address]
}

resource "google_dns_record_set" "mqtt_prod" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = "mqtt.prod.${google_dns_managed_zone.gke_trakrf_id.dns_name}"
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.mqtt_prod.address]
}
```

- [ ] **Step 2: Validate format**

Run: `tofu -chdir=terraform/gcp fmt -check -diff`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add terraform/gcp/dns.tf
git commit -m "feat(tra-828): A records for mqtt.{preview,prod}.gke.trakrf.id"
```

---

## Task 3: Helm — `trakrf-ingester` values.yaml refactor

**Files:**
- Modify: `helm/trakrf-ingester/values.yaml`

- [ ] **Step 1: Replace `mqtt` block and add `broker` block**

Replace the `# MQTT config` block (lines ~52-61) with:

```yaml
# MQTT config — ingester reaches the broker over loopback (sidecar pattern).
# Credentials come from the broker auth Secret (broker.authSecret), and
# MQTT_URL is composed in-template via $(VAR) env interpolation.
# See feedback_k8s_dsn_composition for the pattern.
mqtt:
  # Non-secret; overridden per-env in argocd/root/templates/trakrf-ingester.yaml
  # so each env logs as a distinct client. Distinct clientIds avoid MQTT's
  # duplicate-eviction loop if the same broker is ever shared across envs.
  # See feedback_mqtt_clientid_per_cluster.
  clientId: trakrf-ingester
  topic: "trakrf/scans/#"
  host: localhost
  port: 1883
  user: trakrf-ingester

# Mosquitto sidecar (TRA-828). One pod = ingester + broker + exporter.
# Disabled in clusters without per-env LB/cert wiring; enabled in values-gke.yaml.
broker:
  enabled: false
  image:
    repository: eclipse-mosquitto
    tag: "2.0.21"
    pullPolicy: IfNotPresent
  # Per-env values injected via inlineValues by argocd/root/templates/trakrf-ingester.yaml.
  hostname: ""
  loadBalancerIP: ""
  # Reflector mirrors this Secret from trakrf-system into per-env namespaces.
  # Created by `just mosquitto-secrets`. Keys:
  #   passwd    — mosquitto password_file (single username:hash line)
  #   username  — literal MQTT username (consumed by ingester + exporter env)
  #   password  — literal MQTT password (same)
  authSecret: trakrf-mosquitto-auth
  # cert-manager-issued TLS cert Secret for the :8883 listener; created by the
  # per-env Certificate resource (templates/certificate.yaml).
  certSecret: trakrf-mqtt-tls
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 250m
      memory: 256Mi
  exporter:
    enabled: true
    image:
      repository: sapcc/mosquitto-exporter
      tag: "0.8.0"
      pullPolicy: IfNotPresent
    port: 9234
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 50m
        memory: 64Mi
```

- [ ] **Step 2: Render base values to verify chart still templates**

Run: `helm template trakrf-ingester helm/trakrf-ingester | head -50`
Expected: renders without error (deployment will reference values added in later tasks but should not crash on the values file change alone — note that the deployment template still references `.Values.mqtt.credentialsSecret`; we'll update that in Task 4).

Expected: chart renders the existing deployment.yaml; we accept transient stale references to `mqtt.credentialsSecret` until Task 4 lands.

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-ingester/values.yaml
git commit -m "feat(tra-828): trakrf-ingester values — broker sidecar block, mqtt host/user split"
```

---

## Task 4: Helm — `trakrf-ingester` deployment.yaml sidecars + env rewire

**Files:**
- Modify: `helm/trakrf-ingester/templates/deployment.yaml`

- [ ] **Step 1: Rewrite `deployment.yaml`**

Replace file contents with:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "trakrf-ingester.fullname" . }}
  labels:
    {{- include "trakrf-ingester.labels" . | nindent 4 }}
  annotations:
    # Stakater Reloader bounces this Deployment on changes to the broker auth
    # Secret (creds rotation) and the cert Secret (cert-manager renewal every
    # ~60 days). Mosquitto does not reliably pick up a new cert on SIGHUP.
    # The annotation is harmless when broker is disabled (no watched Secrets).
    reloader.stakater.com/auto: "true"
spec:
  replicas: {{ .Values.replicaCount }}
  # Ingester holds an MQTT session; avoid overlapping pods during updates.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "trakrf-ingester.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        {{- if .Values.broker.enabled }}
        checksum/mosquitto-config: {{ include (print $.Template.BasePath "/mosquitto-configmap.yaml") . | sha256sum }}
        {{- end }}
      labels:
        {{- include "trakrf-ingester.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: ingester
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- if .Values.metrics.enabled }}
          ports:
            - name: metrics
              containerPort: {{ .Values.metrics.port }}
              protocol: TCP
          {{- end }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          args:
            - run
            - /etc/connect/connect.yaml
          env:
            - name: MQTT_TOPIC
              value: {{ .Values.mqtt.topic | quote }}
            - name: MQTT_CLIENT_ID
              value: {{ .Values.mqtt.clientId | quote }}
            - name: MQTT_USER
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.broker.authSecret }}
                  key: username
            - name: MQTT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.broker.authSecret }}
                  key: password
            # Composed via $(VAR) env interpolation (see feedback_k8s_dsn_composition).
            - name: MQTT_URL
              value: "mqtt://$(MQTT_USER):$(MQTT_PASSWORD)@{{ .Values.mqtt.host }}:{{ .Values.mqtt.port }}"
            - name: PG_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.database.credentialsSecret }}
                  key: password
            - name: PG_URL
              value: "postgresql://{{ .Values.database.user }}:$(PG_PASSWORD)@{{ .Values.database.host }}:{{ .Values.database.port }}/{{ .Values.database.name }}?sslmode={{ .Values.database.sslmode }}&options=-c%20search_path%3D{{ .Values.database.searchPath }}"
          volumeMounts:
            - name: config
              mountPath: /etc/connect
              readOnly: true
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
        {{- if .Values.broker.enabled }}
        - name: mosquitto
          image: "{{ .Values.broker.image.repository }}:{{ .Values.broker.image.tag }}"
          imagePullPolicy: {{ .Values.broker.image.pullPolicy }}
          ports:
            - name: mqtts
              containerPort: 8883
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            # eclipse-mosquitto image's `mosquitto` user = UID 1883.
            runAsUser: 1883
            runAsGroup: 1883
          readinessProbe:
            tcpSocket:
              port: 8883
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 8883
            initialDelaySeconds: 30
            periodSeconds: 30
          volumeMounts:
            - name: mosquitto-config
              mountPath: /mosquitto/config
              readOnly: true
            - name: mosquitto-tls
              mountPath: /mosquitto/tls
              readOnly: true
            - name: mosquitto-auth
              mountPath: /mosquitto/auth
              readOnly: true
            - name: mosquitto-data
              mountPath: /mosquitto/data
          resources:
            {{- toYaml .Values.broker.resources | nindent 12 }}
        {{- if .Values.broker.exporter.enabled }}
        - name: mosquitto-exporter
          image: "{{ .Values.broker.exporter.image.repository }}:{{ .Values.broker.exporter.image.tag }}"
          imagePullPolicy: {{ .Values.broker.exporter.image.pullPolicy }}
          ports:
            - name: mqtt-metrics
              containerPort: {{ .Values.broker.exporter.port }}
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            # sapcc/mosquitto-exporter is distroless-ish; runs as nobody.
            runAsUser: 65534
            runAsGroup: 65534
          env:
            - name: BROKER_ENDPOINT
              value: "tcp://localhost:1883"
            - name: MQTT_USER
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.broker.authSecret }}
                  key: username
            - name: MQTT_PASS
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.broker.authSecret }}
                  key: password
            - name: BIND_ADDRESS
              value: ":{{ .Values.broker.exporter.port }}"
          readinessProbe:
            httpGet:
              path: /metrics
              port: mqtt-metrics
            initialDelaySeconds: 5
            periodSeconds: 30
          resources:
            {{- toYaml .Values.broker.exporter.resources | nindent 12 }}
        {{- end }}
        {{- end }}
      volumes:
        - name: config
          configMap:
            name: {{ include "trakrf-ingester.fullname" . }}
        {{- if .Values.broker.enabled }}
        - name: mosquitto-config
          configMap:
            name: {{ include "trakrf-ingester.fullname" . }}-mosquitto
        - name: mosquitto-tls
          secret:
            secretName: {{ .Values.broker.certSecret }}
        - name: mosquitto-auth
          secret:
            secretName: {{ .Values.broker.authSecret }}
            items:
              - key: passwd
                path: passwd
        - name: mosquitto-data
          emptyDir: {}
        {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

- [ ] **Step 2: Render with broker disabled (base)**

Run: `helm template trakrf-ingester helm/trakrf-ingester | grep -E 'name: (ingester|mosquitto|mosquitto-exporter)'`
Expected: only `name: ingester` (single container — broker.enabled defaults false).

- [ ] **Step 3: Render with broker enabled**

Run:
```bash
helm template trakrf-ingester helm/trakrf-ingester \
  --set broker.enabled=true \
  --set broker.hostname=mqtt.preview.gke.trakrf.id \
  --set broker.loadBalancerIP=1.2.3.4 \
  | grep -E 'name: (ingester|mosquitto|mosquitto-exporter)|MQTT_(URL|USER|PASSWORD|TOPIC)|broker.authSecret|trakrf-mosquitto-auth'
```
Expected: three container names render; MQTT_URL composed via `$(MQTT_USER):$(MQTT_PASSWORD)@localhost:1883`; secret references `trakrf-mosquitto-auth`.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-ingester/templates/deployment.yaml
git commit -m "feat(tra-828): trakrf-ingester deployment — mosquitto + exporter sidecars, MQTT_URL composed"
```

---

## Task 5: Helm — `mosquitto-configmap.yaml`

**Files:**
- Create: `helm/trakrf-ingester/templates/mosquitto-configmap.yaml`

- [ ] **Step 1: Create the ConfigMap template**

```yaml
{{- if .Values.broker.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "trakrf-ingester.fullname" . }}-mosquitto
  labels:
    {{- include "trakrf-ingester.labels" . | nindent 4 }}
data:
  mosquitto.conf: |
    # Per-listener auth (so the loopback plain listener can require auth too).
    per_listener_settings true

    # Loopback-only plain listener for the ingester + exporter sidecars.
    # Authenticated; never reachable from outside the pod (bound to 127.0.0.1).
    listener 1883 127.0.0.1
    allow_anonymous false
    password_file /mosquitto/auth/passwd

    # Public TLS listener. cert-manager mounts the cert Secret at /mosquitto/tls.
    # TLS 1.2 only — the GL-S10 BLE gateway's mbedTLS build is 1.2-only and a
    # 1.3-floor would brick it. See TRA-827.
    listener 8883 0.0.0.0
    protocol mqtt
    certfile /mosquitto/tls/tls.crt
    keyfile  /mosquitto/tls/tls.key
    tls_version tlsv1.2
    allow_anonymous false
    password_file /mosquitto/auth/passwd

    # Stateless broker — current device traffic is QoS 0, so persistence is
    # inert. Sidesteps the zonal-PD AZ-orphan trap (TRA-364). emptyDir is
    # mounted at persistence_location to satisfy the directive even when off.
    persistence false
    persistence_location /mosquitto/data/

    # Log to stdout so kubectl logs sees broker events.
    log_dest stdout
{{- end }}
```

- [ ] **Step 2: Render to verify**

Run: `helm template trakrf-ingester helm/trakrf-ingester --set broker.enabled=true --set broker.hostname=x --set broker.loadBalancerIP=1.2.3.4 | grep -A 2 'name: trakrf-ingester-mosquitto'`
Expected: ConfigMap rendered with `data.mosquitto.conf` containing the listener config.

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-ingester/templates/mosquitto-configmap.yaml
git commit -m "feat(tra-828): mosquitto ConfigMap — TLS 1.2 :8883, loopback :1883 with auth"
```

---

## Task 6: Helm — per-env `mqtt-service.yaml` LoadBalancer

**Files:**
- Create: `helm/trakrf-ingester/templates/mqtt-service.yaml`

- [ ] **Step 1: Create the Service template**

```yaml
{{- if .Values.broker.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "trakrf-ingester.fullname" . }}-mqtt
  labels:
    {{- include "trakrf-ingester.labels" . | nindent 4 }}
  annotations:
    # Explicitly pin to GKE's passthrough L4 NetLB. NEG-backed L4 ILBs or any
    # L7 ingress would either terminate TLS or do SNI routing — both break
    # the no-SNI GL-S10 client. Default L4 ext NetLB is passthrough; the
    # annotation is belt-and-suspenders.
    cloud.google.com/l4-rbs: "enabled"
spec:
  type: LoadBalancer
  loadBalancerIP: {{ .Values.broker.loadBalancerIP }}
  # Preserves the real client IP in broker logs (visible via $SYS) — useful
  # when chasing a flapping device. Pods are 1:1 with the LB so per-node
  # health checks are not a constraint.
  externalTrafficPolicy: Local
  selector:
    {{- include "trakrf-ingester.selectorLabels" . | nindent 4 }}
  ports:
    - name: mqtts
      port: 8883
      targetPort: mqtts
      protocol: TCP
{{- end }}
```

- [ ] **Step 2: Render to verify**

Run: `helm template trakrf-ingester helm/trakrf-ingester --set broker.enabled=true --set broker.hostname=x --set broker.loadBalancerIP=1.2.3.4 | grep -A 12 'kind: Service' | head -30`
Expected: a `LoadBalancer` Service named `trakrf-ingester-mqtt` with `loadBalancerIP: 1.2.3.4`, port 8883.

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-ingester/templates/mqtt-service.yaml
git commit -m "feat(tra-828): mqtt LoadBalancer Service — passthrough L4 on per-env static IP"
```

---

## Task 7: Helm — per-env `certificate.yaml`

**Files:**
- Create: `helm/trakrf-ingester/templates/certificate.yaml`

- [ ] **Step 1: Create the Certificate template**

```yaml
{{- if .Values.broker.enabled }}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ include "trakrf-ingester.fullname" . }}-mqtt
  labels:
    {{- include "trakrf-ingester.labels" . | nindent 4 }}
spec:
  secretName: {{ .Values.broker.certSecret }}
  # Host-specific cert, not wildcard. The GL-S10's minimal mbedTLS build has
  # inconsistent wildcard-SAN matching; host-specific avoids the issue.
  commonName: {{ .Values.broker.hostname }}
  dnsNames:
    - {{ .Values.broker.hostname }}
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
{{- end }}
```

- [ ] **Step 2: Render to verify**

Run: `helm template trakrf-ingester helm/trakrf-ingester --set broker.enabled=true --set broker.hostname=mqtt.preview.gke.trakrf.id --set broker.loadBalancerIP=1.2.3.4 | grep -A 10 'kind: Certificate'`
Expected: Certificate with `commonName: mqtt.preview.gke.trakrf.id`, single-entry dnsNames, `secretName: trakrf-mqtt-tls`.

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-ingester/templates/certificate.yaml
git commit -m "feat(tra-828): per-env Certificate for mqtt.{env}.gke.trakrf.id (host-specific)"
```

---

## Task 8: Helm — extend metrics Service + ServiceMonitor for broker exporter

**Files:**
- Modify: `helm/trakrf-ingester/templates/service.yaml`
- Modify: `helm/trakrf-ingester/templates/servicemonitor.yaml`

- [ ] **Step 1: Add `mqtt-metrics` port to headless metrics Service**

Replace `helm/trakrf-ingester/templates/service.yaml` contents with:

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
    {{- if and .Values.broker.enabled .Values.broker.exporter.enabled }}
    - name: mqtt-metrics
      port: {{ .Values.broker.exporter.port }}
      targetPort: mqtt-metrics
      protocol: TCP
    {{- end }}
{{- end }}
```

- [ ] **Step 2: Add `mqtt-metrics` endpoint to ServiceMonitor**

Replace `helm/trakrf-ingester/templates/servicemonitor.yaml` contents with:

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
    {{- if and .Values.broker.enabled .Values.broker.exporter.enabled }}
    - port: mqtt-metrics
      path: /metrics
      interval: {{ .Values.serviceMonitor.interval }}
      scrapeTimeout: {{ .Values.serviceMonitor.scrapeTimeout }}
    {{- end }}
{{- end }}
```

- [ ] **Step 3: Render to verify**

Run: `helm template trakrf-ingester helm/trakrf-ingester --set broker.enabled=true --set broker.hostname=x --set broker.loadBalancerIP=1.2.3.4 | grep -E 'mqtt-metrics|port: 9234|port: 4195'`
Expected: both `metrics` (4195) and `mqtt-metrics` (9234) appear in Service ports and ServiceMonitor endpoints.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-ingester/templates/service.yaml helm/trakrf-ingester/templates/servicemonitor.yaml
git commit -m "feat(tra-828): expose mqtt-metrics (9234) on headless Service + ServiceMonitor"
```

---

## Task 9: Helm — cluster overlays

**Files:**
- Modify: `helm/trakrf-ingester/values-gke.yaml`
- Modify: `helm/trakrf-ingester/values-aks.yaml`
- Modify: `helm/trakrf-ingester/values-eks.yaml`

- [ ] **Step 1: Enable broker on GKE overlay**

Replace `helm/trakrf-ingester/values-gke.yaml` contents with:

```yaml
# GKE overlay — enables Mosquitto sidecar (TRA-828). Per-env hostname and
# loadBalancerIP are injected via the root chart's inlineValues (see
# argocd/root/templates/trakrf-ingester.yaml).
#
# clientId is also overridden per-env in the root chart for cross-env clarity
# (see feedback_mqtt_clientid_per_cluster). The base value here stays as the
# legacy GKE-wide id for any out-of-overlay test renders.
mqtt:
  clientId: trakrf-ingester-gke

broker:
  enabled: true

# GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM node pools
# (T2A/T2D/Axion). AKS Ubuntu does not. Toleration scoped to GKE overlays
# only — base and AKS/EKS values stay untouched. See TRA-470 and memory
# feedback_gke_arm_auto_taint.
tolerations:
  - key: kubernetes.io/arch
    operator: Equal
    value: arm64
    effect: NoSchedule
```

- [ ] **Step 2: Disable broker + replicas on AKS overlay**

Replace `helm/trakrf-ingester/values-aks.yaml` contents with:

```yaml
# AKS overlay — broker fan-out lives in the AKS-parity ticket (TRA-833) and
# isn't wired yet. Until then: broker disabled, ingester scaled to 0 so the
# rendered Deployment exists but no pod tries to connect to a non-existent
# broker. The trakrf-mqtt-credentials Secret is retired (TRA-828).
replicaCount: 0

mqtt:
  clientId: trakrf-ingester-aks

broker:
  enabled: false
```

- [ ] **Step 3: Disable broker + replicas on EKS overlay**

Replace `helm/trakrf-ingester/values-eks.yaml` contents with:

```yaml
# EKS overlay — currently burned down (TRA-381); broker fan-out lives in the
# EKS-parity ticket (TRA-832). Until then: broker disabled, ingester scaled
# to 0. See values-aks.yaml for the same rationale.
replicaCount: 0

mqtt:
  clientId: trakrf-ingester-eks

broker:
  enabled: false
```

- [ ] **Step 4: Render each cluster overlay to verify**

Run:
```bash
for c in gke aks eks; do
  echo "=== $c ==="
  helm template trakrf-ingester helm/trakrf-ingester \
    -f helm/trakrf-ingester/values.yaml \
    -f helm/trakrf-ingester/values-$c.yaml \
    --set broker.hostname=test-host \
    --set broker.loadBalancerIP=1.2.3.4 \
    | grep -E '^(kind|  name|replicas):' | head -20
done
```
Expected:
- `gke`: Deployment(replicas not set → defaults to 1 from base), Service (headless), Service (mqtt LB), ConfigMap (×2), Certificate, ServiceMonitor.
- `aks`/`eks`: Deployment with `replicas: 0`, headless Service, base ConfigMap, ServiceMonitor; no mqtt Service, no Certificate, no mosquitto ConfigMap.

- [ ] **Step 5: Commit**

```bash
git add helm/trakrf-ingester/values-gke.yaml helm/trakrf-ingester/values-aks.yaml helm/trakrf-ingester/values-eks.yaml
git commit -m "feat(tra-828): trakrf-ingester overlays — enable broker on GKE, scale-to-0 on AKS/EKS"
```

---

## Task 10: ArgoCD root — per-env broker hostname/IP/clientId

**Files:**
- Modify: `argocd/root/templates/trakrf-ingester.yaml`
- Modify: `argocd/root/values.yaml`

- [ ] **Step 1: Add placeholders to root values.yaml**

Append (or extend the GKE placeholder block):

```yaml

# TRA-828 — per-env MQTT broker LB IPs (Tofu-injected by scripts/apply-root-app.sh).
# Blank on non-GKE clusters; consumed by argocd/root/templates/trakrf-ingester.yaml
# to set per-env broker.loadBalancerIP. Hostname is computed per-env from a
# fixed `mqtt.{env}.gke.trakrf.id` template (no per-env placeholder needed).
mqttPreviewIp: ""
mqttProdIp: ""
```

- [ ] **Step 2: Extend per-env ingester Application inlineValues**

Replace `argocd/root/templates/trakrf-ingester.yaml` contents with:

```yaml
{{- /*
  One trakrf-ingester Application per env. Mirrors the trakrf-backend
  pattern — same per-env DB credentials, same trakrf-system DB host,
  same role override. The ingester has no migrate Job and no ingress.

  TRA-828: each env also gets its own broker hostname + LB IP injected
  here. On non-GKE clusters mqttPreviewIp/mqttProdIp are blank and the
  cluster overlay sets broker.enabled=false (values-aks.yaml /
  values-eks.yaml), so the unused broker.* values are harmless.
*/ -}}
{{- range $env := list "preview" "prod" }}
{{- $ipKey := printf "mqtt%sIp" (title $env) -}}
{{- $ip := index $.Values $ipKey | default "" -}}
{{- $values := printf "database:\n  name: trakrf_%s\n  user: trakrf-app-%s\n  credentialsSecret: trakrf-app-%s-credentials\n  host: trakrf-db-rw.trakrf-system\nmqtt:\n  clientId: trakrf-ingester-%s-%s\nbroker:\n  hostname: mqtt.%s.gke.trakrf.id\n  loadBalancerIP: %s\n" $env $env $env $.Values.cluster $env $env $ip }}
---
{{- include "trakrf.application" (dict
  "name" (printf "trakrf-ingester-%s" $env)
  "path" "helm/trakrf-ingester"
  "namespace" (printf "trakrf-%s" $env)
  "syncWave" "1"
  "cluster" $.Values.cluster
  "repoURL" $.Values.repoURL
  "targetRevision" $.Values.targetRevision
  "destination" $.Values.destination
  "inlineValues" $values
) }}
{{- end }}
```

- [ ] **Step 3: Render root chart to verify**

Run:
```bash
helm template trakrf-root argocd/root \
  --set cluster=gke \
  --set mqttPreviewIp=1.2.3.4 \
  --set mqttProdIp=5.6.7.8 \
  | grep -A 30 'name: trakrf-ingester-preview'
```
Expected: `inlineValues` contains `broker:` with `hostname: mqtt.preview.gke.trakrf.id`, `loadBalancerIP: 1.2.3.4`, and `mqtt.clientId: trakrf-ingester-gke-preview`.

Also verify cluster=aks renders blank-IP broker block (still harmless because overlay disables broker):
```bash
helm template trakrf-root argocd/root --set cluster=aks | grep -A 8 'name: trakrf-ingester-prod' | grep -E 'broker:|hostname:|loadBalancerIP:'
```
Expected: `hostname: mqtt.prod.gke.trakrf.id`, `loadBalancerIP:` empty. (Dead-letter values; overlay's `broker.enabled: false` gates everything that uses them.)

- [ ] **Step 4: Commit**

```bash
git add argocd/root/values.yaml argocd/root/templates/trakrf-ingester.yaml
git commit -m "feat(tra-828): per-env broker hostname/IP/clientId in trakrf-ingester Application"
```

---

## Task 11: Stakater Reloader Application

**Files:**
- Create: `argocd/root/templates/reloader.yaml`

- [ ] **Step 1: Create the Reloader Application (mirror reflector pattern)**

```yaml
# Stakater Reloader — bounces Deployments/StatefulSets when watched
# ConfigMaps/Secrets change. Opt-in via the `reloader.stakater.com/auto: "true"`
# pod-template annotation on the workload.
#
# Used for cert-manager Secret rotation (every ~60d) on the Mosquitto broker
# cert, and for broker auth Secret rotations. Mosquitto doesn't reliably pick
# up a new cert on SIGHUP, so a pod restart is the simple, durable fix.
#
# Distinct from emberstack/reflector (already installed) — Reflector copies
# Secrets across namespaces; Reloader restarts pods. Both live at sync wave -1.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: reloader
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: trakrf
  source:
    repoURL: https://stakater.github.io/stakater-charts
    chart: reloader
    targetRevision: "v1.4.7"
    helm:
      values: |
        reloader:
          {{- if eq .Values.cluster "gke" }}
          # GKE auto-applies kubernetes.io/arch=arm64:NoSchedule on T2A pools.
          # See memory feedback_gke_arm_auto_taint and TRA-470.
          deployment:
            tolerations:
              - key: kubernetes.io/arch
                operator: Equal
                value: arm64
                effect: NoSchedule
          {{- end }}
  destination:
    server: {{ .Values.destination.server }}
    namespace: reloader
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Render to verify**

Run: `helm template trakrf-root argocd/root --set cluster=gke | grep -A 25 'name: reloader$'`
Expected: Application with chart `reloader`, repo `stakater-charts`, GKE toleration block under `deployment.tolerations`.

Then render for cluster=aks: `helm template trakrf-root argocd/root --set cluster=aks | grep -A 12 'name: reloader$'`
Expected: same Application, no GKE toleration (and no `deployment:` block).

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/reloader.yaml
git commit -m "feat(tra-828): Stakater Reloader Application — restarts pods on Secret rotation"
```

---

## Task 12: `scripts/apply-root-app.sh` — inject per-env MQTT IPs

**Files:**
- Modify: `scripts/apply-root-app.sh`

- [ ] **Step 1: Add MQTT IP reads + helm flags**

Edit `scripts/apply-root-app.sh`:

(a) In the GKE case (around line 53), add after `LB_IP=$(tofu -chdir="$TF_DIR" output -raw traefik_lb_ip)`:

```bash
    MQTT_PREVIEW_IP=$(tofu -chdir="$TF_DIR" output -raw mqtt_preview_ip)
    MQTT_PROD_IP=$(tofu -chdir="$TF_DIR" output -raw mqtt_prod_ip)
```

(b) In every other case (`aks)`, `eks)`, `*)`), add after the matching `LB_IP=""` / `GCP_*` blocks:

```bash
    MQTT_PREVIEW_IP=""
    MQTT_PROD_IP=""
```

(c) Extend the helm command at the bottom with two new `--set` flags before `"${EXTRA_ARGS[@]}"`:

```bash
  --set mqttPreviewIp="$MQTT_PREVIEW_IP" \
  --set mqttProdIp="$MQTT_PROD_IP" \
```

- [ ] **Step 2: Lint with shellcheck**

Run: `shellcheck scripts/apply-root-app.sh` (if installed; skip if not)
Expected: no errors. Existing warnings (if any) acceptable; new code must add none.

- [ ] **Step 3: Dry-run the helm invocation (without state)**

Run: `bash -n scripts/apply-root-app.sh`
Expected: parses cleanly (exit 0).

- [ ] **Step 4: Commit**

```bash
git add scripts/apply-root-app.sh
git commit -m "feat(tra-828): apply-root-app.sh wires mqtt_preview_ip / mqtt_prod_ip from tofu"
```

---

## Task 13: `justfile` — `mosquitto-secrets` recipe + retire `ingester-secrets`

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Delete the old `ingester-secrets` recipe (lines ~126-135)**

Remove the entire block:

```
# Create trakrf-ingester MQTT secret from .env.local (idempotent).
# Run against the active kube context BEFORE argocd-bootstrap — or any time
# after, followed by `kubectl rollout restart deployment/trakrf-ingester -n trakrf`.
ingester-secrets:
    @kubectl create namespace trakrf --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${MQTT_URL:-}" || { echo "ERROR: MQTT_URL not set in .env.local"; exit 1; }
    @kubectl create secret generic trakrf-mqtt-credentials -n trakrf \
      --from-literal=MQTT_URL="${MQTT_URL}" \
      --dry-run=client -o yaml | kubectl apply -f -
    @echo "MQTT secret applied (or unchanged). Ingester will pick it up on next rollout."
```

- [ ] **Step 2: Add the new `mosquitto-secrets` recipe**

Insert (in roughly the same spot as the deleted recipe, after `db-secrets`):

```make
# Create the Mosquitto broker auth Secret in trakrf-system with reflector
# annotations so it mirrors into trakrf-preview / trakrf-prod. Run BEFORE the
# trakrf-ingester pods come up — they mount this Secret for the loopback
# password_file + the ingester/exporter env credentials.
#
# Requires in .env.local:
#   MOSQUITTO_USER       e.g. trakrf-ingester
#   MOSQUITTO_PASSWORD   generate with `openssl rand -hex 32`
#                        (base64 has /+ which breaks URL-composed DSNs;
#                        see feedback_db_password_alphabet)
#
# Idempotent. Re-running rotates the Secret; Stakater Reloader bounces both
# env pods automatically (the trakrf-ingester Deployment carries the
# `reloader.stakater.com/auto: "true"` annotation).
mosquitto-secrets:
    @kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${MOSQUITTO_USER:-}" || { echo "ERROR: MOSQUITTO_USER not set in .env.local"; exit 1; }
    @test -n "${MOSQUITTO_PASSWORD:-}" || { echo "ERROR: MOSQUITTO_PASSWORD not set in .env.local"; exit 1; }
    @# Use a throwaway eclipse-mosquitto container so we don't depend on a host
    @# mosquitto_passwd binary. Writes the hashed password_file to stdout, then
    @# folds it into a Secret alongside literal username/password for ingester
    @# + exporter env wiring.
    @PASSWD_FILE=$(docker run --rm eclipse-mosquitto:2.0.21 sh -c \
      "mosquitto_passwd -b -c /tmp/passwd '${MOSQUITTO_USER}' '${MOSQUITTO_PASSWORD}' >/dev/null && cat /tmp/passwd") && \
     kubectl create secret generic trakrf-mosquitto-auth -n trakrf-system \
       --from-literal=passwd="$$PASSWD_FILE" \
       --from-literal=username="${MOSQUITTO_USER}" \
       --from-literal=password="${MOSQUITTO_PASSWORD}" \
       --dry-run=client -o yaml | kubectl apply -f -
    @kubectl annotate --overwrite secret trakrf-mosquitto-auth -n trakrf-system \
      reflector.v1.k8s.emberstack.com/reflection-allowed=true \
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-preview,trakrf-prod
    @echo "Mosquitto auth Secret applied. Reflector mirrors to trakrf-{preview,prod}."
```

- [ ] **Step 3: Verify `just --list` parses**

Run: `just --list | grep -E 'mosquitto-secrets|ingester-secrets'`
Expected: `mosquitto-secrets` present; `ingester-secrets` absent.

- [ ] **Step 4: Commit**

```bash
git add justfile
git commit -m "feat(tra-828): mosquitto-secrets recipe; retire ingester-secrets"
```

---

## Task 14: `.env.local.sample` + README updates

**Files:**
- Modify: `.env.local.sample` (may or may not exist; check first)
- Modify: `README.md`

- [ ] **Step 1: Inspect `.env.local.sample`**

Run: `ls -la .env.local.sample 2>/dev/null || echo "absent"`

If absent, create it with at minimum:

```
# Mosquitto broker auth (TRA-828) — consumed by `just mosquitto-secrets`.
# Generate password with: openssl rand -hex 32
# (avoid base64; /+ break URL-composed DSNs, see feedback_db_password_alphabet)
MOSQUITTO_USER=trakrf-ingester
MOSQUITTO_PASSWORD=
```

If present, ensure these two lines exist and any `MQTT_URL=` line is removed.

- [ ] **Step 2: Update README.md**

Search and replace in `README.md`:
- `just ingester-secrets` → `just mosquitto-secrets`
- Any narrative mentioning `MQTT_URL` or `trakrf-mqtt-credentials` should be updated to reference `MOSQUITTO_USER`/`MOSQUITTO_PASSWORD` and the new auth Secret.

Confirm with: `grep -n "ingester-secrets\|MQTT_URL\|trakrf-mqtt-credentials" README.md`
Expected: no matches after edit.

- [ ] **Step 3: Check helm/README.md and any other docs**

Run: `grep -rln "ingester-secrets\|MQTT_URL\|trakrf-mqtt-credentials" helm/ docs/ argocd/ 2>/dev/null`
Update any hits the same way (preserve historical spec doc mentions if they are historical context — but README/operator docs should be current).

- [ ] **Step 4: Commit**

```bash
git add .env.local.sample README.md helm/README.md
git commit -m "docs(tra-828): README + .env.local.sample — mosquitto-secrets workflow"
```

(Adjust `git add` to only include files that actually changed.)

---

## Task 15: Full render + diff smoke (pre-PR)

This is the consolidated check before opening the PR. No code changes; just verification.

- [ ] **Step 1: Render every cluster overlay**

Run:
```bash
for c in aks eks gke; do
  echo "=== $c ==="
  helm template trakrf-root argocd/root --set cluster=$c \
    --set mqttPreviewIp=1.2.3.4 --set mqttProdIp=5.6.7.8 \
    > /tmp/trakrf-root-$c.yaml 2>&1 || echo "ERROR rendering $c"
  wc -l /tmp/trakrf-root-$c.yaml
done
```
Expected: all three render, no errors, non-zero line counts.

- [ ] **Step 2: Sanity-grep for required artifacts in GKE render**

Run:
```bash
grep -cE 'kind: (Certificate|ConfigMap|Service|Deployment|Application)' /tmp/trakrf-root-gke.yaml
grep -cE 'trakrf-ingester-(preview|prod)|trakrf-mosquitto-auth|trakrf-mqtt-tls|mqtt.preview.gke.trakrf.id|mqtt.prod.gke.trakrf.id|reloader' /tmp/trakrf-root-gke.yaml
```
Expected: non-zero counts for both. The second grep should show the per-env hostnames and Reloader Application.

- [ ] **Step 3: Confirm no stale references**

Run:
```bash
grep -nE 'trakrf-mqtt-credentials|ingester-secrets|MQTT_URL.*secretKeyRef' /tmp/trakrf-root-gke.yaml || echo "clean"
```
Expected: `clean` (no matches).

- [ ] **Step 4: tofu fmt across the GCP module**

Run: `tofu -chdir=terraform/gcp fmt -check -diff`
Expected: clean.

- [ ] **Step 5: Commit anything residual / amend pass**

If steps 1-4 surface a problem, fix it and add a follow-up commit; do not amend prior commits.

---

## Task 16: Open PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin miks2u/tra-828-self-hosted-mosquitto-broker-on-gke-off-emqx-cloud
```

- [ ] **Step 2: Open PR via `gh pr create`**

Title: `feat(tra-828): self-hosted Mosquitto broker on GKE (off EMQX Cloud)`

Body sections:
- **Summary** — bullet list of what changed (per-env broker sidecars, cert-manager Certs, LB Services, Reloader Application, secrets workflow).
- **Out-of-band steps for the operator** (mirrors the "Apply ordering" in the spec):
  1. `tofu -chdir=terraform/gcp apply`
  2. `just mosquitto-secrets` (after setting `MOSQUITTO_USER`/`MOSQUITTO_PASSWORD` in `.env.local`)
  3. `scripts/apply-root-app.sh gke`
- **Test plan**:
  - [ ] `tofu plan` clean
  - [ ] ArgoCD shows new ingester pods Healthy (3/3 containers per env)
  - [ ] cert-manager Certs `trakrf-ingester-{preview,prod}-mqtt` are Ready
  - [ ] LB Services have external IPs matching `mqtt_preview_ip`/`mqtt_prod_ip`
  - [ ] `scripts/smoke-broker.sh -h mqtt.preview.gke.trakrf.id -u "$MOSQUITTO_USER" -P "$MOSQUITTO_PASSWORD"` passes
  - [ ] Same for `mqtt.prod.gke.trakrf.id`
  - [ ] `kubectl exec` into `mosquitto-exporter` and `curl localhost:9234/metrics` shows `mosquitto_*` series
  - [ ] After device repoint, fresh rows in `trakrf_preview.trakrf.identifier_scans` (sanity, not a gate)

Do not include `TRA-828` in the PR body per `feedback_no_ticket_refs_in_public_docs` — but commit messages already carry it (these are also public; spec says the convention is no ticket refs in public docs — confirm with `git log origin/main --oneline | head -3` whether the repo is using `feat(tra-XXX):` commits publicly today). If commits in `main` already use the `feat(tra-XXX):` style, keep using it; that's the established norm here.

- [ ] **Step 3: Print PR URL**

`gh pr view --web` (or just print the URL).

---

## Self-Review Checklist

Run mentally after Task 15:

- [ ] Every spec section maps to a task. Per-env broker (Tasks 1, 2, 3, 4, 6, 7, 10) ✓ — auth (Task 13) ✓ — cert + DNS (Tasks 1, 2, 7, plus existing TRA-829) ✓ — Reloader (Task 11) ✓ — secrets workflow (Tasks 13, 14) ✓ — apply-root-app wiring (Task 12) ✓ — metrics (Task 8) ✓ — cluster overlays (Task 9) ✓.
- [ ] No placeholders. Every code block is concrete.
- [ ] Type consistency: `broker.authSecret` (not `mqtt.credentialsSecret`) used throughout; `broker.hostname` / `broker.loadBalancerIP` consistent in values, deployment, service, certificate, root chart.
- [ ] Mosquitto data dir: emptyDir → `/mosquitto/data` to satisfy `persistence_location` even when `persistence false`.
- [ ] mqtt-metrics name matches between Deployment containerPort (Task 4), Service port (Task 8), ServiceMonitor endpoint (Task 8) — ✓ `mqtt-metrics`.
