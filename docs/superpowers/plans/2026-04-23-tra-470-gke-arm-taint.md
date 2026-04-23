# TRA-470 — GKE ARM Arch-Taint Tolerations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `kubernetes.io/arch=arm64:NoSchedule` tolerations to every GKE workload so a fresh `just gcp` + `just argocd-bootstrap gke` + root-app sync needs no manual `kubectl taint` step.

**Architecture:** Per-workload tolerations declared in each chart's `values-gke.yaml` overlay (or the GKE branch of `argocd/root/templates/*.yaml` inline helm.values for upstream charts wired through the root-app). Strictly scoped to GKE — AKS/EKS overlays and base `values.yaml` files are not touched. Identical canonical toleration block reused across eight sites.

**Tech Stack:** Helm values YAML, ArgoCD Applications with inline helm.values, Kubernetes pod tolerations, CNPG Cluster `spec.affinity.tolerations`, `kube-prometheus-stack`, `argo-cd`, `cloudnative-pg`, `jetstack/cert-manager`, `traefik/traefik` Helm charts.

**Canonical toleration block** (identical in every site):

```yaml
tolerations:
  - key: kubernetes.io/arch
    operator: Equal
    value: arm64
    effect: NoSchedule
```

**Canonical header comment** (adapt the first line slightly per file when appending to existing comments):

```yaml
# GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM node pools
# (T2A/T2D/Axion). AKS Ubuntu does not. Toleration scoped to GKE overlays
# only — base and AKS/EKS values stay untouched. See TRA-470 and memory
# feedback_gke_arm_auto_taint.
```

**Spec reference:** `docs/superpowers/specs/2026-04-23-tra-470-gke-arm-taint-design.md`

**Working branch:** `miks2u/tra-470-gke-arm-arch-taint-terraform-level-suppression` (already checked out; spec already committed as `ad662b9`).

---

## File Structure

Eight target files, grouped by placement mechanism:

**Category A — project charts with `.Values.tolerations` already plumbed through templates:**
- `helm/trakrf-backend/values-gke.yaml` (Task 1)
- `helm/trakrf-ingester/values-gke.yaml` (Task 2)
- `helm/trakrf-db/values-gke.yaml` (Task 3) — CNPG Cluster via `affinity.tolerations`

**Category C — upstream charts configured via local values-gke.yaml overlay:**
- `helm/cnpg/values-gke.yaml` (Task 4) — `cnpg/cloudnative-pg` operator
- `helm/monitoring/values-gke.yaml` (Task 5) — `prometheus-community/kube-prometheus-stack` (five subcomponents)
- `argocd/bootstrap/values-gke.yaml` (Task 6) — `argo/argo-cd` (five subcomponents; dex + notifications disabled in base values)

**Category B — upstream charts configured via `argocd/root` inline `helm.values`:**
- `argocd/root/templates/cert-manager.yaml` (Task 7) — extend existing `{{- else if eq .Values.cluster "gke" }}` branch
- `argocd/root/templates/traefik.yaml` (Task 8) — extend existing `{{- else if eq .Values.cluster "gke" }}` branch

**Category D — validation (no files edited):**
- Live-cluster re-taint + bounce (Task 9)

Tasks 1–8 each produce one file change and one commit. Task 9 is validation and produces no commit in this repo (evidence captured in PR description).

---

## Task 1: trakrf-backend GKE overlay

**Files:**
- Modify: `helm/trakrf-backend/values-gke.yaml`

**Context:** Chart's `templates/deployment.yaml` already emits `tolerations` from `{{- with .Values.tolerations }}` (verified at `helm/trakrf-backend/templates/deployment.yaml:80-83`). Base `values.yaml:103` sets `tolerations: []`. Top-level `tolerations:` in the overlay overrides.

- [ ] **Step 1: Read the current overlay to preserve existing content**

Read `helm/trakrf-backend/values-gke.yaml` so you have the current comment header and the `image.tag` / `ingress.host` values in mind.

- [ ] **Step 2: Append the toleration block and rationale comment to the overlay**

Full expected file contents after edit:

