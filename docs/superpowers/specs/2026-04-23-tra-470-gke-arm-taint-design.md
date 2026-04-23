# TRA-470 — GKE ARM arch-taint: permanent per-workload toleration fix

- **Linear:** [TRA-470](https://linear.app/trakrf/issue/TRA-470/gke-arm-arch-taint-terraform-level-suppression)
- **Branch:** `miks2u/tra-470-gke-arm-arch-taint-terraform-level-suppression`
- **Related:** TRA-461 (GKE phase 3), memory `feedback_gke_arm_auto_taint`, memory `project_gke_phase3_shipped`
- **Status:** design

## Problem

GKE 1.28+ auto-applies `kubernetes.io/arch=arm64:NoSchedule` to ARM node pools (T2A, T2D, Axion). Workloads without a matching toleration stay `Pending` with `FailedScheduling`. AKS Ubuntu nodes do not do this, so the AKS phase 3 pattern (TRA-438) needed no tolerations — GKE does.

During the TRA-461 rollout the CNPG operator was the first casualty; the cluster was unblocked with a one-off `kubectl taint node <name> kubernetes.io/arch=arm64:NoSchedule-`, which only persists until node replacement.

### Acceptance

- Fresh `just gcp` + `just argocd-bootstrap gke` + root-app sync → no manual `kubectl taint` needed.
- Survives cluster destroy-rebuild and node replacement (matters for the dev iteration loop).

## Approach

**Per-workload tolerations in GKE-only overlays.** Declare the ARM64 toleration on every workload that can land on the primary ARM pool. Strictly scoped to GKE — tolerations live in each chart's `values-gke.yaml` overlay or in the GKE branch of an inline `argocd/root` template. AKS and EKS manifests are not touched.

**Canonical toleration block** (identical across all eight workload sites):

```yaml
tolerations:
  - key: kubernetes.io/arch
    operator: Equal
    value: arm64
    effect: NoSchedule
```

### Rejected options

- **Terraform-level suppression (`--no-arm-node-taint` equivalent).** `hashicorp/google` v6 (currently locked at v6.50.0) does not expose a `disable_arm_node_taint` field on `google_container_node_pool`. Open issues #13308 and #16054 document related taint-handling bugs but do not yet include a suppression knob. File as an upstream FR; do not block on it.
- **Tolerations in base `values.yaml`.** Single-file-per-chart, but silently pushes unused tolerations into AKS/EKS pod specs and rots its comment the fastest. Explicit GKE overlay scoping is clearer.
- **`image_type = UBUNTU_CONTAINERD`.** Larger security-posture change; unrelated to this issue.
- **`null_resource` / `local-exec` to remove the taint post-create.** Racy and couples TF state to kubectl invocation; no persistence across node replacement.
- **Kyverno / mutating admission webhook auto-inject.** Over-engineered for one label.

## Placement map

Eight workload sites across three placement mechanisms.

### Category A — project charts with first-class `.Values.tolerations`

Set the canonical block at the documented key. Chart templates already plumb it through.

| File | Key | Notes |
|---|---|---|
| `helm/trakrf-backend/values-gke.yaml` | `tolerations:` (top-level) | `{{- with .Values.tolerations }}` in `templates/deployment.yaml` |
| `helm/trakrf-ingester/values-gke.yaml` | `tolerations:` (top-level) | Same scaffold as backend |
| `helm/trakrf-db/values-gke.yaml` | `affinity.tolerations:` | CNPG Cluster; maps to `spec.affinity.tolerations` via `templates/cluster.yaml`. Replace existing "affinity intentionally empty" comment. |

### Category B — upstream charts configured via `argocd/root` inline `helm.values`

Add a `{{- else if eq .Values.cluster "gke" }}` branch (or extend the existing one) in the template's inline `helm.values`.

| File | Chart | Key paths |
|---|---|---|
| `argocd/root/templates/cert-manager.yaml` | `jetstack/cert-manager` | `tolerations:`, `webhook.tolerations:`, `cainjector.tolerations:`, `startupapicheck.tolerations:` |
| `argocd/root/templates/traefik.yaml` | `traefik/traefik` | `deployment.tolerations:` |

### Category C — upstream charts configured via our `values-<cluster>.yaml` overlay

| File | Chart | Key paths |
|---|---|---|
| `helm/cnpg/values-gke.yaml` | `cnpg/cloudnative-pg` | `tolerations:` (operator Deployment) |
| `helm/monitoring/values-gke.yaml` | `prometheus-community/kube-prometheus-stack` | `prometheus.prometheusSpec.tolerations`, `alertmanager.alertmanagerSpec.tolerations`, `grafana.tolerations`, `prometheusOperator.tolerations`, `kube-state-metrics.tolerations` (subchart — hyphenated), `prometheus-node-exporter.tolerations` (subchart DaemonSet — hyphenated) |
| `argocd/bootstrap/values-gke.yaml` | `argo/argo-cd` | `controller.tolerations`, `server.tolerations`, `repoServer.tolerations`, `applicationSet.tolerations`, `notifications.tolerations`, `dex.tolerations`, `redis.tolerations` |

### Explicitly out of scope

- `helm/cert-manager-config/values-gke.yaml` — templates `Certificate` only, no Pod specs.
- `helm/traefik-config/values-gke.yaml` — templates `IngressRoute` / `Middleware` only, no Pod specs.
- `helm/monitoring/manifests-gke/` — Grafana `IngressRoute` only, no Pod specs.
- `values-aks.yaml`, `values-eks.yaml`, base `values.yaml` — all untouched.

### Comment convention

Each affected file gets a short header comment explaining the *why*:

```yaml
# GKE auto-applies kubernetes.io/arch=arm64:NoSchedule to ARM node pools
# (T2A/T2D/Axion). AKS Ubuntu does not. Toleration scoped to GKE overlays
# only — base values stay untouched. See TRA-470 and feedback_gke_arm_auto_taint.
```

## Validation (V2: re-taint + bounce)

Performed on the live GKE cluster after the changes sync.

1. **Baseline pre-check.** `kubectl get nodes -o json | jq '.items[].spec.taints'` — confirm the taint is currently absent (removed during TRA-461). `kubectl get pods -A` — note all pods Ready.
2. **Apply + sync.** Land the eight-file change on the branch, push to sync, wait for all argocd Applications Synced + Healthy.
3. **Re-apply taint.** `kubectl taint node <primary> kubernetes.io/arch=arm64:NoSchedule` — restores the fresh-cluster condition.
4. **Bounce covered workloads.** For each Deployment / StatefulSet / DaemonSet under the eight sites: `kubectl rollout restart`. For the CNPG Cluster: `kubectl cnpg restart cluster trakrf-db -n trakrf` (or `kubectl delete pod -l cnpg.io/cluster=trakrf-db -n trakrf`).
5. **Verify no Pending.** `kubectl get pods -A --field-selector=status.phase=Pending` must return empty. `kubectl get pods -A -o wide` must show everything Running on the tainted primary.
6. **Smoke.** `just smoke-gke` passes end-to-end.
7. **Leave taint applied.** Restores parity with a freshly created cluster; any future node replacement reapplies it anyway.

Bootstrap-time ordering (argocd coming up against a tainted node on a truly fresh cluster) is *inferred* from step 4 rather than directly tested. The next organic destroy-rebuild cycle will confirm it.

## Follow-ups (separate PRs / issues)

- **Upstream feature request** to `hashicorp/terraform-provider-google`: add `node_config.disable_arm_node_taint` (or equivalent) mirroring the `gcloud` CLI behavior. Reference issues #13308 / #16054. Track as its own Linear issue; once provider support lands, overlays become removable but not mandatorily so.
- **Update memory** `feedback_gke_arm_auto_taint` to reflect that tolerations are now the permanent fix (replacing the "track upstream" status); add a pointer to the canonical toleration form.

## Risks

| Risk | Mitigation |
|---|---|
| Miss a subcomponent in a multi-pod upstream chart (e.g., a kube-prom-stack pod type not in the list above) | Validation step 5 catches any Pending pod — iterate until empty |
| Upstream chart renames a tolerations key between minor versions | Chart versions pinned via `targetRevision` / justfile; key drift surfaces on intentional version bumps |
| CNPG pod reschedule causes brief primary downtime during step 4 | One-instance cluster on single-node topology; brief downtime acceptable for validation bounce |
| Toleration silently "fixes" scheduling onto unintended ARM nodes in a hypothetical future mixed-arch pool | Out of scope — current topology is single-pool ARM; revisit if mixed pools ever appear |

## Rollback

Revert the PR. Tolerations are additive; removing them does not break steady-state pods that already scheduled. The next node replacement after a rollback would re-introduce Pending on the taint.
