# TRA-437 — AKS demo phase 2: cluster + ACR + Azure DNS + Cloudflare delegation

**Date**: 2026-04-22
**Linear**: [TRA-437](https://linear.app/trakrf/issue/TRA-437) (child of epic [TRA-435](https://linear.app/trakrf/issue/TRA-435))
**Status**: Design approved, pending user review of this document
**Branch**: `feature/tra-437-aks-phase-2`

## Context

TRA-436 landed the Azure state key, provider, variables, resource group, VNet, AKS-node subnet, and baseline NSG — all no-apply scaffolding. TRA-437 is the first apply: a working AKS cluster with ACR attached, Azure DNS for `aks.trakrf.app`, and Cloudflare NS delegation.

The cluster is a single-node demo, not a mirror of the (now destroyed — see `project_eks_burndown_2026-04-21.md`) EKS dual-pool topology. See the topology note below. Anything that falls out of the "port EKS patterns first" mandate from the epic (see `feedback_aks_port_preference.md`) gets called out inline.

This spec covers TRA-437 only. The portable K8s layer (ArgoCD, Helm overrides, Traefik, cert-manager solver, TrakRF smoke) is TRA-438 and gets its own spec → plan cycle.

## Port preference reminder

Default to EKS patterns (`terraform/aws/`, `terraform/cloudflare/aws-delegation.tf`). Reach for `hashsphere-azure-foundation` only for Azure specifics EKS doesn't cover — AKS resource schema, Azure CNI Overlay, ACR, Azure DNS, `azurerm` provider nuances. No shell-script init, no Azure Blob state, no hashsphere naming conventions.

## Topology deviation from Linear issue

The Linear issue description for TRA-437 mirrors the EKS dual-pool shape (Spot default pool + dedicated `database` on-demand pool). **This spec deviates** from that: single on-demand primary node runs *everything* (DB + app + platform), no dedicated database pool. The Spot burst pool is deferred to TRA-438. Rationale and sizing: see `project_aks_demo_topology.md`.

Update the Linear issue to match once this spec is approved (or leave the divergence called out in the PR description).

## Design decisions (brainstormed 2026-04-22)

| Decision | Choice | Rationale |
|---|---|---|
| Node topology | Single on-demand primary pool, no separate DB pool, Spot burst deferred | EKS dual-pool left one node under-utilized on a single-env demo. One right-sized on-demand node is cheaper and predictably stable for DB workloads. |
| Primary pool SKU | `Standard_D4ps_v5` (ARM, 4 vCPU / 16 GB) | Matches EKS `t3.xlarge` vCPU/RAM. ARM chosen despite multi-arch image risk (see below) for cost + parity with the burst pool we'll add in TRA-438. |
| Primary pool zone | Zone `3` | Single-AZ pin required for CNPG PV stability (DB lives on this node). Zone 1 originally chosen, but this subscription has `NotAvailableForSubscription` restrictions on D-ps_v5 (ARM) SKUs in zones 1 and 2 — zone 3 is the only zone where ARM works. Verified 2026-04-22 via `az vm list-skus`. |
| ACR name | `trakrf` (bare) | Globally unique check passed; no "demo" baked in so name survives a future prod migration. |
| Kubernetes version | `1.35` (latest GA) | Greenfield build; full smoke test downstream regardless of version; no reason to lag. |
| Admin auth model | AAD enabled + local accounts enabled | Entra-backed `kubectl` by default, `az aks get-credentials --admin` as escape hatch; flip `local_account_disabled = true` later without state-destroying changes. |
| Admin group provisioning | Create `trakrf-aks-admins` Entra group in Terraform | Existing tenant has only `TOS` (dead POC); declarative membership makes teammate onboarding trivial. |
| Primary SKU ARM/x86 fallback | None — hardcoded `Standard_D4ps_v5` | Multi-arch image work is out of scope for this phase; let `tofu apply` fail loudly if ARM on-demand unavailable in southcentralus rather than silently downgrading to amd64. |

## Operational plan (post-apply, phase-3 scope)

- Grafana memory-pressure alert on the primary node (follow-up in TRA-438 when monitoring lands).
- Review sizing with real TrakRF usage data once app is running.
- **Scale down primary SKU** (to `Standard_D2ps_v5` or similar) if sustained usage stays <5 GB RAM and <2 CPU.

## Architecture

### Resources added

**`terraform/azure/aks.tf`**
- `azurerm_kubernetes_cluster "main"` — Azure CNI Overlay, AAD-RBAC enabled, `SystemAssigned` identity.
  - Default pool: `Standard_D4ps_v5` (ARM), `priority = "Regular"` (on-demand), `node_count = 1`, `zones = [var.primary_pool_zone]` (default `"1"`), 50 GB OS disk, attached to `azurerm_subnet.aks_nodes`.
  - `network_profile`: `network_plugin = "azure"`, `network_plugin_mode = "overlay"`, `pod_cidr = "10.244.0.0/16"`, `service_cidr = "10.245.0.0/16"`, `dns_service_ip = "10.245.0.10"`, `load_balancer_sku = "standard"`.
  - AAD block: `azure_rbac_enabled = true`, `admin_group_object_ids = [azuread_group.aks_admins.object_id]`. `local_account_disabled = false`.
- **No** `azurerm_kubernetes_cluster_node_pool` resource in this phase. Burst pool lands in TRA-438.

**`terraform/azure/acr.tf`**
- `azurerm_container_registry "main"` — name `var.acr_name` (default `trakrf`), Basic SKU, `admin_enabled = false`.
- `azurerm_role_assignment "aks_acr_pull"` — `AcrPull` on the ACR scope, principal = `azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id`, `skip_service_principal_aad_check = true` to avoid first-apply `PrincipalNotFound` from Entra replication lag.

**`terraform/azure/dns.tf`**
- `azurerm_dns_zone "aks_trakrf_app"` — name `aks.trakrf.app`, in the main resource group.

**`terraform/azure/identity.tf`**
- `data "azuread_client_config" "current"` — for the current user's object ID.
- `azuread_group "aks_admins"` — display name `trakrf-aks-admins`, `security_enabled = true`, owner = current user.
- `azuread_group_member "aks_admin_self"` — binds current user as a member.

**`terraform/cloudflare/azure-delegation.tf`** (mirrors `aws-delegation.tf`)
- `data "terraform_remote_state" "azure"` — backend `s3`, bucket `tf-state`, key `azure.tfstate`, same R2 endpoint and flags as the existing AWS remote-state block.
- `cloudflare_record "aks_subdomain_ns"` — `count = length(data.terraform_remote_state.azure.outputs.dns_nameservers)`, `zone_id = cloudflare_zone.trakrf_app.id`, `name = "aks"`, `type = "NS"`, `content = data.terraform_remote_state.azure.outputs.dns_nameservers[count.index]`, `ttl = 3600`.
  - **Note**: delegation lives on `cloudflare_zone.trakrf_app` (defined in `trakrf-app.tf:5`), not `cloudflare_zone.domain`. The `aws-delegation.tf` delegates `aws.trakrf.id`; this one delegates `aks.trakrf.app`.

### Files updated (not replaced)

**`terraform/azure/provider.tf`**
- Add `azuread = { source = "hashicorp/azuread", version = "~> 3.0" }` to `required_providers`.
- Add `provider "azuread" {}` (tenant inferred from current az CLI session).

**`terraform/azure/variables.tf`**
- Add `variable "kubernetes_version"` (default `"1.35"`).
- Add `variable "primary_pool_zone"` (default `"3"`).
- Add `variable "acr_name"` (default `"trakrf"`).

**`terraform/azure/outputs.tf`** (append)
- `cluster_name`, `kubectl_config_command` (`az aks get-credentials --resource-group ... --name ...`), `acr_login_server`, `dns_zone_name`, `dns_nameservers`.

**`terraform/azure/main.tf`**
- Update `Ticket` tag from `TRA-436` to `TRA-437`.

### No-change files

- `justfile` — `just azure` and `just cloudflare` are already wired (TRA-436 added the Azure recipe).
- `terraform/azure/network.tf` — no changes needed. Overlay means pods don't consume subnet IPs, so the `/24` from TRA-436 is massively oversized for a 1-node default pool; leave it as-is for future burst-pool headroom.
- `terraform/azure/backend.conf` — generated by justfile; no source-of-truth change.

## Apply order & flow

```
1. `just azure`
   → azure-new resources created in order:
     - azuread_group.aks_admins (+ member)
     - azurerm_container_registry.main
     - azurerm_dns_zone.aks_trakrf_app
     - azurerm_kubernetes_cluster.main (single default pool, creates kubelet_identity)
     - azurerm_role_assignment.aks_acr_pull (depends on cluster + ACR)
   → Writes azure.tfstate (including dns_nameservers output) to R2.

2. `just cloudflare`
   → cloudflare/ re-inits, reads fresh azure.tfstate via terraform_remote_state
   → Creates 4× cloudflare_record.aks_subdomain_ns on the trakrf.app zone
   → NS records propagate; aks.trakrf.app resolves to Azure DNS.
```

No Helm, no kubectl in this phase — TRA-438 is where the cluster gets populated (and where the Spot burst pool gets added if/when burst capacity is needed).

## Definition of done

From the Linear issue, plus smoke tests:

- [ ] `tofu -chdir=terraform/azure plan` shows no drift after apply.
- [ ] `tofu -chdir=terraform/cloudflare plan` shows no drift after apply.
- [ ] `az aks get-credentials --resource-group rg-trakrf-demo-ussc --name aks-trakrf-demo-ussc` succeeds.
- [ ] `kubectl cluster-info` returns control-plane + coredns endpoints.
- [ ] `kubectl get nodes` shows 1 node in zone 1 with `Standard_D4ps_v5` SKU.
- [ ] `nslookup aks.trakrf.app @1.1.1.1` returns four Azure NS records.
- [ ] `dig NS aks.trakrf.app +trace` shows delegation chain terminating at Azure DNS.
- [ ] `az acr login --name trakrf` succeeds.

## Risks & watch-list

- **ARM on-demand availability in southcentralus**: pre-flight with `az vm list-skus -l southcentralus --resource-type virtualMachines --query "[?name=='Standard_D4ps_v5']" -o table`. If unavailable, the apply fails; decision is to *not* bake in a fallback SKU for this phase.
- **Entra group creation permissions**: the Terraform apply needs the current az CLI principal to have `Group.ReadWrite.All` (usually present for tenant owners). If it fails, fall back to pre-creating the group manually and passing the object ID as a variable.
- **Cross-module apply ordering**: `just cloudflare` must run *after* `just azure` so that the remote-state read sees `dns_nameservers`. If `cloudflare` is applied stale, the NS record count will be 0; re-applying after `just azure` picks up the outputs. Safe either direction — just rerunnable.
- **Single point of failure**: with one primary node running everything, node replacement (SKU resize, k8s upgrade, hardware failure) downs the entire stack until the replacement is ready. Acceptable for demo; revisit if promoted to preview/prod.
- **Storage class (phase-3 concern)**: AKS defaults to `managed-csi` (Azure Disk). EKS was overridden to `gp3` in `eks.tf:98`. Phase 3 will handle Helm value overrides for CNPG and any other storage-class-aware workloads. No action here.
- **Load balancer (phase-3 concern)**: Traefik `Service type=LoadBalancer` will auto-provision an Azure Standard LB. Verify propagation in phase 3.
- **Stale tfplan files**: both `terraform/azure/tfplan` and `terraform/aws/tfplan` exist on disk from prior runs; `just azure` / `just cloudflare` regenerate them. No cleanup needed.

## Out of scope (for TRA-437)

- Spot burst pool (TRA-438 when/if a workload needs it).
- ArgoCD, Helm chart deploys, cert-manager, Traefik, TrakRF smoke test (TRA-438).
- GitHub Actions OIDC federated credentials (TRA-439).
- Multi-arch container image builds (separate epic or phase 3).
- Storage-class override to a gp3-equivalent (phase 3).
- Disabling local accounts (`local_account_disabled = true`) — flip when the cluster is known-healthy and Entra auth is verified.
- Promoting to a preview environment or production cutover (TRA-440 discussion).
- Grafana memory-pressure alert on primary node (TRA-438 once monitoring is up).
