# TRA-461 — GKE phase 3: ArgoCD bootstrap + portable layer + GHCR image pull

**Date**: 2026-04-23
**Linear**: [TRA-461](https://linear.app/trakrf/issue/TRA-461) (child of epic [TRA-444](https://linear.app/trakrf/issue/TRA-444))
**Status**: Design approved, pending user review of this document
**Branch**: `feature/tra-461-gke-phase-3`

## Context

TRA-460 landed the GKE cluster, Cloud DNS zone for `gke.trakrf.app`, and Cloudflare NS delegation of that subzone. The cluster is empty — no ArgoCD, no platform apps, no TrakRF.

TRA-461 gets TrakRF running on GKE end-to-end: ArgoCD bootstrapped, platform stack synced (cert-manager, Traefik, kube-prometheus-stack, CNPG), `trakrf-backend` + `trakrf-ingester` deployed with real Let's Encrypt TLS on `gke.trakrf.app`, and a manual smoke test (login → BLE scan → inventory save) proving the full data path.

This extends the multi-cluster values-overlay layout established in TRA-438 (AKS phase 3). The pattern — `values.yaml` (common) + `values-<cluster>.yaml` across each `helm/*` chart, with a single `cluster:` touchpoint in `argocd/root/values.yaml` — is preserved as-is. This phase adds a `gke` branch; no refactor.

## Port preference

Default to the AKS-established pattern (`argocd/root/` app-of-apps, `values-<cluster>.yaml` overlays, `scripts/apply-root-app.sh` reading tofu outputs). This ticket is a direct port of TRA-438 with GCP-shaped substitutions, not a chance to refactor. Provider-neutralization (renaming Azure-specific keys in `argocd/root/values.yaml`) waits for cluster #3.

## Design decisions

| Decision | Choice | Rationale |
|---|---|---|
| cert-manager DNS-01 solver | **Cloud DNS** via GKE Workload Identity on the `gke.trakrf.app` zone | Makes the TRA-460 zone load-bearing; tight blast radius (zone-scoped `roles/dns.admin`, not project-wide); mirrors AKS's Azure-DNS-via-workload-identity discipline. |
| Cert authority | Let's Encrypt | Same as EKS/AKS — cloud-neutral, in-cluster, protocol-standard. |
| Multi-cluster pattern | **Additive** `values-gke.yaml` overlays + `gke` branch in root-app templates | Matches TRA-438's decision; no refactor with only two data points. |
| Storage class | `premium-rwo` (pd-ssd) | User preference — incremental cost over `standard-rwo`, better IOPS headroom for CNPG + Prometheus TSDB. |
| Traefik LB IP | **Static** `google_compute_address` (regional EXTERNAL, PREMIUM tier, `us-central1`), TF-managed | Stability across cluster rebuilds; DNS A records managed in the same `terraform/gcp/` apply. |
| Image source | **GHCR direct**; no Artifact Registry push | trakrf images are public (verified via anonymous bearer token); no pull secret needed. AR push is a phase-4 CI concern. |
| Image tag | `sha-a99b5b8` (same ARM-native tag as AKS) | `t2a-standard-4` is ARM Ampere; the TRA-455 tag is already arm64-native. |
| CNPG topology | Single `t2a-standard-4` node runs everything | Same rationale as AKS single-pool — demo vehicle, node pinning is a later concern. |
| Delivery mechanism | **Root-app Applications for most; direct helm for CNPG operator + kube-prometheus-stack** | Unchanged from TRA-438 — same chart-shaped cycles (CNPG pre-install CRDs) and same kube-prom controller-OOM risk. |
| Grafana host | `grafana.gke.trakrf.app` | Mirrors the AKS `grafana.aks.trakrf.app` convention. |

## Architecture

### Runtime data flow

- **Public DNS**: `gke.trakrf.app` + `*.gke.trakrf.app` → static regional GCP IP (TF-managed `google_compute_address`, PREMIUM tier, `us-central1`) → Traefik `LoadBalancer` Service (pinned via `spec.loadBalancerIP`).
- **Cert issuance**: cert-manager pod uses GKE Workload Identity. The Kubernetes SA `cert-manager/cert-manager` is annotated with a GCP service account email; that GCP SA has `roles/dns.admin` scoped **only to the `gke.trakrf.app` Cloud DNS zone**. `ClusterIssuer` uses the `cloudDNS` solver referencing `project_id` + `hostedZoneName`. Let's Encrypt DNS-01 mints real cert for apex + wildcard SANs.
- **Ingress path**: `https://gke.trakrf.app` → regional LB (static IP) → Traefik → IngressRoute for `trakrf-backend` → backend Service → backend pod (serves SPA + API from single monorepo image via `go:embed`) → CNPG `trakrf-db-rw` Service → Postgres pod, PV on `premium-rwo`.
- **Observability**: kube-prometheus-stack scrapes everything; Grafana at `https://grafana.gke.trakrf.app`. Node + disk-latency panels drive the post-demo "was `premium-rwo` the right call" feedback loop.

### Non-goals

- Real TLS on the `trakrf.app` apex (marketing-site concern)
- Multi-region or cross-cluster federation
- ApplicationSet migration
- CI-driven Artifact Registry pushes (phase 4)
- Load / stress / failover testing
- AKS → GKE migration of `premium-rwo` (AKS stays on `managed-csi`; narrative divergence acknowledged)

## Implementation

### Terraform additions (`terraform/gcp/`)

**New file: `terraform/gcp/cert_manager.tf`**
- `google_service_account.cert_manager` — identity cert-manager federates into (name: `cert-manager-<name_prefix>`)
- `google_dns_managed_zone_iam_member.cert_manager_dns_admin` — `roles/dns.admin` scoped to `google_dns_managed_zone.gke_trakrf_app` (not project-wide)
- `google_service_account_iam_member.cert_manager_wi` — `roles/iam.workloadIdentityUser`, member `serviceAccount:${project_id}.svc.id.goog[cert-manager/cert-manager]`

**New file: `terraform/gcp/traefik_lb.tf`**
- `google_compute_address.traefik` — regional EXTERNAL, PREMIUM tier, `us-central1`, `prevent_destroy = true`

No IAM wiring analogous to the Azure `Network Contributor` dance — GCE cloud-controller honors the reservation without additional role grants.

**Additions to `terraform/gcp/dns.tf`**
- `google_dns_record_set.gke_apex` — `gke.trakrf.app.` A → `google_compute_address.traefik.address`
- `google_dns_record_set.gke_wildcard` — `*.gke.trakrf.app.` A → same

**New outputs in `terraform/gcp/outputs.tf`**
- `cert_manager_service_account_email` — for the K8s SA annotation
- `cloud_dns_zone_name` — Cloud DNS managed-zone **resource name** (`gke-trakrf-app`), distinct from `dns_zone_name` (human-readable `gke.trakrf.app`)
- `traefik_lb_ip` — static address

No changes to `gke.tf` — Workload Identity was already enabled in phase 2.

### Helm chart changes

Pattern: add `values-gke.yaml` alongside the existing `values-aks.yaml` / `values-eks.yaml` in each chart. No changes to any `values.yaml` (common) except where the `clusterissuer.yaml` template gains a new `cloudDNS` branch.

**`helm/cert-manager-config/`**
- `values-gke.yaml`: `solver: cloudDNS`, `cloudDNS.project: <project_id>`, `cloudDNS.hostedZoneName: gke-trakrf-app`, `certificate.commonName: gke.trakrf.app`, `dnsNames: [gke.trakrf.app, "*.gke.trakrf.app"]`
- Template `clusterissuer.yaml` grows a third `{{ else if eq .Values.solver "cloudDNS" }}…{{ end }}` branch (alongside existing `cloudflare` and `azureDNS`)

**cert-manager (jetstack upstream)** — embedded in `argocd/root/templates/cert-manager.yaml`, gated on `.Values.cluster`. New GKE case:
- `serviceAccount.annotations."iam.gke.io/gcp-service-account": <cert_manager_service_account_email from tofu>`
- No pod labels needed (GKE WI does not need `azure.workload.identity/use` equivalent)

**`helm/traefik-config/values-gke.yaml`** — empty scaffold. Traefik Service-level overrides (`loadBalancerIP`) live on the upstream chart values injected by `argocd/root/templates/traefik.yaml`, not here.

**`helm/trakrf-backend/values-gke.yaml`**
- `image.tag: sha-a99b5b8`
- `ingress.host: gke.trakrf.app`

**`helm/trakrf-ingester/values-gke.yaml`** — empty scaffold (parity with AKS).

**`helm/trakrf-db/values-gke.yaml`**
- `storage.class: premium-rwo`
- Affinity intentionally empty (single-pool topology).

**`helm/cnpg/values-gke.yaml`** — empty scaffold.

**`helm/monitoring/values-gke.yaml`**
- `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName: premium-rwo`
- `alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName: premium-rwo`
- `grafana.persistence.storageClassName: premium-rwo`
- `grafana.grafana.ini.server.domain: grafana.gke.trakrf.app`
- `grafana.grafana.ini.server.root_url: https://grafana.gke.trakrf.app`

**`helm/monitoring/manifests-gke/`** — new directory with the `gke.trakrf.app` variant of the Grafana IngressRoute (mirrors `manifests-aks/`).

**`argocd/bootstrap/values-gke.yaml`** — empty scaffold; ArgoCD itself doesn't need GCP API access.

### ArgoCD root chart (`argocd/root/`)

Additive changes only — no renames of existing AKS-specific keys.

**`argocd/root/values.yaml`** — new keys appended:
- `gcpProjectId: ""`
- `certManagerGcpServiceAccountEmail: ""`
- `cloudDnsZoneName: ""`
- (`traefikLbIp` already exists; reused for GKE's static IP)

**`argocd/root/templates/cert-manager-config.yaml`** — extend the cluster conditional:
```
{{- else if eq .Values.cluster "gke" -}}
{{- $inlineValues = printf "cloudDNS:\n  project: %s\n  hostedZoneName: %s\n"
    .Values.gcpProjectId
    .Values.cloudDnsZoneName
-}}
```

**`argocd/root/templates/cert-manager.yaml`** — add GKE branch:
```
{{- else if eq .Values.cluster "gke" }}
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: {{ .Values.certManagerGcpServiceAccountEmail | quote }}
{{- end }}
```

**`argocd/root/templates/traefik.yaml`** — extend cluster conditional with GKE-specific `loadBalancerIP` (no resource-group annotation; no GCP analog):
```
{{- else if eq .Values.cluster "gke" }}
service:
  spec:
    loadBalancerIP: {{ .Values.traefikLbIp | quote }}
{{- end }}
```

**`scripts/apply-root-app.sh`** — add `gke)` case reading from `terraform/gcp`:
- `gcpProjectId` ← `tofu output -raw project_id`
- `certManagerGcpServiceAccountEmail` ← `tofu output -raw cert_manager_service_account_email`
- `cloudDnsZoneName` ← `tofu output -raw cloud_dns_zone_name`
- `traefikLbIp` ← `tofu output -raw traefik_lb_ip`
- Azure-only vars (`CLIENT_ID`, `TENANT_ID`, `SUB_ID`, `MAIN_RG`) pass through as empty (same pattern as `eks)` today)

### Justfile additions

**`gke-creds`** (new):
```
gke-creds:
    @PROJECT=$(tofu -chdir=terraform/gcp output -raw project_id) && \
     CLUSTER=$(tofu -chdir=terraform/gcp output -raw cluster_name) && \
     ZONE=$(tofu -chdir=terraform/gcp output -raw zone) && \
     gcloud container clusters get-credentials $CLUSTER --zone $ZONE --project $PROJECT && \
     kubectl config use-context gke_${PROJECT}_${ZONE}_${CLUSTER}
```

No changes to `cnpg-bootstrap`, `monitoring-bootstrap`, `argocd-bootstrap`, `db-secrets` — they already take `CLUSTER` as an arg and will pick up `values-gke.yaml` automatically.

**`smoke-gke`** (new, mirrors `smoke-aks`) — see Smoke test section.

### Cleanup

None for this phase. AKS-related files stay intact; EKS-related files stay intact.

## Smoke test

### Scripted preconditions (`just smoke-gke`)

- All root-app Applications `Synced` + `Healthy` (`kubectl -n argocd get applications`)
- Certificate Ready, Secret populated (`kubectl -n traefik get certificate`)
- Traefik Service external IP equals `tofu -chdir=terraform/gcp output -raw traefik_lb_ip`
- `dig +short gke.trakrf.app` and `dig +short foo.gke.trakrf.app` both return that IP
- `curl -sI https://gke.trakrf.app` → 200 OK; `curl -v` shows Let's Encrypt issuer
- Backend health endpoint responds

Script exits non-zero on any red.

### Manual UI walkthrough (TRA-461 "done" criterion)

1. Browser to `https://gke.trakrf.app`; log in with `.env.local` credentials. Verify JWT issued, dashboard renders.
2. Trigger BLE scan from UI. Verify inventory discovery end-to-end (Redpanda Connect → backend → CNPG).
3. Save inventory item. Reload page, verify persisted.

### Grafana sanity

- Browser to `https://grafana.gke.trakrf.app`; log in.
- Confirm default kube-state-metrics dashboards render for the single `t2a-standard-4` primary.
- Record baseline memory / CPU / disk-latency on `premium-rwo` under smoke-test load (feedback on the `premium-rwo` vs `standard-rwo` choice).

### Outputs

- `just smoke-gke` exit 0
- Screenshots (login, dashboard, BLE scan, saved inventory, Grafana overview)
- Linear comment on TRA-461 with results + baseline numbers
- PR merged; TRA-461 → Done

## Risks and mitigations

- **GCP SA propagation lag** (~30–60s after `just gcp`) → first cert-manager DNS-01 attempt fails. cert-manager retries automatically; 5-min patience before debugging.
- **Workload Identity SA binding subject mismatch** → cert-manager can't get tokens. Subject must be exactly `serviceAccount:${project_id}.svc.id.goog[cert-manager/cert-manager]`. Validate with `gcloud iam service-accounts get-iam-policy <sa-email>`.
- **`spec.loadBalancerIP` deprecation drift** → upstream K8s marks it deprecated; GCE cloud-controller still honors it today. Replacement is an annotation when it lands. Not blocking.
- **Traefik LB `Pending` > 2 min** → static IP region/tier mismatch. Check `kubectl -n traefik describe svc traefik`; verify `google_compute_address` region matches the cluster region.
- **CNPG initdb Pending** → single-zone cluster (`us-central1-a`) means `WaitForFirstConsumer` zone affinity can't mismatch. Should not occur.
- **GHCR pull flake** → images are public and verified with anonymous bearer token flow; no pull secret needed. If GitHub ever revokes anonymous pulls on `ghcr.io/trakrf/*`, fallback is a docker-registry secret in the `trakrf` namespace referenced via `imagePullSecrets` (chart already supports it).

## Destroy plan

```
helm -n argocd uninstall trakrf-root       # graceful prune of Applications
helm -n argocd uninstall argocd
just gcp-destroy                           # (or tofu -chdir=terraform/gcp destroy)
```

`prevent_destroy` on `google_compute_address.traefik` and `google_dns_managed_zone.gke_trakrf_app` (existing). GKE cluster itself is not `prevent_destroy` — destroy-rebuild is a valid dev loop at this scale.

## Bootstrap sequence (operator)

```
just gcp                       # apply terraform (cert_manager.tf, traefik_lb.tf, dns A records)
just gke-creds                 # kubeconfig context
just cnpg-bootstrap gke        # CNPG operator (direct helm)
just db-secrets                # role secrets in trakrf ns
just monitoring-bootstrap gke  # kube-prometheus-stack (direct helm)
just argocd-bootstrap gke      # ArgoCD + root-app; script reads tofu outputs
# wait for sync
just smoke-gke
```

## Follow-ups (out of scope for TRA-461)

- Phase 4 (TRA-462): smoke test end-to-end save-location flow
- CI-driven Artifact Registry push (if/when public GHCR pulls become problematic)
- ApplicationSet migration once a third cluster exists
- Node right-sizing based on Grafana readings (post-demo)
- Spot burst pool
- Provider-neutralization of `argocd/root/values.yaml` field names (defer to cluster #3)
