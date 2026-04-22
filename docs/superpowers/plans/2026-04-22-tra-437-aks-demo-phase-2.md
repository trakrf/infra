# TRA-437 AKS Demo Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a working AKS cluster with ACR attached, Azure DNS for `aks.trakrf.app`, and Cloudflare NS delegation. First apply of the Azure module.

**Architecture:** Single on-demand `Standard_D4ps_v6` ARM primary node runs everything (DB + app + platform). No separate database pool. Spot burst pool deferred to TRA-438. Azure CNI Overlay networking. AAD-RBAC with an Entra `trakrf-aks-admins` group created in-module. ACR at `trakrf.azurecr.io`, attached to AKS via `AcrPull` on the kubelet identity. Cloudflare delegates `aks.trakrf.app` to Azure DNS via cross-module remote-state read (mirrors the existing `aws-delegation.tf` pattern).

**Tech Stack:** OpenTofu, `hashicorp/azurerm ~> 4.0`, `hashicorp/azuread ~> 3.0`, `hashicorp/cloudflare ~> 4.x` (already used), Cloudflare R2 via S3 backend, just, direnv.

**Spec:** `docs/superpowers/specs/2026-04-22-tra-437-aks-demo-phase-2-design.md`

**Branch:** `feature/tra-437-aks-phase-2` (already created; spec committed at `b9264a0`)

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `terraform/azure/provider.tf` | modify | Add `azuread ~> 3.0` provider |
| `terraform/azure/variables.tf` | modify | Add `kubernetes_version`, `primary_pool_zone`, `acr_name` |
| `terraform/azure/main.tf` | modify | Update `Ticket` tag TRA-436 → TRA-437 |
| `terraform/azure/identity.tf` | create | `azuread_group.aks_admins` + self-membership |
| `terraform/azure/dns.tf` | create | `azurerm_dns_zone.aks_trakrf_app` |
| `terraform/azure/acr.tf` | create | `azurerm_container_registry.main` + `AcrPull` role assignment on kubelet identity |
| `terraform/azure/aks.tf` | create | `azurerm_kubernetes_cluster.main` (single on-demand ARM primary pool) |
| `terraform/azure/outputs.tf` | modify | Append cluster/kubeconfig/acr/dns outputs |
| `terraform/cloudflare/azure-delegation.tf` | create | Remote-state read of `azure.tfstate`, NS records on `trakrf.app` zone |

## Testing Approach

Terraform HCL has no unit tests. The "test" per change is:

1. `tofu validate` — parses HCL, checks schema against provider, resolves references. Runs after every code change.
2. `tofu plan` — computes the full diff; catches type errors and provider validation that `validate` misses. Runs before apply.
3. `tofu apply` — the real test. Resources come up, smoke tests confirm behavior.
4. Smoke tests — `kubectl cluster-info`, `az acr login`, `dig NS aks.trakrf.app +trace`.

Each code task ends with `tofu validate` passing. Apply + smoke live in their own tasks.

CI (`.github/workflows/ci.yml`) runs `tofu-validate` with `-backend=false` for each module in the matrix — catches schema regressions on every PR push without needing Azure credentials.

---

### Task 1: Pre-flight — verify ARM SKU availability

Not a code change — a go/no-go gate. If `Standard_D4ps_v6` isn't available in `southcentralus`, the apply will fail later and we need to know *now* so we can escalate. Per the spec's "let it fail loudly" decision, there's no fallback SKU baked into the code.

**Files:** none

- [ ] **Step 1: Verify ARM on-demand D4ps_v5 availability in southcentralus**

Run:
```bash
az vm list-skus -l southcentralus --resource-type virtualMachines \
  --query "[?name=='Standard_D4ps_v6'].{name:name, locations:locations, restrictions:restrictions}" \
  -o jsonc
```

Expected: one entry. Confirm zone 3 is NOT in any `restrictions[].restrictionInfo.zones` list. Note: in this subscription (confirmed 2026-04-22), zones 1 and 2 are blocked with `NotAvailableForSubscription` — zone 3 is the only ARM zone. If zone 3 also becomes blocked, escalate.

- [ ] **Step 2: Verify AKS version 1.35 availability**

Run:
```bash
az aks get-versions --location southcentralus -o table | head -5
```

Expected: `1.35.x` appears in the first few rows with `KubernetesOfficial` support plan. If not, fall back to the latest GA version shown and update the `kubernetes_version` default accordingly (note in PR description).