```yaml
# GKE overrides for trakrf-backend.
# Pinned to the trakrf/platform main commit sha-a99b5b8 (same tag as AKS).
# PR #190 switched CI to an ARM-native runner and dropped amd64 from main-
# branch builds — the image is linux/arm64-native, which matches GKE's
# t2a-standard-4 (ARM Ampere) primary node.

image:
  tag: sha-a99b5b8

ingress:
  host: gke.trakrf.app

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

- [ ] **Step 3: Render the chart with the overlay and verify the toleration appears on the Deployment pod spec**

Run:

```bash
helm template trakrf-backend ./helm/trakrf-backend \
  -f helm/trakrf-backend/values.yaml \
  -f helm/trakrf-backend/values-gke.yaml \
  --set image.tag=sha-a99b5b8 \
  | grep -A5 'tolerations:'
```

Expected output includes:

```
      tolerations:
        - effect: NoSchedule
          key: kubernetes.io/arch
          operator: Equal
          value: arm64
```

If `helm template` errors on missing required values (e.g., secrets), pass `--set` flags for required fields or use `--skip-tests` / `--skip-schema-validation` as needed. The only thing that must be true is the toleration block appears in the rendered Deployment.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-backend/values-gke.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): trakrf-backend GKE ARM toleration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: trakrf-ingester GKE overlay

**Files:**
- Modify: `helm/trakrf-ingester/values-gke.yaml`

**Context:** Same scaffold as backend — chart's `templates/deployment.yaml:81-83` emits `tolerations` from `{{- with .Values.tolerations }}`. Base `values.yaml:74` sets `tolerations: []`.

- [ ] **Step 1: Read the current overlay**

Existing file contents to preserve:

```yaml
# GKE overlay — distinct MQTT clientId so GKE doesn't collide with Railway
# prod or other cluster ingesters on the shared EMQX Cloud broker (MQTT
# evicts duplicate clientId sessions, producing reconnect flap). One-line
# tweak per overlay; base `trakrf-ingester` default stays intact for any
# bare helm install without a cluster overlay.
mqtt:
  clientId: trakrf-ingester-gke
```

- [ ] **Step 2: Append toleration block and rationale comment**

Full expected file contents after edit:

```yaml
# GKE overlay — distinct MQTT clientId so GKE doesn't collide with Railway
# prod or other cluster ingesters on the shared EMQX Cloud broker (MQTT
# evicts duplicate clientId sessions, producing reconnect flap). One-line
# tweak per overlay; base `trakrf-ingester` default stays intact for any
# bare helm install without a cluster overlay.
mqtt:
  clientId: trakrf-ingester-gke

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

- [ ] **Step 3: Render and verify**

Run:

```bash
helm template trakrf-ingester ./helm/trakrf-ingester \
  -f helm/trakrf-ingester/values.yaml \
  -f helm/trakrf-ingester/values-gke.yaml \
  | grep -A5 'tolerations:'
```

Expected output contains the arm64 toleration block on the Deployment.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-ingester/values-gke.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): trakrf-ingester GKE ARM toleration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: trakrf-db (CNPG Cluster) GKE overlay

**Files:**
- Modify: `helm/trakrf-db/values-gke.yaml`

**Context:** The chart's `templates/cluster.yaml:54-64` emits `spec.affinity.tolerations` on the CNPG Cluster from `.Values.affinity.tolerations`. Base `values.yaml:64` has `tolerations: []` inside an `affinity:` block. Current overlay has `storage.class: premium-rwo` and a comment saying "affinity intentionally empty" — replace that comment.

- [ ] **Step 1: Read the current overlay**

Existing file contents:

```yaml
# GKE topology: single t2a-standard-4 on-demand primary node runs everything
# (DB + app + platform). No separate DB pool, no affinity — the scheduler
# picks the only available node. Storage: premium-rwo (pd-ssd) for IOPS
# headroom over the standard-rwo (pd-balanced) default.

storage:
  class: premium-rwo

# affinity intentionally empty — inherits defaults (nodeSelector {}, tolerations [])
```

- [ ] **Step 2: Replace the overlay with the updated content**

Full expected file contents after edit:

```yaml
# GKE topology: single t2a-standard-4 on-demand primary node runs everything
# (DB + app + platform). No separate DB pool, no nodeSelector — the scheduler
# picks the only available node. Storage: premium-rwo (pd-ssd) for IOPS
# headroom over the standard-rwo (pd-balanced) default.

storage:
  class: premium-rwo

# GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM node pools
# (T2A/T2D/Axion). AKS Ubuntu does not. CNPG Cluster needs the toleration
# on spec.affinity.tolerations. Scoped to GKE overlay only. See TRA-470
# and memory feedback_gke_arm_auto_taint.
affinity:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule
```

