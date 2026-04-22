# TRA-438 — AKS demo phase 3: portable K8s layer + TrakRF smoke test

**Date**: 2026-04-22
**Linear**: [TRA-438](https://linear.app/trakrf/issue/TRA-438) (child of epic [TRA-435](https://linear.app/trakrf/issue/TRA-435))
**Status**: Design approved, pending user review of this document
**Branch**: `feature/tra-438-aks-phase-3`

## Context

TRA-437 landed the AKS cluster, ACR, Azure DNS zone for `aks.trakrf.app`, and Cloudflare NS delegation of that subzone. The cluster is empty — no ArgoCD, no platform apps, no TrakRF.

TRA-438 gets TrakRF running on AKS end-to-end: ArgoCD bootstrapped, platform stack synced (cert-manager, Traefik, kube-prometheus-stack, CNPG), `trakrf-backend` + `trakrf-ingester` deployed with real Let's Encrypt TLS on `aks.trakrf.app`, and a manual smoke test (login → BLE scan → inventory save) proving the full data path.

Alongside the AKS work, this phase converts `helm/` and `argocd/` from a single-cluster (EKS) layout to a multi-cluster values-overlay layout. The existing EKS configuration is preserved in `values-eks.yaml` overlays so a future EKS revival remains a one-line flip rather than a git-history archaeology exercise.

## Port preference reminder

Default to EKS patterns (`helm/*`, `argocd/applications/*`, `just argocd-bootstrap`). Reach for `hashsphere-azure-foundation` only for Azure specifics EKS doesn't cover — workload identity / federated credentials, Azure DNS solver wiring, static PIP + Traefik Service annotations. No shell-script init, no changes to Azure state-backend layout, no hashsphere naming conventions.

## Prerequisite (tracked outside this repo)

`trakrf/platform` needs a one-line PR to `docker-build.yml:62`:
```diff
-          platforms: linux/amd64
+          platforms: linux/amd64,linux/arm64
```
The root `Dockerfile` sets `CGO_ENABLED=0` (line 58) and the frontend stage is `node:24-alpine`; multi-arch is a pure buildx matrix change. Once a multi-arch `sha-XXXXXXX` tag is published, `values-aks.yaml` for `trakrf-backend` gets pinned to it.

`docker buildx imagetools inspect` results (2026-04-22):

| Image | amd64 | arm64 |
|---|---|---|
| `ghcr.io/trakrf/backend:sha-9f22fac` | ✅ | ❌ (blocker, see above) |
| `docker.redpanda.com/redpandadata/connect:4.40.0` | ✅ | ✅ |
| `ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18` | ✅ | ✅ |

Prereq PR status is tracked in Linear on TRA-438, not this spec.

## Design decisions (brainstormed 2026-04-22)

| Decision | Choice | Rationale |
|---|---|---|
| cert-manager DNS-01 solver | **Azure DNS** via workload identity on `aks.trakrf.app` zone | Makes the TRA-437 zone load-bearing rather than cosmetic; tighter blast radius than reusing the Cloudflare token everywhere; matches preview-cutover "cloud-native to cluster" narrative. |
| Cert authority | Let's Encrypt | No Azure-native public CA exists for AKS+Traefik (Front Door / App Gateway managed certs only work when those services are the TLS terminator). cert-manager + LE is cloud-neutral, protocol-standard, in-cluster, and matches EKS. |
| Multi-cluster pattern | **Values overlay** (`values.yaml` + `values-<cluster>.yaml`), not template duplication or ApplicationSet | Multi-cloud narrative is useful for TrakRF presentation; ApplicationSet is premature with one cluster; static references keep debugging simple and upgrade cleanly to ApplicationSet when EKS returns. |
| ArgoCD wiring | **App-of-apps root Helm chart** (`argocd/root/`) with `cluster: <name>` as the single mapping touchpoint | Self-hoster friendly: `cp values-aks.yaml values-homelab.yaml`, flip one line, rebootstrap. |
| Platform scope | **EKS parity** — cert-manager, Traefik, kube-prometheus-stack, CNPG, trakrf-backend, trakrf-ingester, ArgoCD | Grafana drives the node-sizing feedback loop from `project_aks_demo_topology`; one-line monitoring overlay is trivial given the rest is already parameterized. |
| Delivery mechanism | **Root-app Applications for most; direct helm for CNPG operator + kube-prometheus-stack** | `project_argocd_lessons` — kube-prom's ~50+ ConfigMaps/CRDs OOM the ArgoCD controller; CNPG's pre-install hooks depend on CRDs the same chart installs (chicken-and-egg). Same values-overlay pattern either way. |
| Image strategy | **Skip ACR**; pull from GHCR directly | trakrf images are public; AcrPull wiring from TRA-437 already exercised by its role assignment; ACR push is phase-4 CI concern. |
| Traefik LB IP | **Static public IP** in main RG, TF-managed; A records for `@` + `*` in same apply | IP stability across cluster rebuilds was the whole point of delegating `aks.trakrf.app` to Azure DNS under TF. |
| CNPG | **Wrap bare CR in `helm/trakrf-db/` chart** | Uniform Helm-shaped deployables; retires misleading `argocd/clusters/trakrf/` path. |
| Smoke test | **Manual browser walkthrough** (login → BLE → inventory) + scripted `just smoke-aks` precondition checks | Matches demo-vehicle scope; scripted app probes belong in `trakrf/platform`. |

## Architecture

### Runtime data flow

- **Public DNS**: `aks.trakrf.app` + `*.aks.trakrf.app` → static Azure PIP (TF-managed) → Traefik Service LB binding
- **Cert issuance**: cert-manager ClusterIssuer uses workload identity federated to a user-assigned identity with `DNS Zone Contributor` scoped to `aks.trakrf.app`. Solves ACME DNS-01 against Azure DNS, mints real LE cert for apex + wildcard SANs.
- **Ingress path**: `https://aks.trakrf.app` → Azure LB (static IP) → Traefik → IngressRoute for trakrf-backend → backend Service → backend pod (serves SPA + API from single monorepo image via `go:embed`) → CNPG `trakrf-db-rw` Service → Postgres pod on primary node, PV on `managed-csi`.
- **Observability**: kube-prometheus-stack scrapes everything; Grafana at `https://grafana.aks.trakrf.app` shows node memory/CPU for the `Standard_D4ps_v6` primary — the feedback loop for the post-demo "right-size the primary" decision.

### Non-goals (this phase)

- Real TLS on the root `trakrf.app` apex (unchanged from Linear issue — that's a marketing-site concern)
- Multi-region, cross-cluster federation
- ApplicationSet-based multi-cluster generators (values overlays are the forward-compatible stepping stone)
- CI-driven ACR pushes (phase 4)
- load / stress / concurrency / failover testing

## Implementation

### Terraform additions

**`terraform/azure/aks.tf`** — two property adds on `azurerm_kubernetes_cluster.main`:
- `oidc_issuer_enabled = true`
- `workload_identity_enabled = true`

Both are `false → true` transitions; no resource recreation per the azurerm changelog notes.

**New file: `terraform/azure/cert_manager.tf`**
- `azurerm_user_assigned_identity.cert_manager` — the identity cert-manager federates into
- `azurerm_federated_identity_credential.cert_manager` — binds `system:serviceaccount:cert-manager:cert-manager` to the UAI via the AKS OIDC issuer, audience `api://AzureADTokenExchange`
- `azurerm_role_assignment.cert_manager_dns` — `DNS Zone Contributor` scoped to `azurerm_dns_zone.aks_trakrf_app.id` (not the whole RG, not the subscription)

**New file: `terraform/azure/traefik_lb.tf`**
- `azurerm_public_ip.traefik` — Standard SKU, Static allocation, zonal (matches `primary_pool_zone`), in main RG, `prevent_destroy = true`
- `azurerm_role_assignment.aks_network_contributor_main_rg` — `Network Contributor` on main RG for the AKS cluster identity (required when LB resources live outside the AKS MC_ RG)

**Additions to `terraform/azure/dns.tf`**
- `azurerm_dns_a_record.aks_apex` — `@` → `azurerm_public_ip.traefik.ip_address`
- `azurerm_dns_a_record.aks_wildcard` — `*` → same

**New outputs in `terraform/azure/outputs.tf`**
- `cert_manager_identity_client_id`
- `cert_manager_identity_tenant_id` (for the Azure DNS solver config)
- `subscription_id`
- `dns_zone_resource_group`
- `traefik_lb_ip`
- `main_resource_group_name` (explicit, for the Traefik Service annotation)

### Helm chart changes

Pattern: every chart's current `values.yaml` splits into `values.yaml` (common) + `values-eks.yaml` (the current content, moved) + `values-aks.yaml` (new).

**`helm/cert-manager-config/`**
- `values.yaml` common: ACME email, LE prod server URL, cert SAN pattern
- `values-eks.yaml`: `solver: cloudflare`, zone `trakrf.app`, CF token secret ref (as-is today)
- `values-aks.yaml`: `solver: azureDNS`, tenantId / subscriptionId / resourceGroup / hostedZoneName from tofu outputs; no token — workload identity does the auth
- Template `clusterissuer.yaml` adds an `{{ if eq .Values.solver "azureDNS" }}…{{ else if eq .Values.solver "cloudflare" }}…{{ end }}` solver fork; everything else stays shared

**cert-manager (jetstack upstream) values** — not a chart under `helm/`; these values are embedded in the `argocd/root/templates/cert-manager.yaml` Application pointing at `https://charts.jetstack.io`, gated on `.Values.cluster`:
- AKS case: `serviceAccount.annotations."azure.workload.identity/client-id"` = `<cert_manager_identity_client_id from tofu>`, `serviceAccount.labels."azure.workload.identity/use"` = `"true"`, pod label `azure.workload.identity/use: "true"` on the cert-manager controller
- EKS case: existing IRSA annotation if any, else empty

**`helm/traefik-config/`**
- `values-aks.yaml`: `service.spec.loadBalancerIP: <traefik_lb_ip>`, `service.annotations."service.beta.kubernetes.io/azure-load-balancer-resource-group": <main_resource_group_name>`
- `values-eks.yaml`: whatever AWS LB annotations existed (or empty)

**`helm/monitoring/`** (applied via `just monitoring-bootstrap CLUSTER`, not ArgoCD — see "Direct helm installs")
- `values-eks.yaml`: `storageClassName: gp3` (existing)
- `values-aks.yaml`: `storageClassName: managed-csi`, Grafana ingress `host: grafana.aks.trakrf.app`

**`helm/cnpg/`** (new wrapper; applied via `just cnpg-bootstrap CLUSTER`, not ArgoCD — see "Direct helm installs")
- `values.yaml`: common CNPG operator config (replica count, resources)
- `values-aks.yaml`: any Azure-specific tweaks (likely empty for phase 3)
- `values-eks.yaml`: existing EKS tweaks or empty
- No `templates/` — this is a values-only wrapper around the upstream `cnpg/cloudnative-pg` chart

**`helm/trakrf-backend/`**
- `values-eks.yaml`: `ingress.host: eks.trakrf.app`
- `values-aks.yaml`: `ingress.host: aks.trakrf.app`, `image.tag: <multi-arch tag from prereq PR>`

**`helm/trakrf-ingester/`**
- `values-aks.yaml`: ingress host or other small overrides as needed; Redpanda Connect image unchanged

**`helm/trakrf-db/` (new chart)**
- `Chart.yaml` — `name: trakrf-db`, `version: 0.1.0`
- `values.yaml` — common CNPG spec (instances, image `ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18`, postgresql parameters, initdb/bootstrap SQL, managed roles) — 1:1 port of current `argocd/clusters/trakrf/cluster.yaml` minus storage + affinity
- `values-eks.yaml`: `storage.class: gp3`, affinity `nodeSelector: {workload: database}` + matching tolerations
- `values-aks.yaml`: `storage.class: managed-csi`, empty affinity (single-pool topology per memory)
- `templates/cluster.yaml` — CNPG `Cluster` CR rendered from values

**`argocd/bootstrap/`** (existing)
- `values-eks.yaml`: existing IRSA annotation for ArgoCD SA (as-is)
- `values-aks.yaml`: no special SA annotation; ArgoCD itself doesn't need Azure API access

### ArgoCD root chart (`argocd/root/`)

New Helm chart, single touchpoint for cluster binding.

- `Chart.yaml` — `name: trakrf-root`, `apiVersion: v2`
- `values.yaml` — `cluster: aks`, `repoURL`, `targetRevision`, `destination.server`, namespace map, and tofu-sourced values (`certManagerIdentityClientId`, `traefikLbIp`, etc.) as placeholders populated at install time by `scripts/apply-root-app.sh`
- `templates/_helpers.tpl` — one `trakrf.application` helper templating the common Application shape (sync policy, sync options, finalizer, `valueFiles: [values.yaml, values-{{ .cluster }}.yaml]`)
- `templates/*.yaml` — 8 Applications (CNPG operator + kube-prometheus-stack are standalone helm installs, see "Direct helm installs" below):
  - argocd (self-hosting of ArgoCD)
  - cert-manager (jetstack upstream, SA workload-identity annotation)
  - cert-manager-config (our chart)
  - traefik (upstream)
  - traefik-config (our chart)
  - trakrf-db (our chart, new)
  - trakrf-backend
  - trakrf-ingester

**Sync-wave ordering** (`argocd.argoproj.io/sync-wave` annotation):
- `-1`: cert-manager, traefik — operators/controllers with CRDs
- `0`: cert-manager-config, traefik-config, trakrf-db — depend on CRDs + issuer
- `1`: trakrf-backend — depends on DB ready (schema migration Job)
- `2`: trakrf-ingester — depends on backend Service + DB

### Direct helm installs (not managed by the root-app)

Two components stay as direct helm installs via justfile recipes, each with the same values-overlay pattern (`values.yaml` + `values-<cluster>.yaml`):

- **CNPG operator** (`cnpg-system` ns) — `just cnpg-bootstrap CLUSTER`. Reason: CNPG's pre-install hooks depend on CRDs the same chart installs; ArgoCD doesn't gracefully handle the cycle. Documented in `docs/superpowers/specs/2026-04-12-trakrf-db-design.md`.
- **kube-prometheus-stack** (`monitoring` ns) — `just monitoring-bootstrap CLUSTER`. Reason: ~50+ ConfigMaps/CRDs OOM the ArgoCD application-controller at demo-cluster resource sizing. Documented in `project_argocd_lessons` memory.

These still share the multi-cloud values pattern, so a self-hoster changing clusters flips the same `CLUSTER` arg across all three bootstrap commands (`cnpg-bootstrap`, `monitoring-bootstrap`, `argocd-bootstrap`).

### Bootstrap scripts and justfile recipes

**`scripts/apply-root-app.sh`** (new, ~40 lines bash)
- Reads named outputs via `tofu -chdir=terraform/azure output -json`
- Substitutes them into a temp values file derived from `argocd/root/values.yaml` with `cluster: {{CLUSTER}}`
- Runs `helm upgrade --install trakrf-root ./argocd/root -n argocd -f <temp-values>`
- Idempotent; safe to re-run when tofu outputs change

**Justfile additions/changes**
- `aks-creds` (new) — `az aks get-credentials … && kubelogin convert-kubeconfig -l azurecli`
- `cnpg-bootstrap CLUSTER` (new) — `helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system -f helm/cnpg/values.yaml -f helm/cnpg/values-{{CLUSTER}}.yaml`
- `monitoring-bootstrap CLUSTER` (modified to take CLUSTER arg) — same pattern with kube-prometheus-stack values
- `db-secrets` (new) — creates `trakrf-app-credentials` and `trakrf-migrate-credentials` in the `trakrf` namespace using `kubectl apply --dry-run=client -o yaml | kubectl apply -f -` pattern; reads passwords from `.env.local`
- `argocd-bootstrap CLUSTER` (modified — takes arg) — installs ArgoCD with cluster-appropriate values, then runs `scripts/apply-root-app.sh $CLUSTER`
- `smoke-aks` (new) — precondition checks (see Smoke test section)

### Cleanup

- Delete `argocd/clusters/trakrf/cluster.yaml` (replaced by `helm/trakrf-db/`)
- Delete `argocd/applications/*.yaml` (replaced by `argocd/root/templates/*.yaml`)
- Evaluate `argocd/clusters/cluster.yaml` — likely fold its in-cluster registration into the root-app chart or remove

## Smoke test

### Scripted preconditions (`just smoke-aks`)

- All 9 Applications `Synced` + `Healthy` (`kubectl -n argocd get applications`)
- Certificate(s) Ready, Secret populated (`kubectl -n traefik get certificate`)
- Traefik Service external IP equals `tofu -chdir=terraform/azure output -raw traefik_lb_ip`
- `dig +short aks.trakrf.app` and `dig +short foo.aks.trakrf.app` both return that IP
- `curl -sI https://aks.trakrf.app` → 200 OK, `curl -v` shows Let's Encrypt issuer on the cert
- Backend health endpoint responds

Script exits non-zero on any red.

### Manual UI walkthrough (TRA-438 "done" criterion)

1. Browser to `https://aks.trakrf.app`; log in with test credentials from `.env.local`. Verify JWT issued, dashboard renders.
2. Trigger BLE scan from UI. Verify inventory discovery runs end-to-end (Redpanda Connect → backend → DB).
3. Save inventory item. Reload page, verify persisted.

### Grafana sanity

- Browser to `https://grafana.aks.trakrf.app`; log in.
- Confirm default kube-state-metrics dashboards show the single primary node.
- Record baseline memory / CPU on `Standard_D4ps_v6` under smoke-test load for the post-demo right-sizing decision.

### Outputs

- `just smoke-aks` exit 0
- Screenshots of login, dashboard, BLE scan, saved inventory, Grafana overview
- Linear comment on TRA-438 with results + baseline Grafana numbers
- PR merged; TRA-438 → Done

## Risks and mitigations

- **Multi-arch prereq not merged** → backend `ImagePullBackOff`. Mitigation: gate `values-aks.yaml` pin on a multi-arch tag being published.
- **Federated credential subject mismatch** → cert-manager fails Azure auth; certs stuck Issuing. Mitigation: verify SA name/namespace match federation subject exactly (`system:serviceaccount:cert-manager:cert-manager`); cross-check via `az identity federated-credential list`.
- **Role assignment propagation lag** (up to ~2 min) on first apply → first cert attempt fails. Mitigation: cert-manager retries automatically; 5-minute patience window before debugging.
- **Traefik LB `Pending` > 3 min** → usually missing/wrong `azure-load-balancer-resource-group` annotation or Network Contributor not propagated. Mitigation: `kubectl -n traefik describe svc traefik` is the first stop; validate the annotation value matches the TF output.
- **CNPG initdb `Pending`** → PV scheduling mismatch. Mitigation: zone pin on primary pool matches `managed-csi` `WaitForFirstConsumer`; should not occur but documented for triage.

## Destroy plan

```
helm -n argocd uninstall trakrf-root       # graceful prune of Applications
helm -n argocd uninstall argocd
just azure-destroy
```

`prevent_destroy` on `azurerm_public_ip.traefik`, `azurerm_dns_zone.aks_trakrf_app` (existing), and optionally the AKS cluster itself (decision deferred — destroy-rebuild is a valid dev loop at this scale).

## Follow-ups (out of scope for TRA-438)

- Multi-arch CI fix in `trakrf/platform` (prereq, tracked in Linear)
- Phase 4: CI-driven ACR push, proper image pull flow
- ApplicationSet migration once a second cluster exists
- Node right-sizing decision based on Grafana readings (likely TRA-438 follow-up ticket)
- Spot burst pool (deferred from TRA-437)