- [ ] **Step 3: Verify current az CLI principal can create Entra groups**

Run:
```bash
az ad signed-in-user show --query "{id:id, upn:userPrincipalName}" -o json
```

Expected: returns your user ID. The apply will later try to create an Entra group; if you don't have `Group.ReadWrite.All`, Terraform will fail with a `403 Forbidden`. For a tenant owner this is usually fine — raise with user if unsure.

---

### Task 2: Add `azuread` provider and new variables

Provider change + new variables land together — the provider block needs no variables, but the new variables are consumed by `aks.tf` and `acr.tf` in later tasks. Keep them in one commit so the module is self-consistent.

**Files:**
- Modify: `terraform/azure/provider.tf`
- Modify: `terraform/azure/variables.tf`

- [ ] **Step 1: Add `azuread` provider to `provider.tf`**

Edit `terraform/azure/provider.tf`. In the `required_providers` block, add the `azuread` entry after `random`:

```hcl
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
```

Then add a new provider block below the existing `provider "azurerm"` block:

```hcl
provider "azuread" {
  # tenant inferred from current az CLI session
}
```

- [ ] **Step 2: Add new variables to `variables.tf`**

Append to `terraform/azure/variables.tf`:

```hcl
variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the AKS cluster"
  default     = "1.35"
}

variable "primary_pool_zone" {
  type        = string
  description = "Availability zone for the primary node pool (single-AZ pin for CNPG PV stability). Zone 3 required: this subscription blocks D-ps_v5 ARM SKUs in zones 1 and 2."
  default     = "3"
}

variable "acr_name" {
  type        = string
  description = "ACR name (globally unique, alphanumeric 5-50 chars)"
  default     = "trakrf"
}
```

- [ ] **Step 3: Re-init terraform to pull the new provider**

Run:
```bash
just _backend-conf terraform/azure
tofu -chdir=terraform/azure init -backend-config=backend.conf -upgrade
```

Expected: `hashicorp/azuread v3.x.x` is installed; `Terraform has been successfully initialized!`.

- [ ] **Step 4: Validate**

Run:
```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add terraform/azure/provider.tf terraform/azure/variables.tf terraform/azure/.terraform.lock.hcl
git commit -m "$(cat <<'EOF'
feat(tra-437): add azuread provider and AKS/ACR variables

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Update `Ticket` tag to TRA-437

Small, isolated change to keep the tag accurate on all resources this phase touches.

**Files:**
- Modify: `terraform/azure/main.tf`

- [ ] **Step 1: Edit the `common_tags` local**

Edit `terraform/azure/main.tf:9`. Change:

```hcl
    Ticket      = "TRA-436"
```

to:

```hcl
    Ticket      = "TRA-437"
```

- [ ] **Step 2: Validate**

```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/azure/main.tf
git commit -m "$(cat <<'EOF'
chore(tra-437): bump Ticket tag to TRA-437

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Create Entra admin group (`identity.tf`)

Declarative group provisioning so teammate onboarding is just `azuread_group_member` membership later. Owner and first member = current az CLI principal.

**Files:**
- Create: `terraform/azure/identity.tf`

- [ ] **Step 1: Write `identity.tf`**

Create `terraform/azure/identity.tf` with:

```hcl
# Current az CLI principal — used as group owner + first member
data "azuread_client_config" "current" {}

# Entra group that grants AKS cluster-admin via AAD-RBAC
resource "azuread_group" "aks_admins" {
  display_name     = "trakrf-aks-admins"
  description      = "Cluster admins for AKS (trakrf) — TRA-437"
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]
}

# Self-membership so the operator who ran 'just azure' has immediate admin access
resource "azuread_group_member" "aks_admin_self" {
  group_object_id  = azuread_group.aks_admins.object_id
  member_object_id = data.azuread_client_config.current.object_id
}
```

- [ ] **Step 2: Validate**

```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/azure/identity.tf
git commit -m "$(cat <<'EOF'
feat(tra-437): provision trakrf-aks-admins Entra group

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Create Azure DNS zone (`dns.tf`)

Public DNS zone that Cloudflare will delegate to in the Cloudflare module. Zone lives in the main resource group.

**Files:**
- Create: `terraform/azure/dns.tf`

- [ ] **Step 1: Write `dns.tf`**

Create `terraform/azure/dns.tf`:

```hcl
# Public DNS zone for AKS demo workloads
# Cloudflare delegates aks.trakrf.app here via terraform/cloudflare/azure-delegation.tf
resource "azurerm_dns_zone" "aks_trakrf_app" {
  name                = "aks.trakrf.app"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}