- [ ] **Step 3: Render and verify the toleration appears under `spec.affinity.tolerations` on the CNPG Cluster**

Run:

```bash
helm template trakrf-db ./helm/trakrf-db \
  -f helm/trakrf-db/values.yaml \
  -f helm/trakrf-db/values-gke.yaml \
  | grep -B1 -A6 'tolerations:'
```

Expected output shows `tolerations:` nested under `affinity:` under `spec:` on the `Cluster` object, with the arm64 entry.

- [ ] **Step 4: Commit**

```bash
git add helm/trakrf-db/values-gke.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): trakrf-db CNPG Cluster GKE ARM toleration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: cnpg operator GKE overlay

**Files:**
- Modify: `helm/cnpg/values-gke.yaml`

**Context:** Upstream `cnpg/cloudnative-pg` chart installs the CNPG operator Deployment. Chart's values schema has top-level `tolerations:` for the operator pod spec. Base `helm/cnpg/values.yaml` does not set tolerations. Overlay is currently a scaffold-only comment. Installed via `just cnpg-bootstrap gke` (see `justfile:79-88`).

- [ ] **Step 1: Read the current overlay**

Existing file contents:

```yaml
# GKE overrides for CNPG operator — none today. Single-pool topology,
# no special scheduling. Scaffold kept for uniform `just cnpg-bootstrap
# <cluster>` argument handling.
```

- [ ] **Step 2: Replace the overlay with operator toleration**

Full expected file contents after edit:

```yaml
# GKE overrides for CNPG operator. Single-pool topology, no special
# scheduling beyond the ARM taint toleration.
#
# GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM node pools
# (T2A/T2D/Axion). AKS Ubuntu does not. Toleration scoped to GKE overlay
# only — base and AKS/EKS values stay untouched. See TRA-470 and memory
# feedback_gke_arm_auto_taint.
tolerations:
  - key: kubernetes.io/arch
    operator: Equal
    value: arm64
    effect: NoSchedule
```

- [ ] **Step 3: Render and verify the operator Deployment has the toleration**

Run:

```bash
helm template cnpg cnpg/cloudnative-pg \
  -f helm/cnpg/values.yaml \
  -f helm/cnpg/values-gke.yaml \
  | grep -A5 'tolerations:'
```

If `helm repo add cnpg https://cloudnative-pg.github.io/charts` has not been run, do so first (the bootstrap recipe does it; local repo state may vary). Expected: one `tolerations:` block on the operator Deployment with the arm64 entry.

- [ ] **Step 4: Commit**

```bash
git add helm/cnpg/values-gke.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): cnpg operator GKE ARM toleration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: kube-prometheus-stack GKE overlay

**Files:**
- Modify: `helm/monitoring/values-gke.yaml`

**Context:** Upstream `prometheus-community/kube-prometheus-stack` deploys five pod-generating subcomponents; all five need tolerations. Installed via `just monitoring-bootstrap gke` (see `justfile:154-177`). Chart structure:
- `prometheus.prometheusSpec.tolerations` — Prometheus StatefulSet (managed by operator)
- `alertmanager.alertmanagerSpec.tolerations` — Alertmanager StatefulSet (managed by operator)
- `grafana.tolerations` — Grafana Deployment
- `prometheusOperator.tolerations` — the operator itself
- `kube-state-metrics.tolerations` — subchart (hyphenated key)
- `prometheus-node-exporter.tolerations` — subchart DaemonSet (hyphenated key)

- [ ] **Step 1: Read the current overlay**

Existing file contents:

```yaml
# helm/monitoring/values-gke.yaml
# GKE-specific monitoring overrides — premium-rwo storage + GKE Grafana host

prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: premium-rwo

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: premium-rwo

grafana:
  persistence:
    storageClassName: premium-rwo
  grafana.ini:
    server:
      domain: grafana.gke.trakrf.app
      root_url: https://grafana.gke.trakrf.app
