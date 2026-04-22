# TRA-438 AKS Demo Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get TrakRF running on the TRA-437 AKS cluster end-to-end: workload-identity-backed cert-manager minting a real Let's Encrypt wildcard cert for `aks.trakrf.app`, Traefik on a static LB IP, CNPG + trakrf-backend + trakrf-ingester deployed via ArgoCD root-app, and a manual smoke test (login → BLE scan → inventory save) confirming the full data path.

**Architecture:** Terraform adds AKS OIDC + workload identity, a user-assigned identity federated to the `cert-manager` SA with `DNS Zone Contributor` scoped to the `aks.trakrf.app` zone, a static Azure PIP + `Network Contributor` on the main RG for Traefik's LB, and TF-managed apex + wildcard A records. Helm charts get a values-overlay refactor (`values.yaml` + `values-<cluster>.yaml`) so EKS and AKS configurations coexist. A new `argocd/root/` app-of-apps Helm chart replaces the raw `argocd/applications/` directory, with `cluster: aks` in its values as the single touchpoint. CNPG operator and kube-prometheus-stack stay as direct helm installs (out of ArgoCD) per existing repo decisions.

**Tech Stack:** OpenTofu + azurerm/azuread providers, Helm 3, ArgoCD 2.x, cert-manager + Azure DNS solver via workload identity, kubelogin, `jq`, `just`, `kubectl`.

**Spec:** `docs/superpowers/specs/2026-04-22-tra-438-aks-phase-3-design.md`

**Branch:** `feature/tra-438-aks-phase-3` (already created; spec committed at `7274c49`)