```

- [ ] **Step 2: Validate**

```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/azure/dns.tf
git commit -m "$(cat <<'EOF'
feat(tra-437): add Azure DNS zone for aks.trakrf.app

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Create ACR (`acr.tf`)

ACR only — no role assignment yet, because the role assignment needs the AKS cluster's kubelet identity to exist. Role assignment lands in Task 8 after AKS is in place.

**Files:**
- Create: `terraform/azure/acr.tf`

- [ ] **Step 1: Write `acr.tf`**

Create `terraform/azure/acr.tf`:

```hcl
# Container registry — trakrf.azurecr.io
# Admin disabled; auth is via AKS kubelet managed identity (role assignment in aks.tf)
resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false

  tags = local.common_tags
}
```

- [ ] **Step 2: Validate**

```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/azure/acr.tf
git commit -m "$(cat <<'EOF'
feat(tra-437): add ACR 'trakrf' (Basic SKU, admin disabled)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Create AKS cluster (`aks.tf`)

Single on-demand ARM primary pool (`Standard_D4ps_v6`, zone 1, `node_count = 1`). Azure CNI Overlay. AAD-RBAC enabled pointing at `azuread_group.aks_admins`. `local_account_disabled = false` so `az aks get-credentials --admin` still works as an escape hatch.

**Files:**
- Create: `terraform/azure/aks.tf`

- [ ] **Step 1: Write `aks.tf`**

Create `terraform/azure/aks.tf`:

```hcl
# AKS cluster — single on-demand primary node runs everything (DB + app + platform)
# Spot burst pool deferred to TRA-438. See project_aks_demo_topology memory.
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aks-${local.name_prefix}"
  kubernetes_version  = var.kubernetes_version

  # Primary (system) pool — on-demand ARM, single-AZ for CNPG PV stability
  default_node_pool {
    name            = "primary"
    vm_size         = "Standard_D4ps_v6"
    vnet_subnet_id  = azurerm_subnet.aks_nodes.id
    node_count      = 1
    zones           = [var.primary_pool_zone]
    os_disk_size_gb = 50

    tags = local.common_tags
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure CNI Overlay — pods get IPs from pod_cidr, not subnet IPs
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.245.0.0/16"
    dns_service_ip      = "10.245.0.10"
    load_balancer_sku   = "standard"
  }

  # AAD-RBAC — Entra group holds cluster-admin; local accounts kept as escape hatch
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = [azuread_group.aks_admins.object_id]
  }

  local_account_disabled = false

  tags = local.common_tags
}

# AcrPull on the kubelet identity — lets AKS nodes pull private images from ACR.
# skip_service_principal_aad_check avoids first-apply PrincipalNotFound from Entra
# replication lag (the kubelet identity was created seconds ago in the same apply).
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.main.id
  skip_service_principal_aad_check = true
}
```

- [ ] **Step 2: Validate**

```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/azure/aks.tf
git commit -m "$(cat <<'EOF'
feat(tra-437): add AKS cluster (single on-demand ARM primary)

k8s 1.35, Azure CNI Overlay, AAD-RBAC via trakrf-aks-admins group.
Standard_D4ps_v6 on-demand primary pinned to zone 1 for CNPG PV
stability. AcrPull granted to kubelet identity on ACR scope.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Append AKS/ACR/DNS outputs

Downstream consumers: `terraform/cloudflare/azure-delegation.tf` reads `dns_nameservers`; the user reads `kubectl_config_command` to wire kubeconfig; CI/scripts read `cluster_name` and `acr_login_server`.

**Files:**
- Modify: `terraform/azure/outputs.tf`

- [ ] **Step 1: Append outputs**

Append to `terraform/azure/outputs.tf`:

```hcl
# AKS
output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "kubectl_config_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}

# ACR
output "acr_login_server" {
  description = "ACR login server for docker push/pull"
  value       = azurerm_container_registry.main.login_server
}

# DNS
output "dns_zone_name" {
  description = "Azure DNS zone name"
  value       = azurerm_dns_zone.aks_trakrf_app.name
}

output "dns_nameservers" {
  description = "Azure DNS nameservers — consumed by Cloudflare for NS delegation"
  value       = azurerm_dns_zone.aks_trakrf_app.name_servers
}
```

