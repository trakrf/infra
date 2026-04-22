# TRA-436 — AKS demo phase 1: state backend + `terraform/azure/` scaffolding

**Date**: 2026-04-22
**Linear**: [TRA-436](https://linear.app/trakrf/issue/TRA-436) (child of epic [TRA-435](https://linear.app/trakrf/issue/TRA-435))
**Status**: Design approved, pending user review of this document
**Branch**: `feature/tra-436-aks-scaffolding`

## Context

New Azure consulting opportunity in the pipeline. TRA-435 is the epic to stand up an AKS parallel to the (now-destroyed) EKS stack — dual-purpose as a portfolio artifact for the consulting pitch and as a possible cutover vehicle for the TrakRF `preview` environment (see [TRA-440](https://linear.app/trakrf/issue/TRA-440)). TRA-435 is sliced into four sub-issues:

- **TRA-436 (this spec)** — Azure state key on existing R2 bucket + `terraform/azure/` scaffolding (provider/vars/RG/VNet/subnet). No apply.
- **TRA-437** — AKS cluster + ACR + Azure DNS zone + Cloudflare NS delegation. First apply.
- **TRA-438** — Portable K8s layer (ArgoCD, Helm value overrides, cert-manager solver, Traefik) + TrakRF smoke test.
- **TRA-439 (optional)** — GitHub Actions OIDC federated credential on hashsphere app registration, scoped to `trakrf/infra`.

This spec covers TRA-436 only. TRA-437–439 get their own spec → plan → implementation cycles, framed by the epic-level architecture below so phase-1 decisions don't box later phases in.

## Port preference (applies across the epic)

**Default to `trakrf/infra` EKS patterns; use `hashsphere-azure-foundation` only for Azure specifics EKS doesn't cover.**

Hashsphere is a standalone ACA demo with its own bootstrap sensibilities (Azure Blob state, shell-script init, different naming). Cargo-culting those patterns into `trakrf/infra` introduces asymmetry that harms both the "parallel to EKS" portfolio narrative and the repo's maintainability. The initial TRA-435 description leaned too heavily on hashsphere — this spec rescopes that.

**Reach for hashsphere only for:**
- `azurerm` provider block + `features {}` block
- AKS resource schema and Azure CNI Overlay config
- `azurerm_container_registry`, `azurerm_dns_zone`
- Azure OIDC GitHub Actions workflow (phase 4 only)

**Do NOT reuse hashsphere's:**
- `init.sh` Azure Blob Storage bootstrap script — we use R2 state, not Azure Blob
- `backend "azurerm"` block — we use `backend "s3"` pointed at Cloudflare R2
- Azure-CAF-flavored naming conventions — we mirror `terraform/aws/`

## Epic-level target architecture

End state after TRA-436 → TRA-438:

```
┌─────────────────────────────────────────────────────────┐
│ Cloudflare zone trakrf.app (existing)                  │
│   └─ NS aks.trakrf.app → Azure DNS (new, TRA-437)      │
└─────────────────────────────────────────────────────────┘
                          │ delegation
                          ▼
┌─────────────────────────────────────────────────────────┐
│ Azure RG: rg-trakrf-demo-ussc                           │
│   ├─ VNet 10.143.0.0/16                                 │
│   │    └─ snet-aks-nodes  10.143.0.0/24                │
│   ├─ AKS (Azure CNI Overlay; pod CIDR 10.244.0.0/16)   │
│   │    ├─ pool "system"  on-demand, single-AZ, D4ps_v5 │
│   │    │                 (16 GB; right-size later)     │
│   │    └─ pool "burst"   Spot, multi-AZ, D2ps_v5, 0..2 │
│   ├─ ACR trakrfdemo<suffix>                             │
│   └─ Azure DNS zone aks.trakrf.app                      │
└─────────────────────────────────────────────────────────┘

Cloudflare R2 bucket tf-state  (existing)
   ├─ aws.tfstate        (from TRA-351)
   ├─ cloudflare.tfstate (from TRA-351)
   └─ azure.tfstate      (new, TRA-436)
```

Portable K8s layer (ArgoCD, CNPG, Traefik, cert-manager, kube-prometheus-stack, trakrf-backend, trakrf-ingester) reused from the existing repo — phase 3 only tweaks storage class (`gp3` → `managed-csi`), image repo (ECR → ACR), and cert-manager solver.

## TRA-436 scope boundary

**In:**
- State backend: new blob key `azure.tfstate` in the existing Cloudflare R2 `tf-state` bucket. No bootstrap work (the bucket already exists, provisioned by `terraform/bootstrap/`).
- `terraform/azure/` root module files: `provider.tf`, `main.tf`, `variables.tf`, `network.tf`, `outputs.tf`. `backend.conf` generated at apply time, gitignored.
- `justfile` recipe `azure` mirroring `aws`.
- CI: add `azure` to the `tofu-validate` matrix in `.github/workflows/ci.yml`.

**Out (→ later phases):** AKS cluster, ACR, Azure DNS zone, Cloudflare NS delegation, any `tofu apply`, ArgoCD/Helm work, OIDC CI.

## State backend

No new backend. Add a third key to the existing `tf-state` R2 bucket.

| Setting | Value | Notes |
|---|---|---|
| Bucket | `tf-state` (existing) | Created by `terraform/bootstrap/` |
| Blob key | `azure.tfstate` | Peer of `aws.tfstate`, `cloudflare.tfstate` |
| Endpoint | `https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com` | Injected via `backend.conf` |
| Region | `auto` (R2 is global) | |
| Auth profile | `cloudflare-r2` (local) | Same as aws/cloudflare modules |

`terraform/azure/provider.tf` backend block (identical pattern to `terraform/aws/provider.tf`):

```hcl
backend "s3" {
  bucket  = "tf-state"
  key     = "azure.tfstate"
  region  = "auto"
  profile = "cloudflare-r2"

  skip_credentials_validation = true
  skip_region_validation      = true
  skip_metadata_api_check     = true
  use_path_style              = true
}
```

`terraform/azure/backend.conf` — gitignored, generated by the justfile's existing `_backend-conf` recipe (which templates the endpoints line from `CLOUDFLARE_ACCOUNT_ID`).

Downstream cross-provider reads (TRA-437 preview): `terraform/cloudflare/azure-delegation.tf` will use `data "terraform_remote_state" "azure" { backend = "s3" ... key = "azure.tfstate" }`, mirroring the existing `aws-delegation.tf`.

## Root module file layout

Mirrors `terraform/aws/` 1:1. Phase 1 lands only these files:

```
terraform/azure/
├── backend.conf       # gitignored, generated by just _backend-conf
├── main.tf            # RG, random suffix, locals (common_tags, region)
├── network.tf         # VNet, subnet, NSG, NSG-subnet association
├── outputs.tf         # RG name, VNet ID, subnet ID, location
├── provider.tf        # azurerm ~> 4.0, backend "s3" (R2)
└── variables.tf       # subscription_id, region, environment, project, cluster_name, vnet_cidr
```

Phase 2 adds `aks.tf`, `acr.tf`, `dns.tf`, and `iam.tf` (managed-identity role assignments) to match `terraform/aws/` file shape (`eks.tf`, `ecr.tf`, `iam.tf`).

### `variables.tf` (defaults mirrored from `terraform/aws/variables.tf`)

| Variable | Type | Default | Notes |
|---|---|---|---|
| `subscription_id` | string | (required) | Injected via `TF_VAR_subscription_id` from `.env.local` |
| `region` | string | `"southcentralus"` | Matches hashsphere for Azure regional consistency |
| `environment` | string | `"demo"` | Matches `aws/` |
| `project` | string | `"trakrf"` | Matches `aws/` |
| `location` | string | `"ussc"` | Short code for resource naming |
| `cluster_name` | string | `"trakrf-demo"` | Matches EKS cluster_name |
| `vnet_cidr` | string | `"10.143.0.0/16"` | Non-zero second octet; slot after EKS `10.142.x` |

### `main.tf`

```hcl
locals {
  region      = var.region
  name_prefix = "${var.project}-${var.environment}-${var.location}"  # trakrf-demo-ussc

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Ticket      = "TRA-436"
  }
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = local.region
  tags     = local.common_tags
}
```

### `provider.tf`

```hcl
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random",  version = "~> 3.6" }
  }

  backend "s3" {
    bucket  = "tf-state"
    key     = "azure.tfstate"
    region  = "auto"
    profile = "cloudflare-r2"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}
```

### `network.tf`

VNet `10.143.0.0/16` with a single AKS node subnet and baseline NSG. Azure CNI Overlay keeps pod IPs on a non-routable overlay CIDR (configured on the AKS resource in phase 2), so the node subnet stays small.

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes-${local.name_prefix}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 0)]  # 10.143.0.0/24
}