```

- [ ] **Step 2: Add toleration blocks to all six subcomponent keys**

Full expected file contents after edit:

```yaml
# helm/monitoring/values-gke.yaml
# GKE-specific monitoring overrides — premium-rwo storage + GKE Grafana host +
# per-subcomponent ARM tolerations (GKE auto-taints ARM pools; AKS does not).
# See TRA-470 and memory feedback_gke_arm_auto_taint.

prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: premium-rwo
    tolerations:
      - key: kubernetes.io/arch
        operator: Equal
        value: arm64
        effect: NoSchedule

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: premium-rwo
    tolerations:
      - key: kubernetes.io/arch
        operator: Equal
        value: arm64
        effect: NoSchedule

grafana:
  persistence:
    storageClassName: premium-rwo
  grafana.ini:
    server:
      domain: grafana.gke.trakrf.app
      root_url: https://grafana.gke.trakrf.app
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule

prometheusOperator:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule

kube-state-metrics:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule

prometheus-node-exporter:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule
```

- [ ] **Step 3: Render and verify all six subcomponents carry the toleration**

Run:

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -f helm/monitoring/values.yaml \
  -f helm/monitoring/values-gke.yaml \
  | grep -B2 -A5 'arm64'
```

Expected output: multiple `tolerations:` blocks, each followed by the arm64 entry. Visually confirm the blocks appear on Deployments/StatefulSets/DaemonSets named `kube-prometheus-stack-prometheus-operator`, `kube-prometheus-stack-grafana`, `kube-state-metrics`, `kube-prometheus-stack-prometheus-node-exporter`, and on the Prometheus/Alertmanager CRs (the operator applies them to the generated StatefulSets).

If `prometheus-community` Helm repo isn't added locally, run `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update prometheus-community` first.

- [ ] **Step 4: Commit**

```bash
git add helm/monitoring/values-gke.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): kube-prometheus-stack GKE ARM tolerations

Added on all six pod-generating subcomponents: prometheus,
alertmanager, grafana, prometheusOperator, kube-state-metrics,
prometheus-node-exporter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: argocd bootstrap GKE overlay

**Files:**
- Modify: `argocd/bootstrap/values-gke.yaml`

**Context:** Upstream `argo/argo-cd` chart ~9.5 (see `argocd/bootstrap/values.yaml:2`). Installed via `just argocd-bootstrap gke` (see `justfile:119-134`). Base values disable `dex` (`values.yaml:56-57`) and `notifications` (`values.yaml:59-60`), so those do NOT need tolerations. The five subcomponents that DO deploy pods are:
- `controller.tolerations` — application-controller StatefulSet
- `server.tolerations` — argocd-server Deployment
- `repoServer.tolerations` — repo-server Deployment
- `applicationSet.tolerations` — applicationset-controller Deployment
- `redis.tolerations` — redis Deployment

- [ ] **Step 1: Read the current overlay**

Existing file contents:

```yaml
# GKE overlay — no cluster-specific overrides for ArgoCD bootstrap.
# ArgoCD itself does not need GCP API access (no Workload Identity SA
# binding). Scaffold kept for uniform `just argocd-bootstrap <cluster>`
# argument handling.
```

- [ ] **Step 2: Replace the overlay with per-subcomponent tolerations**

Full expected file contents after edit:

```yaml
# GKE overlay. ArgoCD itself needs the ARM taint toleration on every
# deployed subcomponent so it can come up on a fresh GKE cluster before
# any user-workload reconciliation happens. dex + notifications are
# disabled in the base values, so we only cover the five subcomponents
# that actually schedule pods.
#
# GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM node pools
# (T2A/T2D/Axion). AKS Ubuntu does not. See TRA-470 and memory
# feedback_gke_arm_auto_taint.

controller:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule

server:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule

repoServer:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule

applicationSet:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule

redis:
  tolerations:
    - key: kubernetes.io/arch
      operator: Equal
      value: arm64
      effect: NoSchedule
```

- [ ] **Step 3: Render and verify all five argocd subcomponents carry the toleration**

Run:

```bash
helm template argocd argo/argo-cd \
  -f argocd/bootstrap/values.yaml \
  -f argocd/bootstrap/values-gke.yaml \
  | grep -B2 -A5 'arm64'