- [ ] **Step 2: Validate**

```bash
tofu -chdir=terraform/azure validate
```

Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/azure/outputs.tf
git commit -m "$(cat <<'EOF'
feat(tra-437): add AKS/ACR/DNS outputs for downstream consumers

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Plan review

All Azure code is in place. Before apply, review the plan output carefully — this is the "last chance before hitting the Azure API" checkpoint.

**Files:** none

- [ ] **Step 1: Generate plan**

```bash
just _backend-conf terraform/azure
tofu -chdir=terraform/azure init -backend-config=backend.conf
tofu -chdir=terraform/azure plan -out=tfplan
```

Expected: Plan summary shows roughly `Plan: 6 to add, 3 to change, 0 to destroy`.

**Adds (6):** `azuread_group.aks_admins`, `azuread_group_member.aks_admin_self`, `azurerm_container_registry.main`, `azurerm_dns_zone.aks_trakrf_app`, `azurerm_kubernetes_cluster.main`, `azurerm_role_assignment.aks_acr_pull`.

**Changes (3):** `azurerm_resource_group.main`, `azurerm_virtual_network.main`, `azurerm_network_security_group.aks_nodes` — all three already have `tags = local.common_tags` set from TRA-436, and Task 3's Ticket-tag bump (`TRA-436` → `TRA-437`) is an in-place update on each. Subnet has no tags, no change there.

The key is: **no destroys, no surprises outside the spec**. If you see unexpected changes, stop and investigate before applying.

- [ ] **Step 2: Spot-check plan output**

Confirm by eye:
- `azurerm_kubernetes_cluster.main` — `default_node_pool.vm_size = "Standard_D4ps_v6"`, `zones = ["1"]`, `node_count = 1`, `kubernetes_version = "1.35"`.
- `azurerm_container_registry.main` — `name = "trakrf"`, `sku = "Basic"`, `admin_enabled = false`.
- `azurerm_dns_zone.aks_trakrf_app` — `name = "aks.trakrf.app"`.
- `azuread_group.aks_admins` — `display_name = "trakrf-aks-admins"`.
- `azurerm_role_assignment.aks_acr_pull` — `role_definition_name = "AcrPull"`, `skip_service_principal_aad_check = true`.

If any value is off, **STOP** and fix the HCL. Do not apply until the plan matches the spec.

- [ ] **Step 3: No commit (plan is ephemeral)**

The `tfplan` file is gitignored. No commit needed.

---

### Task 10: Apply Azure module

First apply. AKS cluster creation typically takes 5-10 minutes. Role assignment waits on the kubelet identity being created.

**Files:** none

- [ ] **Step 1: Apply**

```bash
just azure
```

Or equivalently:
```bash
tofu -chdir=terraform/azure apply tfplan
```

Expected:
- Resources create in dependency order. Cluster creation dominates wall-clock time.
- Final line: `Apply complete! Resources: ~8 added, ~1 changed, 0 destroyed.`
- Outputs print at the end — confirm `dns_nameservers` lists four Azure NS records.

If the apply fails:
- **`SkuNotAvailable` on AKS**: ARM on-demand D4ps_v5 unavailable. Escalate — do not silently swap SKUs.
- **`PrincipalNotFound` on role assignment**: Entra replication lag despite `skip_service_principal_aad_check`. Re-run `just azure` once; it's idempotent.
- **`Forbidden` on `azuread_group`**: current principal lacks `Group.ReadWrite.All`. Raise with user.

- [ ] **Step 2: No commit (state is remote)**

State is in R2; no git action.

---

### Task 11: Smoke test — kubectl

Verify `az aks get-credentials` works, control plane is reachable, the single node is ready.

**Files:** none

- [ ] **Step 1: Fetch kubeconfig**

```bash
$(tofu -chdir=terraform/azure output -raw kubectl_config_command)
```

(This expands to `az aks get-credentials --resource-group rg-trakrf-demo-ussc --name aks-trakrf-demo-ussc`.)

Expected: `Merged "aks-trakrf-demo-ussc" as current context in ~/.kube/config`. A browser window or device-code prompt may appear for Entra auth — sign in with the same account you used for `az login`.