**Prereq (external):** [TRA-451](https://linear.app/trakrf/issue/TRA-451) must land before the first AKS apply of `trakrf-backend` — a multi-arch `sha-XXXXXXX` tag must exist in `ghcr.io/trakrf/backend`. TF and chart refactor work can proceed without it; only the backend pin + first sync wait on the tag.

## File Structure

### Terraform (`terraform/azure/`)
| File | Status | Responsibility |
|---|---|---|
| `aks.tf` | modify | Enable `oidc_issuer_enabled`, `workload_identity_enabled` |
| `cert_manager.tf` | create | UAI + federated credential + `DNS Zone Contributor` role |
| `traefik_lb.tf` | create | Static `azurerm_public_ip` + `Network Contributor` on main RG |
| `dns.tf` | modify | Append apex `@` + wildcard `*` A records |
| `outputs.tf` | modify | New outputs: cert-manager identity client_id / tenant_id, subscription_id, dns RG, traefik LB IP, main RG name |

### Helm charts (`helm/`)
| Path | Status | Responsibility |
|---|---|---|
| `cert-manager-config/values.yaml` | create | Common ACME/email/server |
| `cert-manager-config/values-eks.yaml` | create | Cloudflare solver |
| `cert-manager-config/values-aks.yaml` | create | Azure DNS solver |
| `cert-manager-config/templates/clusterissuer.yaml` | modify | Solver fork based on values |
| `cert-manager-config/templates/certificate.yaml` | modify | Parameterize dnsNames for cluster |
| `traefik-config/values.yaml` | create | Common (empty or minimal) |
| `traefik-config/values-eks.yaml` | create | Existing EKS annotations (moved from default) |
| `traefik-config/values-aks.yaml` | create | `loadBalancerIP` + Azure LB resource-group annotation |
| `monitoring/values-eks.yaml` | create | gp3 storage class (moved from default) |
| `monitoring/values-aks.yaml` | create | managed-csi + Grafana host override |
| `monitoring/values.yaml` | modify | Keep common pieces; strip cluster-specific settings |
| `trakrf-backend/values-eks.yaml` | create | `ingress.host: eks.trakrf.app` |
| `trakrf-backend/values-aks.yaml` | create | `ingress.host: aks.trakrf.app` + multi-arch image tag |
| `trakrf-backend/values.yaml` | modify | Remove cluster-specific `ingress.host`, keep common |
| `trakrf-ingester/values-eks.yaml` | create | Existing EKS overrides |
| `trakrf-ingester/values-aks.yaml` | create | AKS overrides (likely minimal) |
| `trakrf-ingester/values.yaml` | modify | Keep common |
| `trakrf-db/Chart.yaml` | create | New chart metadata |
| `trakrf-db/values.yaml` | create | Common CNPG spec |
| `trakrf-db/values-eks.yaml` | create | gp3 + database-pool affinity |
| `trakrf-db/values-aks.yaml` | create | managed-csi + empty affinity |
| `trakrf-db/templates/cluster.yaml` | create | Templated CNPG `Cluster` CR |
| `cnpg/values.yaml` | create | Common CNPG operator values (empty or minimal) |
| `cnpg/values-eks.yaml` | create | EKS overrides |
| `cnpg/values-aks.yaml` | create | AKS overrides |

### ArgoCD (`argocd/`)
| Path | Status | Responsibility |
|---|---|---|
| `bootstrap/values.yaml` | modify | Keep common ArgoCD install config |
| `bootstrap/values-eks.yaml` | create | IRSA SA annotation (moved from default) |
| `bootstrap/values-aks.yaml` | create | No SA annotation |
| `root/Chart.yaml` | create | New app-of-apps chart |
| `root/values.yaml` | create | `cluster` + repoURL + tofu-output placeholders |
| `root/templates/_helpers.tpl` | create | Shared `trakrf.application` helper |
| `root/templates/argocd.yaml` | create | ArgoCD self-hosting Application |
| `root/templates/cert-manager.yaml` | create | Upstream jetstack Application w/ workload-identity SA |
| `root/templates/cert-manager-config.yaml` | create | Our chart Application |
| `root/templates/traefik.yaml` | create | Upstream traefik Application |
| `root/templates/traefik-config.yaml` | create | Our chart Application |
| `root/templates/trakrf-db.yaml` | create | Our chart Application |
| `root/templates/trakrf-backend.yaml` | create | Our chart Application |
| `root/templates/trakrf-ingester.yaml` | create | Our chart Application |
| `root.yaml` | modify | Point at `argocd/root` chart via `helm.valueFiles` |
| `applications/*.yaml` | delete | Replaced by `root/templates/` |
| `clusters/trakrf/cluster.yaml` | delete | Replaced by `helm/trakrf-db/` |

### Scripts and justfile
| Path | Status | Responsibility |
|---|---|---|
| `scripts/apply-root-app.sh` | create | Read tofu outputs, template root values, `helm upgrade --install` |
| `scripts/smoke-aks.sh` | create | Scripted precondition checks |
| `justfile` | modify | New/modified recipes: `aks-creds`, `db-secrets`, `cnpg-bootstrap CLUSTER`, `monitoring-bootstrap CLUSTER`, `argocd-bootstrap CLUSTER`, `smoke-aks` |

## Testing Approach

No unit tests per se — this is infra. Each task ends with a verification step:

- **Terraform:** `tofu -chdir=terraform/azure validate` then `tofu plan`, only apply when the diff matches expectations.
- **Helm charts:** `helm lint <chart>` and `helm template <chart> -f values.yaml -f values-aks.yaml` to confirm rendered output.
- **ArgoCD root chart:** `helm template argocd/root -f argocd/root/values.yaml` rendering 7 valid Application manifests.
- **Bash scripts:** `bash -n <script>` syntax check, then an inline dry-run where possible.
- **Live cluster:** `kubectl get applications` + `kubectl get certificate` + `dig` + `curl` against the real deployed URLs (`just smoke-aks`).

---

## Part A — Terraform additions

### Task 1: Pre-flight — confirm TRA-437 state + TRA-451 status

Not a code change. Verifies the world is as expected before we start making changes.

**Files:** none

- [ ] **Step 1: Confirm current branch**

Run:
```bash
git -C /home/mike/trakrf-infra branch --show-current
```

Expected: `feature/tra-438-aks-phase-3`. If different, `git checkout feature/tra-438-aks-phase-3`.

- [ ] **Step 2: Confirm AKS cluster from TRA-437 is still up**

Run:
```bash
tofu -chdir=terraform/azure output -raw cluster_name
tofu -chdir=terraform/azure output -raw kubectl_config_command
```

Expected: cluster name emitted (e.g. `aks-trakrf-demo-southcentralus`) and the get-credentials command prints. If `tofu output` errors, `just azure` first to refresh state.

- [ ] **Step 3: Check TRA-451 status**

Run:
```bash
gh issue view TRA-451 --repo trakrf/trakrf 2>/dev/null || echo "Linear ticket — check https://linear.app/trakrf/issue/TRA-451"
```

TRA-451 is a Linear ticket for the `trakrf/platform` repo. Check Linear for status. If not yet merged, proceed through the TF and helm refactor tasks (they don't depend on the tag). The plan pauses before Task 18 (first apply) if no multi-arch `ghcr.io/trakrf/backend` tag exists. Run:

```bash
docker buildx imagetools inspect ghcr.io/trakrf/backend:latest 2>&1 | grep -E 'Platform:\s+linux/arm64' && echo "✅ arm64 available" || echo "❌ no arm64 manifest yet"
```

If no arm64 manifest yet, TRA-451 must land before the final deploy steps.

### Task 2: Enable OIDC issuer and workload identity on AKS cluster

AKS-side prerequisites for cert-manager's workload-identity auth. Both properties are `false → true` transitions, no resource recreation (per azurerm changelog 4.69.0).

**Files:** `terraform/azure/aks.tf`

- [ ] **Step 1: Add OIDC + workload identity flags**

Edit `terraform/azure/aks.tf`. Inside the `azurerm_kubernetes_cluster "main"` block, after the `local_account_disabled = false` line and before the closing `tags =` line, add:

```hcl
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
```

- [ ] **Step 2: Validate**

Run:
```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Plan and review**

Run:
```bash
just azure
```

(Stop at the plan prompt if not auto-apply.) Expected diff: 2 in-place updates on `azurerm_kubernetes_cluster.main` — `oidc_issuer_enabled: false -> true` and `workload_identity_enabled: false -> true`. No recreate. If the plan shows a recreate, STOP and check azurerm provider version — 4.69.0 is known to handle this in-place.

- [ ] **Step 4: Apply**

Approve the plan. Expected: apply completes in ~2 min (AKS config updates). `tofu -chdir=terraform/azure output` now has an `oidc_issuer_url` data field on the cluster.

- [ ] **Step 5: Commit**

```bash
git add terraform/azure/aks.tf
git commit -m "feat(tra-438): enable AKS OIDC issuer + workload identity

Prerequisite for cert-manager Azure DNS solver via workload identity
federation. Both flags are false->true in-place updates per azurerm
4.69.0; no cluster recreate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3: Create cert-manager user-assigned identity + federated credential + DNS role

Provisions the Azure-side identity cert-manager will federate into. Scoped tightly: `DNS Zone Contributor` on the `aks.trakrf.app` zone only, not the RG or subscription.

**Files:** `terraform/azure/cert_manager.tf` (create)

- [ ] **Step 1: Write `cert_manager.tf`**

Create `terraform/azure/cert_manager.tf`:

```hcl
# User-assigned identity that cert-manager pods federate into via the AKS OIDC issuer.
# Scoped to DNS Zone Contributor on aks.trakrf.app ONLY — solver needs TXT record
# create/delete for _acme-challenge.* during DNS-01.
resource "azurerm_user_assigned_identity" "cert_manager" {
  name                = "id-cert-manager-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = local.common_tags
}

# Federated credential binds the cert-manager Kubernetes SA to the UAI.
# Subject must match the actual SA namespace/name exactly — the cert-manager
# Helm chart's default SA is `cert-manager` in the `cert-manager` namespace.
resource "azurerm_federated_identity_credential" "cert_manager" {
  name                = "fc-cert-manager-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.cert_manager.id
  subject             = "system:serviceaccount:cert-manager:cert-manager"
}

# Tight scope: only the aks.trakrf.app DNS zone resource. Does NOT grant
# access to other zones or to the resource group.
resource "azurerm_role_assignment" "cert_manager_dns" {
  principal_id                     = azurerm_user_assigned_identity.cert_manager.principal_id
  role_definition_name             = "DNS Zone Contributor"
  scope                            = azurerm_dns_zone.aks_trakrf_app.id
  skip_service_principal_aad_check = true
}
```

- [ ] **Step 2: Validate**

Run:
```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success!`.

- [ ] **Step 3: Plan and apply**

Run:
```bash
just azure
```

Expected diff: 3 creates — the UAI, federated credential, role assignment. No changes elsewhere. Apply. Takes ~30s. Role assignment may take up to 2 min to propagate before first cert issuance works; that's fine, cert-manager retries.

- [ ] **Step 4: Commit**

```bash
git add terraform/azure/cert_manager.tf
git commit -m "feat(tra-438): cert-manager Azure identity + DNS role

User-assigned identity federated to the cert-manager SA via AKS OIDC
issuer. DNS Zone Contributor scoped to aks.trakrf.app zone only —
no access to other zones or the RG.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4: Create Traefik static public IP + Network Contributor role

IP stability across cluster rebuilds. The IP lives in the main RG (not the AKS-managed `MC_` RG) — so the AKS cluster identity needs `Network Contributor` on the main RG for cloud-controller-manager to bind the IP.

**Files:** `terraform/azure/traefik_lb.tf` (create)

- [ ] **Step 1: Write `traefik_lb.tf`**

Create `terraform/azure/traefik_lb.tf`:

```hcl
# Static public IP for Traefik's LoadBalancer Service. Lives in the main RG
# (not the auto-created MC_ RG) so it survives cluster rebuilds. prevent_destroy
# guards against accidental rotation — TF-managed A records in dns.tf depend on
# this IP being stable.
resource "azurerm_public_ip" "traefik" {
  name                = "pip-traefik-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = [var.primary_pool_zone]

  tags = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

# AKS cluster identity needs Network Contributor on main RG to bind the PIP
# to the LB created by cloud-controller-manager when Traefik Service comes up.
# Required because the PIP is OUTSIDE the auto-created MC_ resource group.
resource "azurerm_role_assignment" "aks_network_contributor_main_rg" {
  principal_id                     = azurerm_kubernetes_cluster.main.identity[0].principal_id
  role_definition_name             = "Network Contributor"
  scope                            = azurerm_resource_group.main.id
  skip_service_principal_aad_check = true
}
```

- [ ] **Step 2: Validate + plan + apply**

Run:
```bash
tofu -chdir=terraform/azure validate
just azure
```

Expected diff: 2 creates — the PIP and the role assignment. The PIP acquires a static address; capture it for reference but don't hardcode anywhere (outputs.tf handles it).

- [ ] **Step 3: Commit**

```bash
git add terraform/azure/traefik_lb.tf
git commit -m "feat(tra-438): static PIP for Traefik LB + Network Contributor

PIP in main RG (not MC_) for cross-rebuild IP stability. prevent_destroy
protects the address — DNS records depend on it. AKS identity gets
Network Contributor on main RG so cloud-controller can bind the IP
when Traefik's LoadBalancer Service comes up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5: Add apex + wildcard A records for aks.trakrf.app

TF-managed DNS records pointing at the static PIP from Task 4.

**Files:** `terraform/azure/dns.tf` (modify)

- [ ] **Step 1: Append A records to `dns.tf`**

Open `terraform/azure/dns.tf`. After the existing `azurerm_dns_zone.aks_trakrf_app` block (around line 15), append:

```hcl
# Apex A record — browser hits https://aks.trakrf.app
resource "azurerm_dns_a_record" "aks_apex" {
  name                = "@"
  zone_name           = azurerm_dns_zone.aks_trakrf_app.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.traefik.ip_address]

  tags = local.common_tags
}

# Wildcard — grafana.aks.trakrf.app, anything.aks.trakrf.app
resource "azurerm_dns_a_record" "aks_wildcard" {
  name                = "*"
  zone_name           = azurerm_dns_zone.aks_trakrf_app.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.traefik.ip_address]

  tags = local.common_tags
}
```

- [ ] **Step 2: Validate + plan + apply**

Run:
```bash
tofu -chdir=terraform/azure validate
just azure
```

Expected diff: 2 creates — the apex and wildcard A records. Apply.

- [ ] **Step 3: Verify DNS resolves (may take 1-5 min for propagation)**

Run:
```bash
dig +short aks.trakrf.app
dig +short foo.aks.trakrf.app
```

Expected: both return the PIP IP (same value). If empty, wait 1 min and retry — Cloudflare's NS delegation to Azure DNS needs a round-trip on first lookup.

- [ ] **Step 4: Commit**

```bash
git add terraform/azure/dns.tf
git commit -m "feat(tra-438): apex + wildcard A records for aks.trakrf.app

Points aks.trakrf.app and *.aks.trakrf.app at the Traefik static PIP.
TTL 300 during demo tuning; can raise to 3600 once stable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 6: Expose outputs for downstream helm values

Tofu outputs consumed by `scripts/apply-root-app.sh` at bootstrap time.

**Files:** `terraform/azure/outputs.tf` (modify)

- [ ] **Step 1: Append new outputs**

Open `terraform/azure/outputs.tf`. Append at the end:

```hcl
# Cert-manager workload identity — used as SA annotation in argocd/root/values.yaml
output "cert_manager_identity_client_id" {
  description = "Client ID of the cert-manager user-assigned identity"
  value       = azurerm_user_assigned_identity.cert_manager.client_id
}

# Tenant ID — needed for Azure DNS solver config in the ClusterIssuer
output "tenant_id" {
  description = "Entra tenant ID for workload identity token exchange"
  value       = data.azuread_client_config.current.tenant_id
}

# Subscription ID — needed for Azure DNS solver config
output "subscription_id" {
  description = "Subscription the DNS zone lives in (solver needs it)"
  value       = data.azurerm_client_config.current.subscription_id
}

# DNS zone resource group — currently the main RG but expose explicitly so
# values don't hardcode it (future: split zones per RG for prod separation).
output "dns_zone_resource_group" {
  description = "Resource group the aks.trakrf.app zone lives in"
  value       = azurerm_resource_group.main.name
}

# Traefik LB IP — used as loadBalancerIP in values-aks.yaml
output "traefik_lb_ip" {
  description = "Static IP for Traefik's LoadBalancer Service"
  value       = azurerm_public_ip.traefik.ip_address
}

# Main RG name — used as the azure-load-balancer-resource-group annotation
output "main_resource_group_name" {
  description = "Main RG name; used as Traefik Service annotation when LB is not in MC_ RG"
  value       = azurerm_resource_group.main.name
}
```

- [ ] **Step 2: Add the `azurerm_client_config` data source**

The subscription output needs a data source that doesn't currently exist in the module. Open `terraform/azure/identity.tf` (which already has `data "azuread_client_config" "current"`) and append:

```hcl
# azurerm client config — exposes the subscription + tenant of the TF session
data "azurerm_client_config" "current" {}
```

- [ ] **Step 3: Validate + apply**

Run:
```bash
tofu -chdir=terraform/azure validate
just azure
```

Expected: no resource changes, just outputs (added). `tofu apply` with only output changes is fast.

- [ ] **Step 4: Verify outputs resolve**

Run:
```bash
tofu -chdir=terraform/azure output -raw cert_manager_identity_client_id
tofu -chdir=terraform/azure output -raw traefik_lb_ip
tofu -chdir=terraform/azure output -raw tenant_id
tofu -chdir=terraform/azure output -raw dns_zone_resource_group
```

All four should print non-empty UUIDs / IPs / names.

- [ ] **Step 5: Commit**

```bash
git add terraform/azure/outputs.tf terraform/azure/identity.tf
git commit -m "feat(tra-438): expose outputs for helm values wiring

Six outputs consumed by scripts/apply-root-app.sh when templating
argocd/root/values.yaml: cert-manager identity client_id, tenant_id,
subscription_id, dns zone RG, traefik LB IP, main RG name. Adds the
azurerm_client_config data source used by subscription_id.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Part B — Helm chart refactor (values-overlay pattern)

### Task 7: Split `helm/cert-manager-config/` values + solver fork

Most complex chart to split — has both values split AND a template fork (Cloudflare vs Azure DNS solver). Also parameterizes the cert SAN list (currently hardcoded to `trakrf.app` + `*.eks.trakrf.app`).

**Files:**
- Create: `helm/cert-manager-config/values.yaml`
- Create: `helm/cert-manager-config/values-eks.yaml`
- Create: `helm/cert-manager-config/values-aks.yaml`
- Modify: `helm/cert-manager-config/templates/clusterissuer.yaml`
- Modify: `helm/cert-manager-config/templates/certificate.yaml`

- [ ] **Step 1: Create common `values.yaml`**

```yaml
# helm/cert-manager-config/values.yaml
# Common ACME config — cluster-specific solver goes in values-<cluster>.yaml

acme:
  email: admin@trakrf.id
  server: https://acme-v02.api.letsencrypt.org/directory
  privateKeySecretRef: letsencrypt-prod-account-key

issuer:
  name: letsencrypt-prod

# Solver type: "cloudflare" or "azureDNS"
# Overridden in values-<cluster>.yaml
solver: ""

# Certificate SAN list — overridden per cluster
certificate:
  name: trakrf-wildcard
  namespace: traefik
  secretName: trakrf-wildcard-tls
  commonName: ""
  dnsNames: []
```

- [ ] **Step 2: Create `values-eks.yaml`**

```yaml
# helm/cert-manager-config/values-eks.yaml
# EKS uses Cloudflare DNS-01 solver (existing behavior, preserved for future rebuild)

solver: cloudflare

cloudflare:
  apiTokenSecretName: cloudflare-api-token
  apiTokenSecretKey: api-token
  zones:
    - trakrf.app

certificate:
  name: trakrf-app-wildcard
  commonName: trakrf.app
  dnsNames:
    - trakrf.app
    - "*.trakrf.app"
    - "*.eks.trakrf.app"
```

- [ ] **Step 3: Create `values-aks.yaml`**

`<CLIENT_ID>`, `<TENANT_ID>`, `<SUB_ID>`, `<ZONE_RG>` are placeholders — `scripts/apply-root-app.sh` will substitute them at bootstrap time from tofu outputs. The values file itself holds the placeholder strings for review; rendering happens in Task 15's Application manifest which passes computed values via `helm.values` inline.

```yaml
# helm/cert-manager-config/values-aks.yaml
# AKS uses Azure DNS solver via workload identity
# Real values come from argocd/root/templates/cert-manager-config.yaml which
# injects tofu outputs via helm.values — the placeholders below are docs only.

solver: azureDNS

azureDNS:
  hostedZoneName: aks.trakrf.app
  resourceGroupName: <ZONE_RG>           # injected from tofu dns_zone_resource_group
  subscriptionID: <SUB_ID>               # injected from tofu subscription_id
  tenantID: <TENANT_ID>                  # injected from tofu tenant_id
  managedIdentity:
    clientID: <CLIENT_ID>                # injected from tofu cert_manager_identity_client_id

certificate:
  name: trakrf-aks-wildcard
  commonName: aks.trakrf.app
  dnsNames:
    - aks.trakrf.app
    - "*.aks.trakrf.app"
```

- [ ] **Step 4: Rewrite `templates/clusterissuer.yaml` with solver fork**

```yaml
# helm/cert-manager-config/templates/clusterissuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: {{ .Values.issuer.name }}
spec:
  acme:
    server: {{ .Values.acme.server }}
    email: {{ .Values.acme.email }}
    privateKeySecretRef:
      name: {{ .Values.acme.privateKeySecretRef }}
    solvers:
      {{- if eq .Values.solver "cloudflare" }}
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: {{ .Values.cloudflare.apiTokenSecretName }}
              key: {{ .Values.cloudflare.apiTokenSecretKey }}
        selector:
          dnsZones:
            {{- range .Values.cloudflare.zones }}
            - {{ . }}
            {{- end }}
      {{- else if eq .Values.solver "azureDNS" }}
      - dns01:
          azureDNS:
            hostedZoneName: {{ .Values.azureDNS.hostedZoneName }}
            resourceGroupName: {{ .Values.azureDNS.resourceGroupName }}
            subscriptionID: {{ .Values.azureDNS.subscriptionID }}
            tenantID: {{ .Values.azureDNS.tenantID }}
            managedIdentity:
              clientID: {{ .Values.azureDNS.managedIdentity.clientID }}
        selector:
          dnsZones:
            - {{ .Values.azureDNS.hostedZoneName }}
      {{- else }}
      {{- fail (printf "Unknown solver type: %q (expected 'cloudflare' or 'azureDNS')" .Values.solver) }}
      {{- end }}
```

- [ ] **Step 5: Parameterize `templates/certificate.yaml`**

```yaml
# helm/cert-manager-config/templates/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .Values.certificate.name }}
  namespace: {{ .Values.certificate.namespace }}
spec:
  secretName: {{ .Values.certificate.secretName }}
  issuerRef:
    name: {{ .Values.issuer.name }}
    kind: ClusterIssuer
  commonName: {{ .Values.certificate.commonName }}
  dnsNames:
    {{- range .Values.certificate.dnsNames }}
    - {{ . | quote }}
    {{- end }}
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
```

- [ ] **Step 6: Lint + render both overlays**

Run:
```bash
helm lint helm/cert-manager-config -f helm/cert-manager-config/values.yaml -f helm/cert-manager-config/values-eks.yaml
helm lint helm/cert-manager-config -f helm/cert-manager-config/values.yaml -f helm/cert-manager-config/values-aks.yaml
```

Both expected: `1 chart(s) linted, 0 chart(s) failed`.

Run:
```bash
helm template helm/cert-manager-config -f helm/cert-manager-config/values.yaml -f helm/cert-manager-config/values-eks.yaml | grep -A5 'solvers:'
```

Expected: shows the `cloudflare:` block.

Run:
```bash
helm template helm/cert-manager-config -f helm/cert-manager-config/values.yaml -f helm/cert-manager-config/values-aks.yaml | grep -A8 'solvers:'
```

Expected: shows the `azureDNS:` block with placeholder strings (the real values come from the root-app Application's inline helm values).

- [ ] **Step 7: Commit**

```bash
git add helm/cert-manager-config/
git commit -m "refactor(tra-438): parameterize cert-manager-config for multi-cluster

Introduces values.yaml + values-eks.yaml + values-aks.yaml overlay
pattern. ClusterIssuer template forks solver by .Values.solver
('cloudflare' | 'azureDNS'); Certificate template parameterizes the
SAN list. EKS behavior preserved in values-eks.yaml.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 8: Split `helm/traefik-config/` values

Simpler — Traefik config values only.

**Files:**
- Create: `helm/traefik-config/values.yaml` (if doesn't exist)
- Create: `helm/traefik-config/values-eks.yaml`
- Create: `helm/traefik-config/values-aks.yaml`

- [ ] **Step 1: Inspect existing chart structure**

Run:
```bash
ls helm/traefik-config/
find helm/traefik-config/templates -type f
```

Note which templates exist and whether a `values.yaml` is already there.

- [ ] **Step 2: Create or update `values.yaml` with common defaults**

If absent, create:

```yaml
# helm/traefik-config/values.yaml
# Common Traefik-config defaults. Cluster-specific LB annotations go in overlays.

tlsStore:
  name: default
  defaultCertificate:
    secretName: trakrf-wildcard-tls
```

(Adjust `secretName` to match the cert-manager Certificate `secretName` from Task 7 for the current cluster — actually, better: parameterize per cluster.)

Update so `secretName` uses a value key that overlays can set:

```yaml
tlsStore:
  name: default
  defaultCertificateSecret: trakrf-wildcard-tls
```

- [ ] **Step 3: Create `values-eks.yaml`**

```yaml
# helm/traefik-config/values-eks.yaml
tlsStore:
  defaultCertificateSecret: trakrf-wildcard-tls
```

(Matches the EKS-era Certificate secret name.)

- [ ] **Step 4: Create `values-aks.yaml`**

```yaml
# helm/traefik-config/values-aks.yaml
tlsStore:
  defaultCertificateSecret: trakrf-aks-wildcard-tls
```

Matches `certificate.secretName` in cert-manager-config/values-aks.yaml — wait, I set that to `trakrf-wildcard-tls` in the common values. Let me re-check. (NOTE to engineer: both EKS and AKS use `trakrf-wildcard-tls` as the Certificate `secretName` in the common values.yaml of cert-manager-config. So both cluster overlays here should reference `trakrf-wildcard-tls`. Update both values-eks.yaml and values-aks.yaml to use the same `trakrf-wildcard-tls` unless you have a reason to differentiate — the Certificate resource's secretName is what Traefik's TLSStore needs to reference.)

Final answer for this step:

```yaml
# helm/traefik-config/values-aks.yaml
# AKS uses the same secret name as EKS did — cert-manager-config common values
# set certificate.secretName to trakrf-wildcard-tls for both clusters.
tlsStore:
  defaultCertificateSecret: trakrf-wildcard-tls
```

- [ ] **Step 5: Verify template references the keys**

Open `helm/traefik-config/templates/tlsstore.yaml` (or whatever the file is named). Ensure it uses `.Values.tlsStore.defaultCertificateSecret`, not a hardcoded string. If hardcoded, parameterize:

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: {{ .Values.tlsStore.name }}
  namespace: traefik
spec:
  defaultCertificate:
    secretName: {{ .Values.tlsStore.defaultCertificateSecret }}
```

- [ ] **Step 6: Lint + render**

Run:
```bash
helm lint helm/traefik-config -f helm/traefik-config/values.yaml -f helm/traefik-config/values-aks.yaml
helm template helm/traefik-config -f helm/traefik-config/values.yaml -f helm/traefik-config/values-aks.yaml
```

Expected: clean lint, rendered TLSStore with `secretName: trakrf-wildcard-tls`.

- [ ] **Step 7: Commit**

```bash
git add helm/traefik-config/
git commit -m "refactor(tra-438): parameterize traefik-config for multi-cluster

Values-overlay split; TLSStore secretName templated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 9: Split `helm/monitoring/` values

Kube-prometheus-stack wrapper values. The chart is NOT deployed via ArgoCD — `just monitoring-bootstrap CLUSTER` keeps applying it directly (see Task 18).

**Files:**
- Modify: `helm/monitoring/values.yaml`
- Create: `helm/monitoring/values-eks.yaml`
- Create: `helm/monitoring/values-aks.yaml`

- [ ] **Step 1: Read current `helm/monitoring/values.yaml`**

Run:
```bash
cat helm/monitoring/values.yaml
```

Note every `storageClassName`, `storageClass`, ingress `host`, and any other cluster-specific field.

- [ ] **Step 2: Split storage class + Grafana host into `values-eks.yaml`**

Move EKS-specific values to `helm/monitoring/values-eks.yaml`:

```yaml
# helm/monitoring/values-eks.yaml
# EKS-specific monitoring overrides (preserved from original values.yaml)

# StorageClass references
grafana:
  persistence:
    storageClassName: gp3
  ingress:
    enabled: true
    hosts:
      - grafana.eks.trakrf.app

prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
```

(Adjust to match the actual keys/values that were previously in `values.yaml`. The engineer should compare the new `values.yaml` + `values-eks.yaml` to the pre-change `values.yaml` and confirm no EKS-specific settings were lost.)

- [ ] **Step 3: Create `values-aks.yaml`**

```yaml
# helm/monitoring/values-aks.yaml
# AKS-specific monitoring overrides

grafana:
  persistence:
    storageClassName: managed-csi
  ingress:
    enabled: true
    hosts:
      - grafana.aks.trakrf.app

prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-csi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-csi
```

- [ ] **Step 4: Clean `values.yaml` (remove EKS-specific, keep common)**

Edit `helm/monitoring/values.yaml` — remove the keys that now live in `values-eks.yaml` (`gp3` refs, EKS Grafana host). Keep common values: scrape configs, dashboard labels, resource limits, namespace overrides, etc.

- [ ] **Step 5: Lint + render**

Run:
```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 83.4.1 \
  -f helm/monitoring/values.yaml \
  -f helm/monitoring/values-aks.yaml \
  --namespace monitoring \
  | grep -E 'storageClassName|host:' | head -10
```

Expected: `managed-csi` for storageClassName, `grafana.aks.trakrf.app` for Grafana host.

- [ ] **Step 6: Commit**

```bash
git add helm/monitoring/
git commit -m "refactor(tra-438): parameterize monitoring storage class + host

EKS gp3 behavior moves to values-eks.yaml; AKS uses managed-csi +
grafana.aks.trakrf.app.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 10: Split `helm/trakrf-backend/` values

Backend app — just ingress host + image tag overrides.

**Files:**
- Modify: `helm/trakrf-backend/values.yaml`
- Create: `helm/trakrf-backend/values-eks.yaml`
- Create: `helm/trakrf-backend/values-aks.yaml`

- [ ] **Step 1: Create `values-eks.yaml`**

Capture the current EKS defaults from `values.yaml`:

```yaml
# helm/trakrf-backend/values-eks.yaml
# EKS overrides (preserved from original values.yaml)

ingress:
  host: eks.trakrf.app

image:
  tag: sha-9f22fac
```

- [ ] **Step 2: Create `values-aks.yaml`**

```yaml
# helm/trakrf-backend/values-aks.yaml
# AKS overrides. Image tag MUST be a multi-arch tag published after TRA-451.

ingress:
  host: aks.trakrf.app

image:
  tag: "REPLACE_WITH_MULTI_ARCH_TAG"
```

(Yes, this is a placeholder — it WILL fail helm template until a real tag is subbed in. That's intentional — forces explicit action in Task 18 rather than silently picking up a stale tag.)

- [ ] **Step 3: Clean `values.yaml`**

Edit `helm/trakrf-backend/values.yaml`:
- Change `image.tag: sha-9f22fac` → `image.tag: ""` (or delete the key; documented that overlay MUST provide it)
- Change `ingress.host: eks.trakrf.app` → `ingress.host: ""` (or leave for default)

- [ ] **Step 4: Verify templates handle empty `image.tag` correctly**

Run:
```bash
grep -n 'image.tag' helm/trakrf-backend/templates/*.yaml
```

The templates currently render `"{{ .Values.image.repository }}:{{ .Values.image.tag }}"`. If `.Values.image.tag` is empty, the rendered image ref becomes `ghcr.io/trakrf/backend:` — malformed. Add a required-ness check in `templates/deployment.yaml` and `templates/migrate-job.yaml`:

Change:
```yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

To:
```yaml
image: "{{ .Values.image.repository }}:{{ required "image.tag must be set (usually in values-<cluster>.yaml)" .Values.image.tag }}"
```

- [ ] **Step 5: Lint + render (expect AKS render to fail until tag subbed)**

```bash
helm lint helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-eks.yaml
```

Expected: clean.

```bash
helm lint helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-aks.yaml
```

Expected: clean if `REPLACE_WITH_MULTI_ARCH_TAG` is non-empty (it is); the string will render in the image ref but is obviously wrong — that's the intent. It'll be replaced in Task 18 once a real tag exists.

- [ ] **Step 6: Commit**

```bash
git add helm/trakrf-backend/
git commit -m "refactor(tra-438): parameterize trakrf-backend image tag + host

Image tag required from overlay; ingress.host moves per cluster.
AKS overlay uses a placeholder tag as a forcing function — it'll be
bumped to a real multi-arch tag (TRA-451) before first AKS deploy.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 11: Split `helm/trakrf-ingester/` values

Same pattern — ingester uses upstream Redpanda Connect image (already multi-arch), so only ingress/config overrides.

**Files:**
- Modify: `helm/trakrf-ingester/values.yaml`
- Create: `helm/trakrf-ingester/values-eks.yaml`
- Create: `helm/trakrf-ingester/values-aks.yaml`

- [ ] **Step 1: Create `values-eks.yaml` capturing existing behavior**

```yaml
# helm/trakrf-ingester/values-eks.yaml
ingress:
  host: eks.trakrf.app   # adjust to match current EKS ingester ingress host
```

(Inspect `helm/trakrf-ingester/values.yaml` and `templates/*.yaml` first — if the ingester doesn't expose an ingress, the overlay can be empty.)

- [ ] **Step 2: Create `values-aks.yaml`**

```yaml
# helm/trakrf-ingester/values-aks.yaml
ingress:
  host: aks.trakrf.app
```

Or empty if no ingress.

- [ ] **Step 3: Strip cluster-specifics from `values.yaml`**

Edit `helm/trakrf-ingester/values.yaml` — remove `host: eks.trakrf.app` if present, leaving common values.

- [ ] **Step 4: Lint both overlays**

```bash
helm lint helm/trakrf-ingester -f helm/trakrf-ingester/values.yaml -f helm/trakrf-ingester/values-eks.yaml
helm lint helm/trakrf-ingester -f helm/trakrf-ingester/values.yaml -f helm/trakrf-ingester/values-aks.yaml
```

- [ ] **Step 5: Commit**

```bash
git add helm/trakrf-ingester/
git commit -m "refactor(tra-438): parameterize trakrf-ingester for multi-cluster

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 12: Create `helm/trakrf-db/` chart (wrap CNPG Cluster CR)

Port the bare `argocd/clusters/trakrf/cluster.yaml` into a parameterized Helm chart.

**Files:**
- Create: `helm/trakrf-db/Chart.yaml`
- Create: `helm/trakrf-db/values.yaml`
- Create: `helm/trakrf-db/values-eks.yaml`
- Create: `helm/trakrf-db/values-aks.yaml`
- Create: `helm/trakrf-db/templates/cluster.yaml`

- [ ] **Step 1: `Chart.yaml`**

```yaml
apiVersion: v2
name: trakrf-db
description: TrakRF CNPG+Timescale database cluster
type: application
version: 0.1.0
```

- [ ] **Step 2: `values.yaml` (common)**

Port 1:1 from the existing `argocd/clusters/trakrf/cluster.yaml` — everything except storage class and affinity:

```yaml
# helm/trakrf-db/values.yaml
# Common CNPG+Timescale defaults. Storage class + affinity per cluster overlay.

fullnameOverride: trakrf-db

cluster:
  instances: 1
  imageName: ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18

postgresql:
  sharedPreloadLibraries:
    - timescaledb
  parameters:
    timescaledb.license: timescale
    password_encryption: scram-sha-256

bootstrap:
  initdb:
    database: trakrf
    owner: trakrf-migrate
    postInitTemplateSQL:
      - CREATE EXTENSION IF NOT EXISTS timescaledb
    postInitSQL:
      - CREATE ROLE "trakrf-app" LOGIN
    postInitApplicationSQL:
      - CREATE SCHEMA trakrf AUTHORIZATION "trakrf-migrate"
      - GRANT CONNECT ON DATABASE trakrf TO "trakrf-app"
      - GRANT USAGE ON SCHEMA trakrf TO "trakrf-app"
      - ALTER DEFAULT PRIVILEGES FOR ROLE "trakrf-migrate" IN SCHEMA trakrf GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "trakrf-app"
      - ALTER DEFAULT PRIVILEGES FOR ROLE "trakrf-migrate" IN SCHEMA trakrf GRANT USAGE, SELECT ON SEQUENCES TO "trakrf-app"

managedRoles:
  - name: trakrf-app
    ensure: present
    login: true
    superuser: false
    createdb: false
    createrole: false
    passwordSecretName: trakrf-app-credentials
  - name: trakrf-migrate
    ensure: present
    login: true
    superuser: false
    createdb: true
    createrole: false
    passwordSecretName: trakrf-migrate-credentials

storage:
  size: 10Gi
  class: ""                # overlay sets this

# Pod affinity/tolerations — overlay sets; EKS uses dedicated DB pool, AKS runs on primary
affinity:
  nodeSelector: {}
  tolerations: []
```

- [ ] **Step 3: `values-eks.yaml`**

```yaml
# helm/trakrf-db/values-eks.yaml
# EKS pins the DB to the dedicated single-AZ database node group for PV stability (TRA-364).

storage:
  class: gp3

affinity:
  nodeSelector:
    workload: database
  tolerations:
    - key: workload
      operator: Equal
      value: database
      effect: NoSchedule
```

- [ ] **Step 4: `values-aks.yaml`**

```yaml
# helm/trakrf-db/values-aks.yaml
# AKS topology (per project_aks_demo_topology memory): single on-demand primary
# node runs everything. No separate DB pool, no affinity — scheduler picks the
# only available node.

storage:
  class: managed-csi

# affinity intentionally empty (inherited defaults: nodeSelector {}, tolerations [])
```

- [ ] **Step 5: `templates/cluster.yaml`**

```yaml
# helm/trakrf-db/templates/cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ .Values.fullnameOverride | default "trakrf-db" }}
  namespace: {{ .Release.Namespace }}
spec:
  instances: {{ .Values.cluster.instances }}
  imageName: {{ .Values.cluster.imageName | quote }}

  postgresql:
    shared_preload_libraries:
      {{- range .Values.postgresql.sharedPreloadLibraries }}
      - {{ . }}
      {{- end }}
    parameters:
      {{- range $k, $v := .Values.postgresql.parameters }}
      {{ $k }}: {{ $v | quote }}
      {{- end }}

  bootstrap:
    initdb:
      database: {{ .Values.bootstrap.initdb.database }}
      owner: {{ .Values.bootstrap.initdb.owner | quote }}
      postInitTemplateSQL:
        {{- range .Values.bootstrap.initdb.postInitTemplateSQL }}
        - {{ . | quote }}
        {{- end }}
      postInitSQL:
        {{- range .Values.bootstrap.initdb.postInitSQL }}
        - {{ . | quote }}
        {{- end }}
      postInitApplicationSQL:
        {{- range .Values.bootstrap.initdb.postInitApplicationSQL }}
        - {{ . | quote }}
        {{- end }}

  managed:
    roles:
      {{- range .Values.managedRoles }}
      - name: {{ .name | quote }}
        ensure: {{ .ensure }}
        login: {{ .login }}
        superuser: {{ .superuser }}
        createdb: {{ .createdb | default false }}
        createrole: {{ .createrole | default false }}
        passwordSecret:
          name: {{ .passwordSecretName }}
      {{- end }}

  storage:
    size: {{ .Values.storage.size }}
    storageClass: {{ required "storage.class must be set in values-<cluster>.yaml" .Values.storage.class | quote }}

  {{- if or .Values.affinity.nodeSelector .Values.affinity.tolerations }}
  affinity:
    {{- with .Values.affinity.nodeSelector }}
    nodeSelector:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.affinity.tolerations }}
    tolerations:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  {{- end }}
```

- [ ] **Step 6: Lint + render both overlays**

```bash
helm lint helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-eks.yaml
helm lint helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-aks.yaml
```

Both expected: clean.

```bash
helm template trakrf-db helm/trakrf-db \
  -f helm/trakrf-db/values.yaml \
  -f helm/trakrf-db/values-aks.yaml \
  --namespace trakrf | head -50
```

Expected output: a CNPG `Cluster` CR with `storageClass: managed-csi` and no affinity block. Compare to the current bare CR at `argocd/clusters/trakrf/cluster.yaml` — all fields present except storage + affinity (which are the cluster-specific ones).

- [ ] **Step 7: Commit**

```bash
git add helm/trakrf-db/
git commit -m "feat(tra-438): new helm/trakrf-db/ chart wrapping CNPG Cluster CR

1:1 port of argocd/clusters/trakrf/cluster.yaml with storage class
and affinity parameterized per cluster. EKS overlay preserves the
database-pool pinning from TRA-364; AKS runs on primary (per
project_aks_demo_topology memory).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 13: Create `helm/cnpg/` values-only wrapper for direct helm install

Just values overlays for the upstream `cnpg/cloudnative-pg` operator chart — no templates.

**Files:**
- Create: `helm/cnpg/values.yaml`
- Create: `helm/cnpg/values-eks.yaml`
- Create: `helm/cnpg/values-aks.yaml`

- [ ] **Step 1: `values.yaml`**

```yaml
# helm/cnpg/values.yaml
# Common CNPG operator overrides for the upstream cnpg/cloudnative-pg chart.

# TRA-360 note: Clevyr's 17.2-ts2.18 image works with operator 0.28.x.
# Keep operator version pinned by `just cnpg-bootstrap CLUSTER` helm invocation.

replicaCount: 1

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

- [ ] **Step 2: `values-eks.yaml`**

```yaml
# helm/cnpg/values-eks.yaml
# EKS overrides (empty for now — operator runs on default node selector)
```

(File exists but intentionally empty, as a scaffold.)

- [ ] **Step 3: `values-aks.yaml`**

```yaml
# helm/cnpg/values-aks.yaml
# AKS overrides (empty for now — single-pool topology, no special scheduling)
```

- [ ] **Step 4: Add a note to `helm/cnpg/README.md` (new)**

```markdown
# helm/cnpg/ — CNPG operator values

This directory holds **values overlays only** for the upstream
`cnpg/cloudnative-pg` chart. No templates. Applied via:

    just cnpg-bootstrap <cluster>

CNPG stays out of ArgoCD by design — its pre-install hooks depend on
CRDs the same chart installs (chicken-and-egg). See
`docs/superpowers/specs/2026-04-12-trakrf-db-design.md`.
```

- [ ] **Step 5: Commit**

```bash
git add helm/cnpg/
git commit -m "feat(tra-438): helm/cnpg/ values wrapper for CNPG operator

Values-only wrapper (no templates) for upstream cnpg/cloudnative-pg
chart. Applied via 'just cnpg-bootstrap <cluster>' — operator stays
out of ArgoCD per existing pattern (CNPG CRD chicken-and-egg).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 14: Split `argocd/bootstrap/` values

ArgoCD install values. EKS had IRSA annotations; AKS has none for ArgoCD itself.

**Files:**
- Modify: `argocd/bootstrap/values.yaml`
- Create: `argocd/bootstrap/values-eks.yaml`
- Create: `argocd/bootstrap/values-aks.yaml`

- [ ] **Step 1: Inspect current values.yaml**

```bash
cat argocd/bootstrap/values.yaml
```

Identify IRSA-specific blocks (`eks.amazonaws.com/role-arn` annotations, AWS account IDs).

- [ ] **Step 2: Move EKS-specific bits to `values-eks.yaml`**

```yaml
# argocd/bootstrap/values-eks.yaml
# IRSA annotations for EKS — captured from pre-TRA-438 values.yaml

controller:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::252374924199:role/trakrf-demo-argocd"

server:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::252374924199:role/trakrf-demo-argocd"
```

(Adjust keys/ARN to match what's actually in the existing values.yaml. The engineer: if there are no IRSA annotations on ArgoCD SAs in the current file, create `values-eks.yaml` empty — scaffold for symmetry.)

- [ ] **Step 3: Create `values-aks.yaml`**

```yaml
# argocd/bootstrap/values-aks.yaml
# AKS — ArgoCD doesn't need Azure API access, no SA annotations
```

(File exists, empty. ArgoCD reads from git, deploys to cluster — no cloud-side API calls.)

- [ ] **Step 4: Clean `values.yaml`**

Remove the IRSA annotations now in `values-eks.yaml`. Keep common ArgoCD config (resources, HA, server flags, etc.).

- [ ] **Step 5: Render check**

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm template argocd argo/argo-cd \
  -f argocd/bootstrap/values.yaml \
  -f argocd/bootstrap/values-aks.yaml \
  --namespace argocd | grep -E 'serviceAccount:|annotations:' | head -10
```

AKS render should NOT contain the `eks.amazonaws.com` annotation. EKS render (swap the values-aks → values-eks) SHOULD.

- [ ] **Step 6: Commit**

```bash
git add argocd/bootstrap/
git commit -m "refactor(tra-438): split argocd/bootstrap values per cluster

IRSA annotations move to values-eks.yaml; AKS overlay empty (ArgoCD
needs no Azure-side identity in this phase).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Part C — ArgoCD root app-of-apps chart

### Task 15: Create `argocd/root/` Helm chart

The single-touchpoint chart. Wraps Application manifests as Helm templates so cluster + tofu outputs substitute into valueFiles paths and inline helm values.

**Files:**
- Create: `argocd/root/Chart.yaml`
- Create: `argocd/root/values.yaml`
- Create: `argocd/root/templates/_helpers.tpl`
- Create: `argocd/root/templates/argocd.yaml`
- Create: `argocd/root/templates/cert-manager.yaml`
- Create: `argocd/root/templates/cert-manager-config.yaml`
- Create: `argocd/root/templates/traefik.yaml`
- Create: `argocd/root/templates/traefik-config.yaml`
- Create: `argocd/root/templates/trakrf-db.yaml`
- Create: `argocd/root/templates/trakrf-backend.yaml`
- Create: `argocd/root/templates/trakrf-ingester.yaml`

- [ ] **Step 1: `Chart.yaml`**

```yaml
apiVersion: v2
name: trakrf-root
description: TrakRF app-of-apps — ArgoCD Applications composed per cluster
type: application
version: 0.1.0
```

- [ ] **Step 2: `values.yaml`**

```yaml
# argocd/root/values.yaml
# ===
# THE TOUCHPOINT: flip `cluster` to target a different cluster overlay.
# All other values are injected by scripts/apply-root-app.sh from tofu outputs.
# ===

cluster: aks

repoURL: https://github.com/trakrf/infra.git
targetRevision: main

destination:
  server: https://kubernetes.default.svc

namespaces:
  argocd: argocd
  certManager: cert-manager
  traefik: traefik
  trakrf: trakrf

# Tofu output placeholders (populated by scripts/apply-root-app.sh at install time)
certManagerIdentityClientId: ""
tenantId: ""
subscriptionId: ""
dnsZoneResourceGroup: ""
traefikLbIp: ""
mainResourceGroupName: ""
```

- [ ] **Step 3: `templates/_helpers.tpl`**

```yaml
{{/*
  trakrf.application — shared Application shape.

  Usage:
    {{- include "trakrf.application" (dict
      "name" "cert-manager-config"
      "path" "helm/cert-manager-config"
      "namespace" .Values.namespaces.certManager
      "syncWave" "0"
      "cluster" .Values.cluster
      "repoURL" .Values.repoURL
      "targetRevision" .Values.targetRevision
      "destination" .Values.destination
      "inlineValues" ""
    ) }}

  - `path` is set for charts in THIS repo; omit for upstream Applications that
    use `chart` + external repoURL (those templates inline the full source block).
  - `inlineValues` is a YAML string passed via source.helm.values (used for
    upstream chart Applications where we can't emit a values-<cluster>.yaml
    in our repo to reference).
*/}}
{{- define "trakrf.application" -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ .syncWave | quote }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: trakrf
  source:
    repoURL: {{ .repoURL }}
    targetRevision: {{ .targetRevision }}
    path: {{ .path }}
    helm:
      valueFiles:
        - values.yaml
        - values-{{ .cluster }}.yaml
      {{- if .inlineValues }}
      values: |
{{ .inlineValues | indent 8 }}
      {{- end }}
  destination:
    server: {{ .destination.server }}
    namespace: {{ .namespace }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
{{- end -}}
```

- [ ] **Step 4: `templates/argocd.yaml` (ArgoCD self-hosting)**

```yaml
# ArgoCD itself — upstream argo-helm chart. Uses cluster-specific bootstrap values
# by passing them inline via helm.values (since the upstream chart lives in a
# different repo and we can't ship values-<cluster>.yaml alongside it).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: trakrf
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-cd
    targetRevision: "9.5.*"
    helm:
      values: |
        {{- if eq .Values.cluster "eks" }}
        controller:
          serviceAccount:
            annotations:
              eks.amazonaws.com/role-arn: "arn:aws:iam::252374924199:role/trakrf-demo-argocd"
        server:
          serviceAccount:
            annotations:
              eks.amazonaws.com/role-arn: "arn:aws:iam::252374924199:role/trakrf-demo-argocd"
        {{- end }}
        {{- /* AKS: no SA annotations needed in this phase. */ -}}
  destination:
    server: {{ .Values.destination.server }}
    namespace: {{ .Values.namespaces.argocd }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 5: `templates/cert-manager.yaml` (upstream jetstack)**

```yaml
# cert-manager — upstream jetstack chart. Workload identity SA annotations
# injected per-cluster via inline values.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: trakrf
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: "v1.16.*"
    helm:
      values: |
        crds:
          enabled: true
        replicaCount: 2
        podDisruptionBudget:
          enabled: true
        {{- if eq .Values.cluster "aks" }}
        serviceAccount:
          labels:
            azure.workload.identity/use: "true"
          annotations:
            azure.workload.identity/client-id: {{ .Values.certManagerIdentityClientId | quote }}
        podLabels:
          azure.workload.identity/use: "true"
        {{- end }}
  destination:
    server: {{ .Values.destination.server }}
    namespace: {{ .Values.namespaces.certManager }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 6: `templates/cert-manager-config.yaml` (our chart)**

```yaml
{{- $inlineValues := "" }}
{{- if eq .Values.cluster "aks" }}
{{- /* Inject tofu-sourced values into the Azure DNS solver config since values-aks.yaml carries placeholders */ -}}
{{- $inlineValues = printf "azureDNS:\n  resourceGroupName: %s\n  subscriptionID: %s\n  tenantID: %s\n  managedIdentity:\n    clientID: %s\n"
    .Values.dnsZoneResourceGroup
    .Values.subscriptionId
    .Values.tenantId
    .Values.certManagerIdentityClientId
}}
{{- end }}
{{- include "trakrf.application" (dict
  "name" "cert-manager-config"
  "path" "helm/cert-manager-config"
  "namespace" .Values.namespaces.certManager
  "syncWave" "0"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" $inlineValues
) }}
```

- [ ] **Step 7: `templates/traefik.yaml` (upstream)**

```yaml
# Traefik — upstream chart. AKS overrides loadBalancerIP + LB resource-group
# annotation via inline values (tofu-sourced).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: trakrf
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: "39.*"
    helm:
      values: |
        deployment:
          replicas: 2
        podDisruptionBudget:
          enabled: true
          minAvailable: 1
        {{- if eq .Values.cluster "aks" }}
        service:
          spec:
            loadBalancerIP: {{ .Values.traefikLbIp | quote }}
          annotations:
            service.beta.kubernetes.io/azure-load-balancer-resource-group: {{ .Values.mainResourceGroupName | quote }}
        {{- end }}
  destination:
    server: {{ .Values.destination.server }}
    namespace: {{ .Values.namespaces.traefik }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 8: `templates/traefik-config.yaml`**

```yaml
{{- include "trakrf.application" (dict
  "name" "traefik-config"
  "path" "helm/traefik-config"
  "namespace" .Values.namespaces.traefik
  "syncWave" "0"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" ""
) }}
```

- [ ] **Step 9: `templates/trakrf-db.yaml`**

```yaml
{{- include "trakrf.application" (dict
  "name" "trakrf-db"
  "path" "helm/trakrf-db"
  "namespace" .Values.namespaces.trakrf
  "syncWave" "0"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" ""
) }}
```

- [ ] **Step 10: `templates/trakrf-backend.yaml`**

```yaml
{{- include "trakrf.application" (dict
  "name" "trakrf-backend"
  "path" "helm/trakrf-backend"
  "namespace" .Values.namespaces.trakrf
  "syncWave" "1"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" ""
) }}
```

- [ ] **Step 11: `templates/trakrf-ingester.yaml`**

```yaml
{{- include "trakrf.application" (dict
  "name" "trakrf-ingester"
  "path" "helm/trakrf-ingester"
  "namespace" .Values.namespaces.trakrf
  "syncWave" "2"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" ""
) }}
```

- [ ] **Step 12: Lint + render (AKS)**

```bash
helm lint argocd/root -f argocd/root/values.yaml --set cluster=aks \
  --set certManagerIdentityClientId=fake-client-id \
  --set tenantId=fake-tenant \
  --set subscriptionId=fake-sub \
  --set dnsZoneResourceGroup=rg-fake \
  --set traefikLbIp=1.2.3.4 \
  --set mainResourceGroupName=rg-fake
```

Expected: clean.

```bash
helm template trakrf-root argocd/root \
  --set cluster=aks \
  --set certManagerIdentityClientId=fake-id \
  --set tenantId=fake-t \
  --set subscriptionId=fake-s \
  --set dnsZoneResourceGroup=rg-fake \
  --set traefikLbIp=1.2.3.4 \
  --set mainResourceGroupName=rg-fake \
  | grep -E '^kind:|^  name:|sync-wave' | head -30
```

Expected: 7 Application manifests with names `argocd`, `cert-manager`, `cert-manager-config`, `traefik`, `traefik-config`, `trakrf-db`, `trakrf-backend`, `trakrf-ingester`. Wait — that's 8. The existing set was 8 (including argocd self-hosting); my `root/templates/` also has 8 but the spec says "7." Let me recount: argocd, cert-manager, cert-manager-config, traefik, traefik-config, trakrf-db, trakrf-backend, trakrf-ingester = 8. The spec said "7" — I was miscounting in the spec. Update:

- [ ] **Step 13: Fix spec count**

Open `docs/superpowers/specs/2026-04-22-tra-438-aks-phase-3-design.md`. Find "7 Applications (CNPG operator + kube-prometheus-stack..." — change to "8 Applications (CNPG operator + kube-prometheus-stack..." — and make sure the bullet list there has argocd-self included. Commit with the plan at the end (batched).

- [ ] **Step 14: Render EKS overlay to confirm parity**

```bash
helm template trakrf-root argocd/root --set cluster=eks | grep -E '^kind:|^  name:' | head -30
```

Expected: same 8 Application names, no Azure-specific inline values injected.

- [ ] **Step 15: Commit**

```bash
git add argocd/root/
git commit -m "feat(tra-438): argocd/root/ app-of-apps chart

8 Applications as Helm templates with cluster-aware valueFiles and
inline values for upstream charts (cert-manager workload identity
annotations, Traefik Azure LB IP). Single touchpoint is
.Values.cluster — scripts/apply-root-app.sh sets it + injects tofu
outputs at install time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 16: Repoint `argocd/root.yaml` at the new chart + delete old Applications dir

Transition the raw `argocd/root.yaml` Application (which currently syncs the `argocd/applications/` directory) to point at `argocd/root/` Helm chart instead.

**Files:**
- Modify: `argocd/root.yaml`
- Delete: `argocd/applications/*.yaml`
- Delete: `argocd/clusters/trakrf/cluster.yaml`
- Delete: `argocd/clusters/trakrf/` (empty dir)

- [ ] **Step 1: Rewrite `argocd/root.yaml`**

This root Application now references the new Helm chart. The actual install happens via `scripts/apply-root-app.sh` (which does `helm upgrade --install trakrf-root argocd/root -n argocd`); this file becomes a self-description that ArgoCD itself can pick up on a re-sync if it's living in `argocd/root/` already. Simplest approach: skip `argocd/root.yaml` entirely and let the helm install create the Applications (which ArgoCD syncs). Or: point it at the root chart via git-multi-source.

Easiest correct path: **DELETE `argocd/root.yaml` entirely** — the root-app's existence is maintained by the helm install in `just argocd-bootstrap`, not by a git-committed Application. If ArgoCD goes down and comes back, `just argocd-bootstrap aks` re-creates the helm release.

```bash
git rm argocd/root.yaml
```

- [ ] **Step 2: Delete old `argocd/applications/`**

```bash
git rm argocd/applications/*.yaml
rmdir argocd/applications 2>/dev/null || true
```

- [ ] **Step 3: Delete `argocd/clusters/trakrf/`**

```bash
git rm argocd/clusters/trakrf/cluster.yaml
rmdir argocd/clusters/trakrf 2>/dev/null || true
```

- [ ] **Step 4: Evaluate `argocd/clusters/cluster.yaml`**

```bash
cat argocd/clusters/cluster.yaml 2>/dev/null || echo "not present"
```

If it's a cluster-registration Secret for in-cluster destination (usually a no-op since `kubernetes.default.svc` is implicit), delete it:

```bash
git rm argocd/clusters/cluster.yaml 2>/dev/null
rmdir argocd/clusters 2>/dev/null || true
```

If it holds something else (e.g., external cluster registration for a remote AKS), keep it.

- [ ] **Step 5: Commit the deletions**

```bash
git commit -m "refactor(tra-438): retire argocd/applications + clusters/trakrf

The app-of-apps moves to argocd/root/ as a Helm chart installed
via 'just argocd-bootstrap <cluster>'. Old raw Application manifests
and the CNPG Cluster CR are replaced by templates in argocd/root/
and helm/trakrf-db/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Part D — Bootstrap scripts and justfile recipes

### Task 17: Create `scripts/apply-root-app.sh`

Reads tofu outputs, runs `helm upgrade --install` on the root chart.

**Files:** `scripts/apply-root-app.sh` (create)

- [ ] **Step 1: Create `scripts/` directory if needed**

```bash
mkdir -p /home/mike/trakrf-infra/scripts
```

- [ ] **Step 2: Write `scripts/apply-root-app.sh`**

```bash
#!/usr/bin/env bash
# Template argocd/root/values.yaml with tofu outputs and install the root app-of-apps.
#
# Usage: scripts/apply-root-app.sh <cluster>
#   <cluster>  one of: aks, eks, homelab (must have matching values-<cluster>.yaml in helm/ charts)
#
# For AKS, reads tofu outputs from terraform/azure/. For EKS, reads from terraform/aws/.
# For other clusters (homelab), adapt the source block.

set -euo pipefail

CLUSTER="${1:-}"
if [[ -z "$CLUSTER" ]]; then
  echo "usage: $0 <cluster>" >&2
  exit 1
fi

case "$CLUSTER" in
  aks)
    TF_DIR="terraform/azure"
    CLIENT_ID=$(tofu -chdir="$TF_DIR" output -raw cert_manager_identity_client_id)
    TENANT_ID=$(tofu -chdir="$TF_DIR" output -raw tenant_id)
    SUB_ID=$(tofu -chdir="$TF_DIR" output -raw subscription_id)
    DNS_RG=$(tofu -chdir="$TF_DIR" output -raw dns_zone_resource_group)
    LB_IP=$(tofu -chdir="$TF_DIR" output -raw traefik_lb_ip)
    MAIN_RG=$(tofu -chdir="$TF_DIR" output -raw main_resource_group_name)
    ;;
  eks)
    # Pre-destroy snapshot — outputs don't exist after TRA-381 burn-down.
    CLIENT_ID=""
    TENANT_ID=""
    SUB_ID=""
    DNS_RG=""
    LB_IP=""
    MAIN_RG=""
    ;;
  *)
    echo "warning: no tofu output wiring for cluster '$CLUSTER'; using blanks" >&2
    CLIENT_ID=""
    TENANT_ID=""
    SUB_ID=""
    DNS_RG=""
    LB_IP=""
    MAIN_RG=""
    ;;
esac

echo "Installing argocd/root chart (cluster=$CLUSTER)..."
helm upgrade --install trakrf-root argocd/root \
  --namespace argocd \
  --create-namespace \
  -f argocd/root/values.yaml \
  --set cluster="$CLUSTER" \
  --set certManagerIdentityClientId="$CLIENT_ID" \
  --set tenantId="$TENANT_ID" \
  --set subscriptionId="$SUB_ID" \
  --set dnsZoneResourceGroup="$DNS_RG" \
  --set traefikLbIp="$LB_IP" \
  --set mainResourceGroupName="$MAIN_RG"

echo "Root app installed. Watch sync with:"
echo "  kubectl -n argocd get applications -w"
```

- [ ] **Step 3: Make executable**

```bash
chmod +x /home/mike/trakrf-infra/scripts/apply-root-app.sh
```

- [ ] **Step 4: Syntax check**

```bash
bash -n scripts/apply-root-app.sh
```

Expected: no output (syntax OK).

- [ ] **Step 5: Commit**

```bash
git add scripts/apply-root-app.sh
git commit -m "feat(tra-438): scripts/apply-root-app.sh — templating + install

Reads tofu outputs from terraform/azure (AKS) and installs
argocd/root as the trakrf-root helm release. Single path for
first install and re-sync after tofu output changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 18: Create `scripts/smoke-aks.sh`

Scripted precondition checks for the manual smoke test.

**Files:** `scripts/smoke-aks.sh` (create)

- [ ] **Step 1: Write `scripts/smoke-aks.sh`**

```bash
#!/usr/bin/env bash
# Scripted precondition checks for TRA-438 AKS smoke test.
# Exits 0 if all green, non-zero on first red check.

set -euo pipefail

HOST="${HOST:-aks.trakrf.app}"
EXPECTED_IP=$(tofu -chdir=terraform/azure output -raw traefik_lb_ip)

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

# 1. All ArgoCD Applications Synced + Healthy
echo "→ Checking ArgoCD Applications..."
UNHEALTHY=$(kubectl -n argocd get applications -o json | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name')
if [[ -n "$UNHEALTHY" ]]; then
  echo "  unhealthy apps:"
  echo "$UNHEALTHY" | sed 's/^/    /'
  fail "one or more Applications not Synced+Healthy"
fi
pass "All Applications Synced + Healthy"

# 2. Certificate Ready
echo "→ Checking cert-manager Certificate..."
READY=$(kubectl -n traefik get certificate trakrf-aks-wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$READY" != "True" ]]; then
  fail "Certificate trakrf-aks-wildcard is not Ready"
fi
pass "Certificate trakrf-aks-wildcard Ready"

# 3. Traefik Service external IP matches tofu output
echo "→ Checking Traefik LB IP..."
ACTUAL_IP=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [[ "$ACTUAL_IP" != "$EXPECTED_IP" ]]; then
  fail "Traefik LB IP mismatch: got '$ACTUAL_IP', want '$EXPECTED_IP'"
fi
pass "Traefik LB IP = $ACTUAL_IP"

# 4. DNS resolves
echo "→ Checking DNS resolution..."
DNS_APEX=$(dig +short "$HOST" | head -1)
DNS_WILD=$(dig +short "foo.$HOST" | head -1)
[[ "$DNS_APEX" == "$EXPECTED_IP" ]] || fail "DNS $HOST -> '$DNS_APEX', want '$EXPECTED_IP'"
[[ "$DNS_WILD" == "$EXPECTED_IP" ]] || fail "DNS foo.$HOST -> '$DNS_WILD', want '$EXPECTED_IP'"
pass "DNS apex + wildcard both resolve to $EXPECTED_IP"

# 5. HTTPS + Let's Encrypt
echo "→ Checking HTTPS + cert issuer..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://$HOST/" || echo "000")
[[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]] || fail "https://$HOST returned $HTTP_CODE"

ISSUER=$(curl -s -v "https://$HOST/" 2>&1 | grep -E 'issuer:' | head -1)
echo "$ISSUER" | grep -qiE "let's encrypt|letsencrypt|R3|R10|R11" || fail "Cert issuer is not Let's Encrypt: $ISSUER"
pass "HTTPS $HTTP_CODE with Let's Encrypt cert"

echo
echo "All preconditions green. Proceed with manual UI walkthrough:"
echo "  1. Browser to https://$HOST — log in"
echo "  2. Trigger a BLE scan"
echo "  3. Save an inventory item, reload, confirm persisted"
echo "  4. Browser to https://grafana.$HOST — capture baseline metrics"
```

- [ ] **Step 2: Make executable + syntax check**

```bash
chmod +x /home/mike/trakrf-infra/scripts/smoke-aks.sh
bash -n scripts/smoke-aks.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke-aks.sh
git commit -m "feat(tra-438): scripts/smoke-aks.sh — precondition checks

5-step scripted check (ArgoCD health, Certificate Ready, Traefik IP,
DNS, HTTPS+LE cert) gates the manual UI walkthrough for TRA-438.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 19: Update `justfile` — new and modified recipes

**Files:** `justfile` (modify)

- [ ] **Step 1: Add `aks-creds` recipe**

Append to the justfile (after the existing `azure` recipe):

```make
# Fetch AKS kubeconfig via az CLI, then convert to azurecli auth (needs kubelogin)
aks-creds:
    @RG=$(tofu -chdir=terraform/azure output -raw resource_group_name) && \
     CLUSTER=$(tofu -chdir=terraform/azure output -raw cluster_name) && \
     az aks get-credentials --resource-group $RG --name $CLUSTER --overwrite-existing && \
     kubelogin convert-kubeconfig -l azurecli && \
     kubectl config use-context $CLUSTER
```

- [ ] **Step 2: Modify `monitoring-bootstrap` to take a CLUSTER argument**

Replace the existing `monitoring-bootstrap` recipe with:

```make
# Install kube-prometheus-stack into monitoring namespace (direct helm, not ArgoCD)
monitoring-bootstrap CLUSTER:
    @echo "Adding prometheus-community Helm repo..."
    @helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    @helm repo update prometheus-community
    @echo "Installing kube-prometheus-stack ({{CLUSTER}}) into monitoring namespace..."
    @helm upgrade --install kube-prometheus-stack \
      prometheus-community/kube-prometheus-stack \
      --version 83.4.1 \
      --namespace monitoring --create-namespace \
      -f helm/monitoring/values.yaml \
      -f helm/monitoring/values-{{CLUSTER}}.yaml
    @echo "Waiting for Grafana to be ready..."
    @kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=300s
    @echo "Building dashboards ConfigMap from helm/monitoring/dashboards/..."
    @kubectl create configmap kube-prometheus-stack-dashboards \
      --namespace monitoring \
      --from-file=helm/monitoring/dashboards/ \
      --dry-run=client -o yaml \
      | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
      | kubectl apply --server-side --force-conflicts -f -
    @echo "Applying out-of-chart manifests (CNPG ServiceMonitor, dashboards)..."
    @kubectl apply --server-side --force-conflicts -n monitoring -f helm/monitoring/manifests/
```

- [ ] **Step 3: Add `cnpg-bootstrap` recipe**

```make
# Install CNPG operator into cnpg-system (direct helm, not ArgoCD — CRD chicken-and-egg)
cnpg-bootstrap CLUSTER:
    @echo "Adding cnpg Helm repo..."
    @helm repo add cnpg https://cloudnative-pg.github.io/charts
    @helm repo update cnpg
    @echo "Installing cloudnative-pg operator ({{CLUSTER}}) into cnpg-system..."
    @helm upgrade --install cnpg cnpg/cloudnative-pg \
      --version 0.28.* \
      --namespace cnpg-system --create-namespace \
      -f helm/cnpg/values.yaml \
      -f helm/cnpg/values-{{CLUSTER}}.yaml
    @echo "Waiting for operator to be ready..."
    @kubectl rollout status deployment/cnpg-cloudnative-pg -n cnpg-system --timeout=120s
```

- [ ] **Step 4: Add `db-secrets` recipe**

```make
# Create trakrf namespace and CNPG role secrets from .env.local (idempotent)
db-secrets:
    @kubectl create namespace trakrf --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${TRAKRF_APP_DB_PASSWORD:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD not set in .env.local"; exit 1; }
    @kubectl create secret generic trakrf-app-credentials -n trakrf \
      --from-literal=username=trakrf-app \
      --from-literal=password="${TRAKRF_APP_DB_PASSWORD}" \
      --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create secret generic trakrf-migrate-credentials -n trakrf \
      --from-literal=username=trakrf-migrate \
      --from-literal=password="${TRAKRF_MIGRATE_DB_PASSWORD}" \
      --dry-run=client -o yaml | kubectl apply -f -
    @echo "Secrets created (or unchanged)."
```

- [ ] **Step 5: Modify `argocd-bootstrap` to take CLUSTER**

Replace existing recipe:

```make
# Install ArgoCD via Helm and apply the root app-of-apps for a given cluster
argocd-bootstrap CLUSTER:
    @echo "Adding ArgoCD Helm repo..."
    @helm repo add argo https://argoproj.github.io/argo-helm
    @helm repo update argo
    @echo "Installing ArgoCD into argocd namespace ({{CLUSTER}})..."
    @helm upgrade --install argocd argo/argo-cd \
      --namespace argocd --create-namespace \
      -f argocd/bootstrap/values.yaml \
      -f argocd/bootstrap/values-{{CLUSTER}}.yaml
    @echo "Waiting for ArgoCD server to be ready..."
    @kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
    @echo "Applying AppProject..."
    @kubectl apply -f argocd/projects/trakrf.yaml
    @echo "Installing root app-of-apps..."
    @./scripts/apply-root-app.sh {{CLUSTER}}
    @echo "ArgoCD bootstrap complete. Run 'just argocd-password' for the admin password."
```

- [ ] **Step 6: Add `smoke-aks` recipe**

```make
# Run scripted smoke preconditions for AKS (see scripts/smoke-aks.sh)
smoke-aks:
    @./scripts/smoke-aks.sh
```

- [ ] **Step 7: Verify justfile parses**

```bash
just --list | head -25
```

Expected: new recipes visible — `aks-creds`, `cnpg-bootstrap`, `db-secrets`, `monitoring-bootstrap` (with arg), `argocd-bootstrap` (with arg), `smoke-aks`.

- [ ] **Step 8: Commit**

```bash
git add justfile
git commit -m "feat(tra-438): justfile recipes for AKS deploy flow

- aks-creds: az get-credentials + kubelogin convert
- cnpg-bootstrap CLUSTER: direct helm install of CNPG operator
- monitoring-bootstrap CLUSTER: modified to take cluster arg
- db-secrets: create trakrf ns + CNPG role secrets from .env.local
- argocd-bootstrap CLUSTER: modified to take arg + call apply-root-app.sh
- smoke-aks: run scripts/smoke-aks.sh

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Part E — Deploy and verify

### Task 20: Get AKS kubeconfig

**Files:** none (operational)

- [ ] **Step 1: Fetch credentials**

Run:
```bash
just aks-creds
```

Expected: creds written to `~/.kube/config`, context switched to the AKS cluster, `kubelogin convert-kubeconfig` runs silently.

- [ ] **Step 2: Verify cluster reachability**

```bash
kubectl get nodes -o wide
```

Expected: one node (the primary pool, `Standard_D4ps_v6`, zone 3), status `Ready`, arch `arm64`.

### Task 21: Bootstrap CNPG operator + monitoring

**Files:** none (operational)

- [ ] **Step 1: Install CNPG operator**

```bash
just cnpg-bootstrap aks
```

Expected: `cnpg-system` namespace created, operator pod Running within 60s.

```bash
kubectl -n cnpg-system get pods
```

- [ ] **Step 2: Install kube-prometheus-stack**

```bash
just monitoring-bootstrap aks
```

Expected: `monitoring` namespace created, Grafana + Prometheus + Alertmanager pods Running within 5 min. First install takes a while (~50 CRDs + pulls).

```bash
kubectl -n monitoring get pods
```

All should reach `Running`. If anything is `Pending`, check PVC status — `managed-csi` with `WaitForFirstConsumer` should bind once pods schedule.

### Task 22: Create trakrf namespace + DB secrets

**Files:** none (operational)

- [ ] **Step 1: Ensure `.env.local` has both DB passwords**

```bash
grep -E 'TRAKRF_(APP|MIGRATE)_DB_PASSWORD' ~/.env.local || grep -E 'TRAKRF_(APP|MIGRATE)_DB_PASSWORD' /home/mike/trakrf-infra/.env.local
```

If missing, add:
```bash
TRAKRF_APP_DB_PASSWORD=<generate with `openssl rand -base64 24`>
TRAKRF_MIGRATE_DB_PASSWORD=<generate with `openssl rand -base64 24`>
```

Reload direnv (`direnv reload` or `cd .`).

- [ ] **Step 2: Run the recipe**

```bash
just db-secrets
```

Expected: `namespace/trakrf created`, two `secret/trakrf-*-credentials created` lines.

- [ ] **Step 3: Verify**

```bash
kubectl -n trakrf get secrets
```

Expected: both `trakrf-app-credentials` and `trakrf-migrate-credentials` present.

### Task 23: Pin backend image tag and bootstrap ArgoCD

**Blocker:** TRA-451 must have merged and a multi-arch `ghcr.io/trakrf/backend:sha-XXXXXXX` tag published before this task proceeds. If not, pause.

**Files:** `helm/trakrf-backend/values-aks.yaml` (modify)

- [ ] **Step 1: Identify the new multi-arch tag**

Run:
```bash
docker buildx imagetools inspect ghcr.io/trakrf/backend:latest 2>&1 | grep -E 'Platform:\s+linux/arm64'
```

If absent, STOP — loop back to TRA-451. If present, get the commit sha tag (the workflow tags both `latest` and `sha-<short>`):

```bash
gh api repos/trakrf/platform/commits/main --jq '.sha[:7]'
```

That's the `sha-XXXXXXX` to pin.

- [ ] **Step 2: Update `helm/trakrf-backend/values-aks.yaml`**

Edit the file, replace:
```yaml
image:
  tag: "REPLACE_WITH_MULTI_ARCH_TAG"
```

With:
```yaml
image:
  tag: sha-<SHORT_SHA>
```

- [ ] **Step 3: Lint**

```bash
helm lint helm/trakrf-backend -f helm/trakrf-backend/values.yaml -f helm/trakrf-backend/values-aks.yaml
```

Expected: clean, no "image.tag must be set" fail.

- [ ] **Step 4: Commit the tag pin**

```bash
git add helm/trakrf-backend/values-aks.yaml
git commit -m "chore(tra-438): pin trakrf-backend AKS image to multi-arch tag

After TRA-451 shipped, GHCR now has linux/arm64 manifests for
ghcr.io/trakrf/backend. Pin values-aks.yaml to sha-<SHORT_SHA>.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Bootstrap ArgoCD + root-app**

```bash
just argocd-bootstrap aks
```

Expected: ArgoCD installs, AppProject applies, `apply-root-app.sh` runs with tofu outputs substituted, 8 Applications appear in ArgoCD.

- [ ] **Step 6: Watch sync**

```bash
kubectl -n argocd get applications -w
```

Expected progression:
1. argocd (wave -2) — completes quickly (self-hosting is a no-op if already installed)
2. cert-manager (wave -1) — Running, then Synced+Healthy (~2-3 min for CRDs + deployment)
3. traefik (wave -1) — Synced+Healthy; LoadBalancer Service takes 2-3 min to get external IP
4. cert-manager-config, traefik-config, trakrf-db (wave 0) — Synced+Healthy after wave -1 completes. Cert issuance triggers as soon as the Certificate CR lands (~2-5 min for DNS-01 solve + cert mint)
5. trakrf-backend (wave 1) — requires trakrf-db ready (check `kubectl -n trakrf get cluster` — `status.phase: Cluster in healthy state`); migrate Job runs first, then deployment
6. trakrf-ingester (wave 2) — final

If anything stays `OutOfSync` or `Degraded` > 5 min, check the event stream: `kubectl -n argocd describe application <name>`.

### Task 24: Verify Certificate mints and LB binds

**Files:** none (operational)

- [ ] **Step 1: Watch Certificate status**

```bash
kubectl -n traefik describe certificate trakrf-aks-wildcard
```

Expected: `Status.Conditions` contains `Ready=True` within ~5 min of cert-manager seeing the CR. Common failure: federated credential subject mismatch — if the cert stays Issuing for > 10 min, check `kubectl -n cert-manager logs deploy/cert-manager | tail -50` for Azure auth errors.

- [ ] **Step 2: Confirm Traefik LB has the static IP**

```bash
kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
tofu -chdir=terraform/azure output -raw traefik_lb_ip
```

Both must match. If they don't, the Service is picking a different IP — check for `azure-load-balancer-resource-group` annotation missing/wrong:

```bash
kubectl -n traefik get svc traefik -o jsonpath='{.metadata.annotations}' | jq
```

### Task 25: Run scripted smoke test

**Files:** none (operational)

- [ ] **Step 1: Run `just smoke-aks`**

```bash
just smoke-aks
```

Expected: 5 green check lines, exit 0. If any fail, fix before proceeding.

- [ ] **Step 2: Capture output for PR**

```bash
just smoke-aks > /tmp/smoke-aks-$(date +%Y%m%d-%H%M%S).log 2>&1
```

Save for attaching to the Linear comment.

### Task 26: Manual UI walkthrough

**Files:** none (operational, demo-vehicle deliverable)

- [ ] **Step 1: Login**

Browser to `https://aks.trakrf.app`. Verify the Let's Encrypt lock icon. Log in with test credentials. Screenshot the post-login dashboard.

- [ ] **Step 2: BLE scan**

Trigger a BLE scan from the UI. Screenshot the scan result.

- [ ] **Step 3: Inventory save**

Save an inventory item. Reload the page. Confirm it persists. Screenshot before + after.

- [ ] **Step 4: Grafana baseline**

Browser to `https://grafana.aks.trakrf.app`. Fetch admin password:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Log in. Navigate to "Kubernetes / Compute Resources / Node (pods)" dashboard. Select the primary node. Note baseline CPU, memory, network under the smoke-test workload. Screenshot.

- [ ] **Step 5: Compile results**

Create a short summary (in-terminal; will paste into Linear comment):

```
TRA-438 smoke test — <date>

scripted preconditions: pass (scripts/smoke-aks.sh exit 0)

manual walkthrough:
  login    OK — JWT issued, dashboard rendered
  BLE scan OK — scan triggered, X devices discovered
  save    OK — inventory item persisted across reload

grafana baseline (Standard_D4ps_v6 primary):
  cpu    X% of 4 cores
  memory Y GB of 16 GB
  net    Z kb/s in, Z kb/s out
```

### Task 27: Update Linear + open PR

**Files:** none (operational)

- [ ] **Step 1: Push branch**

```bash
git push -u origin feature/tra-438-aks-phase-3
```

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "feat(tra-438): AKS demo phase 3 — TrakRF end-to-end on AKS" \
  --body "$(cat <<'EOF'
## Summary
- Terraform: AKS OIDC issuer + workload identity; cert-manager UAI + federated credential + DNS Zone Contributor; Traefik static PIP + apex/wildcard A records
- Helm: values-overlay refactor (values.yaml + values-{cluster}.yaml) across 7 charts; new helm/trakrf-db and helm/cnpg
- ArgoCD: argocd/root/ app-of-apps Helm chart (8 Applications) replaces raw argocd/applications/
- Scripts: apply-root-app.sh + smoke-aks.sh; new/modified justfile recipes for per-cluster bootstrap
- TrakRF end-to-end verified on https://aks.trakrf.app with real LE cert

Depends on [TRA-451](https://linear.app/trakrf/issue/TRA-451) (shipped).

## Test plan
- [x] `tofu -chdir=terraform/azure validate` (run per task)
- [x] `helm lint` each chart with both `values-eks.yaml` and `values-aks.yaml`
- [x] `helm template argocd/root` renders 8 valid Application manifests
- [x] `just azure` apply succeeds with no recreates
- [x] `just cnpg-bootstrap aks` + `just monitoring-bootstrap aks` succeed
- [x] `just argocd-bootstrap aks` — all 8 Applications Synced+Healthy within 10 min
- [x] Certificate `trakrf-aks-wildcard` Ready; cert issuer is Let's Encrypt
- [x] Traefik Service external IP matches tofu `traefik_lb_ip`
- [x] DNS `aks.trakrf.app` + `foo.aks.trakrf.app` resolve to the PIP
- [x] `just smoke-aks` exit 0
- [x] Manual UI: login, BLE scan, inventory save (screenshots in Linear)
- [x] Grafana baseline captured for D4ps_v6 right-sizing decision

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Comment on Linear**

Add a Linear comment on TRA-438 with the smoke-test results summary, screenshots, Grafana baseline, and the PR URL. Update status to "In Review" (or whatever your workflow uses).

- [ ] **Step 4: Self-review the PR diff**

```bash
gh pr view --web
```

Scan the files-changed view for:
- Any `REPLACE_WITH_MULTI_ARCH_TAG` stragglers (Task 23 should have caught them)
- Unintended deletes outside `argocd/applications/` and `argocd/clusters/trakrf/`
- Secrets in commits (should be none)

---

## Self-Review Notes

### Spec coverage

Cross-ref spec sections → plan tasks:

| Spec section | Plan task(s) |
|---|---|
| Prerequisite (TRA-451) | Task 1 (gate), Task 23 (pin tag) |
| Decisions: cert-manager Azure DNS | Task 3 (TF), Task 7 (helm) |
| Decisions: values overlay | Tasks 7-14 |
| Decisions: app-of-apps root chart | Task 15 |
| Decisions: platform scope (EKS parity) | Tasks 9, 10, 11 + Task 21 (direct installs) |
| Decisions: skip ACR | no-op (helm values keep GHCR image repo) |
| Decisions: static PIP | Task 4, Task 5 (A records) |
| Decisions: CNPG Helm chart | Task 12 |
| Decisions: smoke test manual walkthrough | Task 26 |
| Decisions: direct helm for CNPG + monitoring | Task 13, Task 21 |
| TF: OIDC + workload identity | Task 2 |
| TF: cert_manager.tf | Task 3 |
| TF: traefik_lb.tf | Task 4 |
| TF: dns.tf A records | Task 5 |
| TF: outputs | Task 6 |
| Helm: each chart's values split | Tasks 7, 8, 9, 10, 11, 12, 13 |
| Helm: ClusterIssuer solver fork | Task 7 |
| Helm: trakrf-db new chart | Task 12 |
| ArgoCD: root chart | Task 15 |
| ArgoCD: cleanup | Task 16 |
| Scripts: apply-root-app.sh | Task 17 |
| Scripts: smoke-aks.sh | Task 18 |
| Justfile additions | Task 19 |
| Smoke test scripted | Task 25 |
| Smoke test manual | Task 26 |
| Grafana baseline | Task 26 |

All spec sections accounted for.

### Placeholder scan

Searched the plan for TBD / TODO / placeholder — only intentional ones remain:
- `REPLACE_WITH_MULTI_ARCH_TAG` in `values-aks.yaml` for trakrf-backend (Task 10) — **intentional forcing function**, replaced in Task 23 once TRA-451 ships
- `<SHORT_SHA>` in Task 23 commit message — filled in by the engineer with the actual tag
- `<generate with ...>` in Task 22 step 1 — engineer generates passwords themselves (not baked in)

### Type / name consistency

- Certificate `secretName: trakrf-wildcard-tls` (common in cert-manager-config) = Traefik `defaultCertificateSecret: trakrf-wildcard-tls` (both cluster overlays of traefik-config). Consistent.
- `helm/cert-manager-config/values-aks.yaml` uses `trakrf-aks-wildcard` as Certificate name; matches what `smoke-aks.sh` greps for (`trakrf-aks-wildcard`). Consistent.
- Application count: 8 in Task 15 render check. Spec correction flagged in Task 15 Step 13 to match.

### Scope check

Single-implementation scope. All 27 tasks are sequential or near-sequential — some chart splits (Tasks 7-14) can parallelize across subagents since they're independent files, but everything in Part E is linear.