```

Expected: five `tolerations:` blocks with the arm64 entry, on the application-controller StatefulSet, argocd-server Deployment, argocd-repo-server Deployment, argocd-applicationset-controller Deployment, and argocd-redis Deployment. No tolerations on dex or notifications pods (they should not appear at all).

If `argo` Helm repo isn't added locally, run `helm repo add argo https://argoproj.github.io/argo-helm && helm repo update argo` first.

- [ ] **Step 4: Commit**

```bash
git add argocd/bootstrap/values-gke.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): argocd bootstrap GKE ARM tolerations

Covers controller, server, repoServer, applicationSet, redis.
dex and notifications are disabled in base values.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: cert-manager GKE branch in argocd/root

**Files:**
- Modify: `argocd/root/templates/cert-manager.yaml`

**Context:** Upstream `jetstack/cert-manager` chart deploys four pod-generating components: `cert-manager` itself, `webhook`, `cainjector`, and `startupapicheck` (a Job). All four chart subkeys accept `tolerations:`. The template at `argocd/root/templates/cert-manager.yaml:33-39` already has a `{{- else if eq .Values.cluster "gke" }}` branch setting the `serviceAccount.annotations` for GKE Workload Identity. Extend that branch with tolerations for all four subcomponents.

- [ ] **Step 1: Read the current template**

Existing `argocd/root/templates/cert-manager.yaml` — focus on the helm.values block lines 19-39.

- [ ] **Step 2: Extend the GKE branch to include tolerations**

Locate this block (lines 33-39):

```yaml
        {{- else if eq .Values.cluster "gke" }}
        # GKE Workload Identity — K8s SA annotation is the only wiring;
        # no pod labels or podIdentity equivalent needed.
        serviceAccount:
          annotations:
            iam.gke.io/gcp-service-account: {{ .Values.certManagerGcpServiceAccountEmail | quote }}
        {{- end }}
```

Replace it with:

```yaml
        {{- else if eq .Values.cluster "gke" }}
        # GKE Workload Identity — K8s SA annotation is the only wiring;
        # no pod labels or podIdentity equivalent needed.
        serviceAccount:
          annotations:
            iam.gke.io/gcp-service-account: {{ .Values.certManagerGcpServiceAccountEmail | quote }}
        # GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM pools;
        # AKS Ubuntu does not. See TRA-470. Tolerations on all four pod-
        # generating cert-manager subcomponents.
        tolerations:
          - key: kubernetes.io/arch
            operator: Equal
            value: arm64
            effect: NoSchedule
        webhook:
          tolerations:
            - key: kubernetes.io/arch
              operator: Equal
              value: arm64
              effect: NoSchedule
        cainjector:
          tolerations:
            - key: kubernetes.io/arch
              operator: Equal
              value: arm64
              effect: NoSchedule
        startupapicheck:
          tolerations:
            - key: kubernetes.io/arch
              operator: Equal
              value: arm64
              effect: NoSchedule
        {{- end }}
```

- [ ] **Step 3: Render the root chart to confirm the GKE branch produces the expected helm.values string**

Run:

```bash
helm template argocd-root ./argocd/root \
  -f argocd/root/values-gke.yaml \
  2>/dev/null | sed -n '/name: cert-manager/,/^---/p'
```

Expected: the rendered `Application` object's `spec.source.helm.values` block (a string) contains the four `tolerations:` blocks — one top-level, plus `webhook.tolerations`, `cainjector.tolerations`, `startupapicheck.tolerations`, each with the arm64 entry. The `serviceAccount.annotations.iam.gke.io/gcp-service-account:` line should still be present above the tolerations.

If `argocd/root/values-gke.yaml` doesn't exist in the repo as a selectable file (the root chart's values may come from a different source), fall back to visually diffing the template change against the spec and verify via the live cluster sync in Task 9.

- [ ] **Step 4: Commit**

```bash
git add argocd/root/templates/cert-manager.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): cert-manager GKE ARM tolerations in argocd root template

Extends the existing GKE branch of the inline helm.values to
set tolerations on cert-manager, webhook, cainjector, and
startupapicheck subcomponents.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: traefik GKE branch in argocd/root

**Files:**
- Modify: `argocd/root/templates/traefik.yaml`

**Context:** Upstream `traefik/traefik` chart ~39 deploys a single Traefik Deployment. Toleration key is `deployment.tolerations:` (under the `deployment:` block). The template at `argocd/root/templates/traefik.yaml:37-41` already has a `{{- else if eq .Values.cluster "gke" }}` branch setting `service.spec.loadBalancerIP`. Extend that branch with the deployment toleration.