- [ ] **Step 2: Verify cluster-info**

```bash
kubectl cluster-info
```

Expected: prints control plane and coredns URLs. No errors.

- [ ] **Step 3: Verify nodes**

```bash
kubectl get nodes -o wide
```

Expected:
- Exactly 1 node, status `Ready`.
- `VERSION` column shows `v1.35.x`.
- `INTERNAL-IP` is in the `10.143.0.0/24` subnet (the AKS nodes subnet).
- Labels include `topology.kubernetes.io/zone=southcentralus-1`.

If the node count or SKU is wrong, compare against state with `tofu state show azurerm_kubernetes_cluster.main` before debugging.

---

### Task 12: Smoke test — ACR

Verify `az acr login` succeeds. The kubelet-side `AcrPull` path is exercised later when an actual image is pushed (TRA-438); here we confirm the registry is reachable and named correctly.

**Files:** none

- [ ] **Step 1: Log in to ACR**

```bash
az acr login --name trakrf
```

Expected: `Login Succeeded`.

- [ ] **Step 2: Confirm login server**

```bash
tofu -chdir=terraform/azure output -raw acr_login_server
```

Expected: `trakrf.azurecr.io`

---

### Task 13: Create Cloudflare delegation (`azure-delegation.tf`)

Mirrors `aws-delegation.tf`. Reads Azure module outputs via R2-backed remote state; creates NS records on the `trakrf.app` zone delegating `aks.trakrf.app` to Azure DNS.

**Files:**
- Create: `terraform/cloudflare/azure-delegation.tf`

- [ ] **Step 1: Write `azure-delegation.tf`**

Create `terraform/cloudflare/azure-delegation.tf`:

```hcl
# Read Azure DNS zone outputs from azure/ module via remote state
data "terraform_remote_state" "azure" {
  backend = "s3"

  config = {
    endpoints = {
      s3 = "https://${var.account_id}.r2.cloudflarestorage.com"
    }
    bucket = "tf-state"
    key    = "azure.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true

    profile = "cloudflare-r2"
  }
}

# Create NS records in Cloudflare to delegate aks.trakrf.app to Azure DNS.
# Note: delegation lives on the trakrf.app zone (not trakrf.id like aws-delegation.tf).
resource "cloudflare_record" "aks_subdomain_ns" {
  count = length(data.terraform_remote_state.azure.outputs.dns_nameservers)

  zone_id = cloudflare_zone.trakrf_app.id
  name    = "aks"
  type    = "NS"
  content = data.terraform_remote_state.azure.outputs.dns_nameservers[count.index]
  ttl     = 3600

  comment = "Delegate aks.trakrf.app to Azure DNS"
}
```

- [ ] **Step 2: Validate**

```bash
just _backend-conf terraform/cloudflare
tofu -chdir=terraform/cloudflare init -backend-config=backend.conf
tofu -chdir=terraform/cloudflare validate
```

Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/cloudflare/azure-delegation.tf
git commit -m "$(cat <<'EOF'
feat(tra-437): delegate aks.trakrf.app to Azure DNS

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Apply Cloudflare delegation

**Files:** none

- [ ] **Step 1: Plan**

```bash
tofu -chdir=terraform/cloudflare plan -out=tfplan
```

Expected: `Plan: 4 to add, 0 to change, 0 to destroy.` (Four `cloudflare_record.aks_subdomain_ns` resources — one per Azure nameserver.)

Spot-check: each record has `name = "aks"`, `type = "NS"`, `zone_id` pointing at the `trakrf.app` zone, and a different `content` value (one of the four Azure nameservers).

- [ ] **Step 2: Apply**

```bash
just cloudflare
```

Or:
```bash
tofu -chdir=terraform/cloudflare apply tfplan
```

Expected: `Apply complete! Resources: 4 added, 0 changed, 0 destroyed.`

- [ ] **Step 3: No commit (state is remote)**

---

### Task 15: Smoke test — DNS resolution

Verify Cloudflare's NS records propagated and Azure DNS is authoritative for `aks.trakrf.app`. Propagation is usually fast (sub-minute) but can take up to a few minutes.

**Files:** none

- [ ] **Step 1: Check NS records from a public resolver**

```bash
nslookup -type=NS aks.trakrf.app 1.1.1.1
```