resource "azurerm_network_security_group" "aks_nodes" {
  name                = "nsg-aks-nodes-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}
```

### `outputs.tf`

```hcl
output "resource_group_name" {
  description = "Azure resource group name for AKS demo infra"
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region"
  value       = azurerm_resource_group.main.location
}

output "vnet_id" {
  description = "VNet ID for downstream AKS attachment"
  value       = azurerm_virtual_network.main.id
}

output "aks_nodes_subnet_id" {
  description = "Node subnet ID for the AKS default/system pool"
  value       = azurerm_subnet.aks_nodes.id
}
```

## Networking and node sizing (context for phase 2, informs phase 1 VNet)

Phase 1 only provisions the network. Node pools land in phase 2. Design context to make sure the VNet sizing decided here is right:

- **Mode**: Azure CNI Overlay. Nodes consume VNet IPs; pods live on non-routable overlay `10.244.0.0/16` (configured in `aks.tf` in phase 2). Keeps the node subnet small.
- **System pool** (phase 2): `Standard_D4ps_v5` (ARM, 4 vCPU / 16 GB, ~$112/mo on-demand), single-AZ for PV affinity (TRA-364 pattern), 1 node steady. CNPG pins here.
- **Burst pool** (phase 2): `Standard_D2ps_v5` (ARM, 2 vCPU / 8 GB, ~$17/mo Spot), scale-from-zero (min=0, max=2), multi-AZ. HPA overflow.
- **Sizing strategy** (per design conversation): ship on 16 GB (safe for Prom memory during initial bring-up), collect usage via kube-prometheus-stack for 1–2 weeks, right-size down to `D2ps_v5` (8 GB) if observed peak stays under ~5 GB. Add a `PrometheusRule` alert for `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.15` in phase 3 to catch pressure before OOM.

VNet sizing (`/16`) has plenty of headroom for future subnets (Private Endpoints to ACR, Bastion, etc.). Node subnet (`/24`) is 256 IPs, >20× headroom for a 1–5 node demo.

**AKS platform constraint**: system node pools must be `priority=Regular` (on-demand). User pools can be Spot. This naturally enforces the "on-demand base + Spot burst" pattern and removes the need for a separate `database` pool on the EKS side — single-AZ + on-demand on one `system` pool achieves the same PV-zone-affinity guarantee.

## Justfile and CI integration

### Justfile

Append after the existing `aws` recipe (same pattern):

```make
# Plan and apply Azure infrastructure (AKS, ACR, Azure DNS)
azure: (_backend-conf "terraform/azure")
    @echo "Planning Azure infrastructure..."
    @tofu -chdir=terraform/azure init -backend-config=backend.conf
    @tofu -chdir=terraform/azure plan -out=tfplan
    @tofu -chdir=terraform/azure apply tfplan
```

No new `export TF_VAR_*` lines needed — `TF_VAR_subscription_id` is already set in `.env.local` under its natural name and picked up by Terraform directly via direnv.

### CI workflow

Single-line matrix addition to `.github/workflows/ci.yml`:

```yaml
strategy:
  fail-fast: false
  matrix:
    dir: [aws, azure, cloudflare, bootstrap]   # was: [aws, cloudflare, bootstrap]
```

`tofu validate` runs with `-backend=false`, so no Azure credentials required in CI. Provider schema is downloaded during `init`, validates HCL syntax and schema, exits clean. `tofu fmt -check -recursive terraform/` already covers the new module.

### Local developer auth flow

One-time:
```
az login --tenant $ARM_TENANT_ID
az account set --subscription $ARM_SUBSCRIPTION_ID
```

Then `just azure` picks up the CLI credential via the `azurerm` provider's `DefaultAzureCredential` chain.

## Definition of done

TRA-436 is complete when:

1. `terraform/azure/{provider,main,variables,network,outputs}.tf` exist on `feature/tra-436-aks-scaffolding`.
2. `just azure` runs `tofu init` + `tofu plan` without error. Plan output shows exactly:
   - `random_string.suffix` (1 to add)
   - `azurerm_resource_group.main` (1 to add)
   - `azurerm_virtual_network.main` (1 to add)
   - `azurerm_subnet.aks_nodes` (1 to add)
   - `azurerm_network_security_group.aks_nodes` (1 to add)
   - `azurerm_subnet_network_security_group_association.aks_nodes` (1 to add)
   - Summary: **6 to add, 0 to change, 0 to destroy**
3. `.github/workflows/ci.yml` `tofu-validate` matrix includes `azure` and passes in PR CI.
4. `tofu fmt -check -recursive terraform/` exits 0.
5. No secrets committed; `backend.conf` gitignored (already covered by existing `.gitignore`).

No `tofu apply` in phase 1.

## Deferred questions (tracked, resolved in later phases)

| # | Question | Resolve in | Current lean |
|---|---|---|---|
| 1 | cert-manager DNS-01 solver: Cloudflare token reuse vs Azure DNS with managed identity | TRA-438 | Cloudflare token reuse (simpler, matches EKS pattern; Azure DNS solver is bonus polish) |
| 2 | ARM multi-arch check for `trakrf-backend`, `trakrf-ingester`, `clevyr/cloudnativepg-timescale` | TRA-438 | Verify with `docker manifest inspect`; hybrid-cluster fallback if CNPG image is AMD64-only |
| 3 | Right-size system pool 16 GB → 8 GB after observed usage | TRA-438 follow-up | `PrometheusRule` alert on node memory availability; downsize after 1–2 weeks of metrics |
| 4 | GH Actions plan-on-PR / apply-on-merge vs local-only | TRA-439 | Defer until the consulting engagement actually needs CI automation |
| 5 | Preview environment cutover candidacy | [TRA-440](https://linear.app/trakrf/issue/TRA-440) (separate ticket) | Blocked by TRA-438 stability evaluation |
| 6 | Azure DNS zone monthly fee (~$0.50/zone) vs reusing Cloudflare DNS | TRA-437 | Azure DNS — narrative matters more than $0.50/mo; mirrors Route53 in EKS demo |

## References

- [TRA-435](https://linear.app/trakrf/issue/TRA-435) — AKS demo epic
- [TRA-436](https://linear.app/trakrf/issue/TRA-436) — this phase
- [TRA-437](https://linear.app/trakrf/issue/TRA-437) — phase 2 (cluster + ACR + DNS)
- [TRA-438](https://linear.app/trakrf/issue/TRA-438) — phase 3 (portable K8s layer + smoke test)
- [TRA-439](https://linear.app/trakrf/issue/TRA-439) — phase 4 (GH Actions OIDC, optional)
- [TRA-440](https://linear.app/trakrf/issue/TRA-440) — preview-env cutover cost modeling
- [TRA-351](https://linear.app/trakrf/issue/TRA-351) — EKS epic (source pattern)
- [TRA-364](https://linear.app/trakrf/issue/TRA-364) — PV zone-affinity under node replacement (origin of single-AZ DB pool pattern)
- [TRA-368](https://linear.app/trakrf/issue/TRA-368) — DNS/ingress/TLS (cert-manager + Traefik pattern)
- [hashsphere-azure-foundation](https://github.com/mikestankavich/hashsphere-azure-foundation) — reference for Azure specifics only