- [ ] **Step 1: Read the current template**

Focus on the helm.values block around lines 19-41.

- [ ] **Step 2: Extend the GKE branch to include `deployment.tolerations`**

Locate this block (lines 37-41):

```yaml
        {{- else if eq .Values.cluster "gke" }}
        service:
          spec:
            loadBalancerIP: {{ .Values.traefikLbIp | quote }}
        {{- end }}
```

Replace it with:

```yaml
        {{- else if eq .Values.cluster "gke" }}
        service:
          spec:
            loadBalancerIP: {{ .Values.traefikLbIp | quote }}
        # GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM pools;
        # AKS Ubuntu does not. See TRA-470.
        deployment:
          tolerations:
            - key: kubernetes.io/arch
              operator: Equal
              value: arm64
              effect: NoSchedule
        {{- end }}
```

Note: the top-level `deployment.replicas` in the non-conditional block already exists (line 21). Traefik's Helm schema merges conditional `deployment:` values with the top-level one, so adding `deployment.tolerations` in the GKE branch does not conflict with `deployment.replicas` set outside the conditional. If `helm template` flags this, promote both the existing `deployment.replicas` and the new `deployment.tolerations` into the single `deployment:` block inside the GKE branch (and do the symmetric thing for AKS via another branch) — but test step 3 first before restructuring.

- [ ] **Step 3: Render the root chart to verify the traefik Application has the toleration**

Run:

```bash
helm template argocd-root ./argocd/root \
  -f argocd/root/values-gke.yaml \
  2>/dev/null | sed -n '/name: traefik/,/^---/p'
```

Expected: the `spec.source.helm.values` string contains `deployment:` with both `replicas: 2` (from top-level) and `tolerations:` with the arm64 entry (from GKE branch). If YAML merging surfaces a problem, restructure per the note in Step 2.

- [ ] **Step 4: Commit**

```bash
git add argocd/root/templates/traefik.yaml
git commit -m "$(cat <<'EOF'
feat(tra-470): traefik GKE ARM toleration in argocd root template

Extends the existing GKE branch of inline helm.values to set
deployment.tolerations on the traefik Deployment.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Live-cluster validation (re-taint + bounce)

**Files:** none modified.

**Context:** With all eight files committed and pushed, argocd reconciles the new overlay values. Validate that every covered workload tolerates the ARM taint by restoring the taint on the primary node and bouncing each workload. Capture the evidence for the PR description.

- [ ] **Step 1: Push branch and wait for argocd sync**

Run:

```bash
git push -u origin miks2u/tra-470-gke-arm-arch-taint-terraform-level-suppression
```

Then wait for argocd to reconcile. For root-app-managed charts (cert-manager, traefik), trigger a sync manually if needed (argocd CLI or UI). For `just argocd-bootstrap gke`, `just cnpg-bootstrap gke`, and `just monitoring-bootstrap gke` — these are direct helm installs, NOT managed by argocd. To land the new overlay values you must re-run the bootstrap recipes:

```bash
just argocd-bootstrap gke
just cnpg-bootstrap gke
just monitoring-bootstrap gke
```

Each is an `helm upgrade --install` that is idempotent and rolls pods only for specs that changed.

Verify all Applications Synced + Healthy:

```bash
kubectl get applications -n argocd
```

(The `argocd` self-app will show cosmetic OutOfSync — this is expected, see memory `feedback_argocd_self_app_outofsync`. Every other app must be Synced + Healthy.)

- [ ] **Step 2: Baseline — confirm no taint currently on the node**

Run:

```bash
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, taints: .spec.taints}'
```

Expected: the ARM taint is absent (was manually removed during TRA-461). Note the primary node name — you'll need it in the next step. Call it `<NODE>`.

- [ ] **Step 3: Re-apply the ARM taint to restore the fresh-cluster condition**

Run:

```bash
kubectl taint node <NODE> kubernetes.io/arch=arm64:NoSchedule
```

Verify:

```bash
kubectl get node <NODE> -o json | jq '.spec.taints'
```

Expected: array contains `{key: "kubernetes.io/arch", value: "arm64", effect: "NoSchedule"}`.

- [ ] **Step 4: Bounce all covered workloads**

Run each block and wait for rollout to succeed:

```bash
# argocd components
kubectl rollout restart statefulset/argocd-application-controller -n argocd
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart deployment/argocd-applicationset-controller -n argocd
kubectl rollout restart deployment/argocd-redis -n argocd