Expected: four `*.azure-dns.{com,net,org,info}` nameservers. If you see the old `trakrf.app` nameservers instead of Azure's, wait 60 seconds and retry — propagation lag.

- [ ] **Step 2: Full delegation chain**

```bash
dig NS aks.trakrf.app +trace
```

Expected: the trace walks `.` → `app` → `trakrf.app` → Cloudflare nameservers → Azure nameservers. The final authority for `aks.trakrf.app` should be the Azure DNS nameservers.

- [ ] **Step 3: If propagation is slow**

Wait up to 5 minutes, then retry step 1. If still not resolving:

- Check the Cloudflare dashboard → `trakrf.app` zone → confirm the four NS records exist with `name=aks` and the Azure nameserver values.
- Check `terraform/cloudflare/tfplan` was actually applied (look for "Apply complete" in recent terminal history).

---

### Task 16: Update Linear issue description

The spec deviates from the Linear issue's dual-pool topology. Update TRA-437 so the issue reflects what was actually built.

**Files:** none

- [ ] **Step 1: Update Linear issue body**

Via the `linear-server` MCP tool or the Linear UI, update TRA-437 description to replace the dual-pool section with:

> **Topology** (revised 2026-04-22 during brainstorming; see `docs/superpowers/specs/2026-04-22-tra-437-aks-demo-phase-2-design.md`):
> - Single on-demand `Standard_D4ps_v6` (ARM) primary pool, zone 1, `node_count = 1`. Runs everything.
> - No separate `database` node pool.
> - Spot burst pool deferred to TRA-438.

Keep the ACR, Azure DNS, Cloudflare delegation, watch-for, and DoD sections as-is (they're still accurate).

---

### Task 17: Open PR

All tasks done, Azure + Cloudflare applied, smoke tests passing. Open the PR against `main`.

**Files:** none

- [ ] **Step 1: Push branch**

```bash
git push -u origin feature/tra-437-aks-phase-2
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "feat(tra-437): AKS demo phase 2 — cluster + ACR + Azure DNS + CF delegation" --body "$(cat <<'EOF'
## Summary
- Stands up AKS cluster `aks-trakrf-demo-ussc` with single on-demand `Standard_D4ps_v6` ARM primary node (zone 1, k8s 1.35, Azure CNI Overlay, AAD-RBAC via `trakrf-aks-admins` Entra group).
- Provisions ACR `trakrf.azurecr.io` (Basic SKU, admin disabled) with `AcrPull` on the AKS kubelet identity.
- Creates Azure DNS zone for `aks.trakrf.app` and delegates via Cloudflare NS records on `trakrf.app`.

**Topology deviation from Linear**: this phase collapses the dual-pool EKS mirror described in TRA-437 to a single on-demand primary. Spot burst pool deferred to TRA-438. Rationale in spec + `project_aks_demo_topology` memory.

## Test plan
- [x] `tofu -chdir=terraform/azure plan` shows no drift after apply
- [x] `tofu -chdir=terraform/cloudflare plan` shows no drift after apply
- [x] `kubectl cluster-info` returns control plane + coredns endpoints
- [x] `kubectl get nodes` shows 1 node in zone 1 with `Standard_D4ps_v6` SKU
- [x] `az acr login --name trakrf` succeeds
- [x] `nslookup -type=NS aks.trakrf.app 1.1.1.1` returns four Azure NS records
- [x] `dig NS aks.trakrf.app +trace` resolves to Azure DNS

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Report the PR URL back to the user.

---

## Self-review notes

**Spec coverage:**
- Topology deviation section → Tasks 4 (identity), 6 (ACR), 7 (AKS) + Task 16 (Linear update) ✓
- All files in "Architecture → Resources added" mapped to tasks ✓
- All variables from "Files updated" mapped to Task 2 ✓
- Pre-flight SKU check → Task 1 ✓
- DoD items → Tasks 11, 12, 15 ✓

**Known plan limitations:**
- Task 9's plan-count estimate is approximate — `azurerm_kubernetes_cluster` sometimes reports its inline default node pool as a nested block (no separate resource) and sometimes the role assignment waits on a data source refresh. Review by eye, not by count.
- `skip_service_principal_aad_check = true` is defensive. If the first apply fails on the role assignment with `PrincipalNotFound`, re-running `just azure` resolves it deterministically (the kubelet identity is now old enough to have propagated).