# cert-manager
kubectl rollout restart deployment -n cert-manager

# traefik
kubectl rollout restart deployment -n traefik

# CNPG operator
kubectl rollout restart deployment/cnpg-cloudnative-pg -n cnpg-system

# trakrf apps
kubectl rollout restart deployment/trakrf-backend -n trakrf
kubectl rollout restart deployment/trakrf-ingester -n trakrf

# CNPG primary pod (forces reschedule)
kubectl delete pod -l cnpg.io/cluster=trakrf-db -n trakrf

# monitoring stack
kubectl rollout restart statefulset -n monitoring
kubectl rollout restart deployment -n monitoring
kubectl rollout restart daemonset -n monitoring
```

If exact resource names differ from the list above, adjust (use `kubectl get deploy,sts,ds -A` to enumerate). The point is to force every pod covered by the eight overlay files to re-schedule under the taint.

- [ ] **Step 5: Verify nothing is Pending**

Run:

```bash
kubectl get pods -A --field-selector=status.phase=Pending
```

Expected output:

```
No resources found
```

Also run:

```bash
kubectl get pods -A -o wide | grep -v Running
```

Expected: only the header line and any Completed Jobs. No Pending, no ImagePullBackOff from scheduling.

If any pod is Pending with `FailedScheduling: 0/1 nodes are available: 1 node(s) had untolerated taint(s)`, identify the chart/component and return to its task to add the missing toleration key, then re-run this validation.

- [ ] **Step 6: Run smoke**

Run:

```bash
just smoke-gke
```

Expected: exits 0 with all smoke checks green.

- [ ] **Step 7: Leave the taint in place**

Do NOT remove the taint afterward — restoring the fresh-cluster condition is the correct steady state going forward. Any future node replacement reapplies it anyway.

- [ ] **Step 8: Capture validation evidence for the PR description**

Record:
- Node name that received the re-taint
- Output of `kubectl get pods -A -o wide | wc -l` pre- and post-bounce (sanity check no pods disappeared)
- The "No resources found" confirmation for Pending pods
- Smoke script exit status

No commit for this task — evidence goes into the PR body.

---

## Self-Review

**Spec coverage check:**

| Spec item | Covered by |
|---|---|
| trakrf-backend toleration | Task 1 |
| trakrf-ingester toleration | Task 2 |
| trakrf-db (CNPG Cluster) toleration via affinity.tolerations | Task 3 |
| cnpg operator toleration | Task 4 |
| kube-prometheus-stack (6 subcomponents) tolerations | Task 5 |
| argocd (5 subcomponents, dex/notifications excluded) tolerations | Task 6 |
| cert-manager inline-helm.values GKE branch tolerations | Task 7 |
| traefik inline-helm.values GKE branch toleration | Task 8 |
| V2 validation: re-taint + bounce, no Pending, smoke-gke green | Task 9 |
| Rationale comment in every overlay pointing to TRA-470 + memory | All of Tasks 1-8 |
| Base values.yaml + AKS/EKS overlays untouched | Negative space — no task modifies them |
| Follow-ups (upstream FR, memory update) | Called out as separate PRs in the spec; not in this plan |

**No placeholders:** All tasks have exact file paths, complete replacement file contents (not diffs against imagined state), exact commands, and expected outputs. The one area of flexibility is Task 8's Step 2 note about possible YAML merging — but it has concrete fallback instructions, not a placeholder.

**Type/key consistency:** Every task uses the canonical `kubernetes.io/arch = arm64, Equal, NoSchedule` quadruple. The toleration value keys (`tolerations:`, `affinity.tolerations:`, `deployment.tolerations:`, `controller.tolerations:`, `prometheus.prometheusSpec.tolerations:`, `kube-state-metrics.tolerations:`, `prometheus-node-exporter.tolerations:`) are stable across tasks and match the spec's placement map.

**Scope:** Single subsystem (GKE toleration overlays), 8 files, one validation pass. Appropriately sized for a single plan.
