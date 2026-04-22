# TRA-436 AKS Demo Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `terraform/azure/` scaffolding (provider, RG, VNet, subnet, NSG) with R2-backed state and get `tofu plan` clean. No `tofu apply`.

**Architecture:** Mirror `terraform/aws/` file-by-file. New state key `azure.tfstate` in the existing `tf-state` Cloudflare R2 bucket (no new state backend). Azure CNI Overlay networking — VNet `10.143.0.0/16`, node subnet `/24`, pod overlay `10.244.0.0/16` applied to the AKS resource in phase 2.

**Tech Stack:** OpenTofu, `hashicorp/azurerm ~> 4.0`, `hashicorp/random ~> 3.6`, Cloudflare R2 via S3 backend, just, direnv.

**Spec:** `docs/superpowers/specs/2026-04-22-tra-436-aks-demo-phase-1-design.md`

**Branch:** `feature/tra-436-aks-scaffolding` (already created; spec committed at `c9445c2`)

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `terraform/azure/provider.tf` | create | `azurerm ~> 4.0` + `random` providers, `backend "s3"` pointed at R2, `features {}` block |
| `terraform/azure/variables.tf` | create | All input variables with defaults (`subscription_id`, `region`, `environment`, `project`, `location`, `cluster_name`, `vnet_cidr`) |
| `terraform/azure/main.tf` | create | Resource group, random suffix, `common_tags` locals, `name_prefix` local |
| `terraform/azure/network.tf` | create | VNet, AKS node subnet, baseline NSG, NSG-subnet association |
| `terraform/azure/outputs.tf` | create | RG name, location, VNet ID, subnet ID |
| `terraform/azure/backend.conf` | generated, gitignored | Injects R2 endpoint; created by the existing `_backend-conf` just recipe — no code edit needed |
| `justfile` | modify | Add `azure` recipe at the same level as `aws` and `cloudflare` |
| `.github/workflows/ci.yml` | modify | Add `azure` to the `tofu-validate` matrix list |

## Testing Approach

Terraform HCL has no unit tests in the pytest/junit sense. The "test" per change is:

1. `tofu validate` — parses HCL, checks schema against provider, resolves references.
2. `tofu plan` — computes the full diff; catches type errors and provider validation that `validate` misses.

Each task ends with `tofu validate` passing. The final task runs `just azure` end-to-end and confirms the plan output matches the spec's definition-of-done (6 resources, all to-add).

CI adds a free third layer: `tofu-validate` runs on every PR with `-backend=false` (no creds), which catches schema regressions without talking to Azure or R2.

---

### Task 1: Provider configuration

Tightly couples to `variables.tf` (the provider references `var.subscription_id`). Land both in one commit.

**Files:**
- Create: `terraform/azure/provider.tf`
- Create: `terraform/azure/variables.tf`

- [ ] **Step 1: Create `terraform/azure/variables.tf`**

Write the file with all variable declarations. Defaults match the spec (`region=southcentralus`, `vnet_cidr=10.143.0.0/16`, `cluster_name=trakrf-demo`, `location=ussc`).

```hcl
variable "subscription_id" {
  type        = string
  description = "Azure subscription ID — injected via TF_VAR_subscription_id in .env.local"
}

variable "region" {
  type        = string
  description = "Azure region for all resources"
  default     = "southcentralus"
}

variable "environment" {
  type        = string
  description = "Environment name for tagging"
  default     = "demo"
}

variable "project" {
  type        = string
  description = "Project name for tagging"
  default     = "trakrf"
}

variable "location" {
  type        = string
  description = "Location short code for resource naming"
  default     = "ussc"
}

variable "cluster_name" {
  type        = string
  description = "Name of the AKS cluster (applied in phase 2)"
  default     = "trakrf-demo"
}

variable "vnet_cidr" {
  type        = string
  description = "CIDR block for the VNet"
  default     = "10.143.0.0/16"
}
```

- [ ] **Step 2: Create `terraform/azure/provider.tf`**

Backend block mirrors `terraform/aws/provider.tf` exactly (only the `key` differs: `azure.tfstate`). Provider block mirrors hashsphere's `features {}` block.

```hcl
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
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

- [ ] **Step 3: Initialize OpenTofu (backend-disabled) and validate**

Run:
```bash
cd terraform/azure
tofu init -backend=false -input=false
tofu validate
```

Expected output from `tofu init`: downloads `hashicorp/azurerm` and `hashicorp/random`, emits `OpenTofu has been successfully initialized!`

Expected output from `tofu validate`: `Success! The configuration is valid.`

- [ ] **Step 4: Format check**

Run:
```bash
cd /home/mike/trakrf-infra
tofu fmt -check -recursive terraform/
```

Expected: exits 0 with no output (all files already formatted).

If the check fails, run `tofu fmt -recursive terraform/` to fix, then re-run the check.

- [ ] **Step 5: Commit**

```bash
cd /home/mike/trakrf-infra
git add terraform/azure/provider.tf terraform/azure/variables.tf
git commit -m "$(cat <<'EOF'
feat(tra-436): add azurerm provider + variables scaffolding

R2 state backend (azure.tfstate), azurerm ~> 4.0, variables mirror
terraform/aws/variables.tf naming with Azure-specific additions
(subscription_id, location, vnet_cidr=10.143.0.0/16).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Resource group + locals

**Files:**
- Create: `terraform/azure/main.tf`

- [ ] **Step 1: Create `terraform/azure/main.tf`**

Locals follow hashsphere's shape for `name_prefix` and `common_tags`. Tag set mirrors `terraform/aws/main.tf`'s `common_tags` keys (`Project`, `Environment`, `ManagedBy`, `Ticket`). Random suffix reserved for phase 2 globally-unique ACR naming.

```hcl
locals {
  region      = var.region
  name_prefix = "${var.project}-${var.environment}-${var.location}"

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

  tags = local.common_tags
}
```

- [ ] **Step 2: Validate**

Run:
```bash
cd /home/mike/trakrf-infra/terraform/azure
tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format check**

```bash
cd /home/mike/trakrf-infra
tofu fmt -check -recursive terraform/
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
cd /home/mike/trakrf-infra
git add terraform/azure/main.tf
git commit -m "$(cat <<'EOF'
feat(tra-436): add resource group + locals (name_prefix, common_tags)

RG name rg-trakrf-demo-ussc, tags mirror terraform/aws/ pattern.
Random suffix reserved for phase-2 ACR naming (globally unique).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Network (VNet + subnet + NSG)

**Files:**
- Create: `terraform/azure/network.tf`

- [ ] **Step 1: Create `terraform/azure/network.tf`**

VNet uses `var.vnet_cidr` (`10.143.0.0/16`). Node subnet derived via `cidrsubnet(var.vnet_cidr, 8, 0)` which yields `10.143.0.0/24`. No subnet delegation (AKS attaches without one in CNI Overlay mode). Baseline NSG with no custom rules — AKS layers its own NSG rules via the cluster's managed NSG, this one is defense-in-depth.

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]

  tags = local.common_tags
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes-${local.name_prefix}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 0)]
}

resource "azurerm_network_security_group" "aks_nodes" {
  name                = "nsg-aks-nodes-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}
```

- [ ] **Step 2: Validate**

```bash
cd /home/mike/trakrf-infra/terraform/azure
tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format check**

```bash
cd /home/mike/trakrf-infra
tofu fmt -check -recursive terraform/
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
cd /home/mike/trakrf-infra
git add terraform/azure/network.tf
git commit -m "$(cat <<'EOF'
feat(tra-436): add VNet + AKS node subnet + baseline NSG

VNet 10.143.0.0/16 sized for growth; node subnet 10.143.0.0/24 via
cidrsubnet(). Pod CIDR 10.244.0.0/16 applied in phase 2 on the AKS
resource (Azure CNI Overlay).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Outputs

**Files:**
- Create: `terraform/azure/outputs.tf`

- [ ] **Step 1: Create `terraform/azure/outputs.tf`**

Outputs needed downstream by phase-2 AKS resource (subnet ID), phase-2 cloudflare delegation module (to read via `terraform_remote_state`), and human operators (RG + location for `az` CLI commands).

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
  description = "Node subnet ID for the AKS system pool"
  value       = azurerm_subnet.aks_nodes.id
}
```

- [ ] **Step 2: Validate**

```bash
cd /home/mike/trakrf-infra/terraform/azure
tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format check**

```bash
cd /home/mike/trakrf-infra
tofu fmt -check -recursive terraform/
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
cd /home/mike/trakrf-infra
git add terraform/azure/outputs.tf
git commit -m "$(cat <<'EOF'
feat(tra-436): add outputs for downstream phase-2 consumption

RG name, location, VNet ID, subnet ID — consumed by the phase-2 AKS
resource and by terraform/cloudflare/ for NS delegation via
terraform_remote_state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Justfile `azure` recipe

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Read the existing `aws` recipe to confirm location and pattern**

Run:
```bash
grep -n 'aws:' /home/mike/trakrf-infra/justfile
```

Expected: line number for the `aws:` recipe (around line 38). Use this as the anchor for the edit.

- [ ] **Step 2: Add the `azure` recipe after the `aws` recipe**

Use the Edit tool to insert the recipe:

```make
# Plan and apply Azure infrastructure (AKS, ACR, Azure DNS)
azure: (_backend-conf "terraform/azure")
    @echo "Planning Azure infrastructure..."
    @tofu -chdir=terraform/azure init -backend-config=backend.conf
    @tofu -chdir=terraform/azure plan -out=tfplan
    @tofu -chdir=terraform/azure apply tfplan
```

Insert immediately after the `aws` recipe's closing line (the `tofu apply tfplan` line of the `aws:` recipe) and before the `# List objects in the R2 terraform state bucket` comment that begins the `s3-ls` recipe.

Use this Edit operation:

```
old_string:
# Plan and apply AWS infrastructure (Route53, EKS)
aws: (_backend-conf "terraform/aws")
    @echo "Planning AWS infrastructure..."
    @tofu -chdir=terraform/aws init -backend-config=backend.conf
    @tofu -chdir=terraform/aws plan -out=tfplan
    @tofu -chdir=terraform/aws apply tfplan

# List objects in the R2 terraform state bucket

new_string:
# Plan and apply AWS infrastructure (Route53, EKS)
aws: (_backend-conf "terraform/aws")
    @echo "Planning AWS infrastructure..."
    @tofu -chdir=terraform/aws init -backend-config=backend.conf
    @tofu -chdir=terraform/aws plan -out=tfplan
    @tofu -chdir=terraform/aws apply tfplan

# Plan and apply Azure infrastructure (AKS, ACR, Azure DNS)
azure: (_backend-conf "terraform/azure")
    @echo "Planning Azure infrastructure..."
    @tofu -chdir=terraform/azure init -backend-config=backend.conf
    @tofu -chdir=terraform/azure plan -out=tfplan
    @tofu -chdir=terraform/azure apply tfplan

# List objects in the R2 terraform state bucket
```

- [ ] **Step 3: Verify `just --list` shows the new recipe**

Run:
```bash
cd /home/mike/trakrf-infra
just --list
```

Expected: the output contains `azure` alongside `aws`, `cloudflare`, `bootstrap`, `s3-ls`, etc.

- [ ] **Step 4: Verify `_backend-conf` can generate `terraform/azure/backend.conf`**

Run:
```bash
cd /home/mike/trakrf-infra
just _backend-conf "terraform/azure"
cat terraform/azure/backend.conf
```

Expected: file contains `endpoints = { s3 = "https://44e11a8ed610444ba0026bf7f710355d.r2.cloudflarestorage.com" }` (or whatever `CLOUDFLARE_ACCOUNT_ID` resolves to in the dev shell).

- [ ] **Step 5: Verify `backend.conf` is gitignored**

Run:
```bash
cd /home/mike/trakrf-infra
git status --short terraform/azure/
```

Expected: `backend.conf` does NOT appear in the output (it's covered by the existing `backend.conf` entry in `.gitignore`). If it does appear, stop and check `.gitignore`.

- [ ] **Step 6: Commit**

```bash
cd /home/mike/trakrf-infra
git add justfile
git commit -m "$(cat <<'EOF'
feat(tra-436): add just azure recipe mirroring just aws

Uses the existing _backend-conf recipe to template R2 endpoint into
terraform/azure/backend.conf, then init/plan/apply.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Add `azure` to CI validate matrix

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Edit the `tofu-validate` matrix**

Use the Edit tool:

```
old_string:        dir: [aws, cloudflare, bootstrap]

new_string:        dir: [aws, azure, cloudflare, bootstrap]
```

(Note: the indentation is 8 spaces, matching the existing yaml. Preserve it exactly.)

- [ ] **Step 2: Locally simulate the CI validate step for `azure`**

Run:
```bash
cd /home/mike/trakrf-infra/terraform/azure
rm -rf .terraform .terraform.lock.hcl 2>/dev/null || true
tofu init -backend=false -input=false
tofu validate
```

Expected: both commands succeed. `tofu init` output contains provider downloads for `hashicorp/azurerm` and `hashicorp/random`. `tofu validate` prints `Success! The configuration is valid.`

This mirrors exactly what CI will run via the matrix.

- [ ] **Step 3: Re-initialize for the next task (with backend config)**

We disabled the backend for the CI simulation; re-enable it so Task 7 can run `tofu plan` against real state.

```bash
cd /home/mike/trakrf-infra
just _backend-conf "terraform/azure"
tofu -chdir=terraform/azure init -backend-config=backend.conf
```

Expected: `OpenTofu has been successfully initialized!`

- [ ] **Step 4: Commit**

```bash
cd /home/mike/trakrf-infra
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci(tra-436): add azure to tofu-validate matrix

Free coverage for the new terraform/azure/ module. Runs with
-backend=false so no Azure or R2 credentials are required in CI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: End-to-end verification (no apply)

This task is verification only — no code changes, no commit. Confirms the definition-of-done criteria from the spec.

**Files:** none modified.

- [ ] **Step 1: Confirm Azure CLI is authenticated**

Run:
```bash
az account show --query '{sub: id, name: name}'
```

Expected: JSON showing `sub: 200ab9b0-6cca-4cf4-8e8c-709e0646e0b0` (the subscription ID from `.env.local`). If this fails with "Please run az login", run:

```bash
az login --tenant $ARM_TENANT_ID
az account set --subscription $ARM_SUBSCRIPTION_ID
```

Then re-run `az account show`.

- [ ] **Step 2: Confirm R2 backend auth is working**

Run:
```bash
cd /home/mike/trakrf-infra
just s3-ls
```

Expected: lists objects in the `tf-state` R2 bucket including `aws.tfstate` and `cloudflare.tfstate`. This confirms the `cloudflare-r2` AWS CLI profile is configured correctly.

- [ ] **Step 3: Run the initial plan**

Note: the `just azure` recipe runs init + plan + apply sequentially. For phase 1 we want to stop before apply. Run the init + plan pieces manually:

```bash
cd /home/mike/trakrf-infra
just _backend-conf "terraform/azure"
tofu -chdir=terraform/azure init -backend-config=backend.conf -reconfigure
tofu -chdir=terraform/azure plan -out=tfplan
```

Expected: `tofu plan` succeeds with the following summary (exact resource count, all adds):

```
Plan: 6 to add, 0 to change, 0 to destroy.
```

Resources in the plan (order may vary):
- `random_string.suffix` will be created
- `azurerm_resource_group.main` will be created
- `azurerm_virtual_network.main` will be created
- `azurerm_subnet.aks_nodes` will be created
- `azurerm_network_security_group.aks_nodes` will be created
- `azurerm_subnet_network_security_group_association.aks_nodes` will be created

- [ ] **Step 4: Visually inspect the plan output**

Scan for:
- RG name resolves to `rg-trakrf-demo-ussc`
- Location is `southcentralus`
- VNet `address_space = ["10.143.0.0/16"]`
- Subnet `address_prefixes = ["10.143.0.0/24"]`
- No `var.<foo>` appears unresolved in the plan output
- No provider authentication errors

If any of these don't match, stop and diagnose before proceeding.

- [ ] **Step 5: Confirm `tfplan` file is gitignored**

```bash
cd /home/mike/trakrf-infra
git status --short
```

Expected: `terraform/azure/tfplan` does NOT appear (covered by the existing `*tfplan*` gitignore rule).

- [ ] **Step 6: DO NOT run `tofu apply`**

Apply is out of scope for phase 1 — it happens in TRA-437.

The `tfplan` file stays on disk for reference but is not applied.

---

### Task 8: Push branch and open PR

This isn't implementation — it's the ship step. Included here so the plan doesn't end mid-air.

**Files:** none modified.

- [ ] **Step 1: Review the branch's commit history**

```bash
cd /home/mike/trakrf-infra
git log --oneline main..HEAD
```

Expected: 7 commits — the spec commit from brainstorming, plus 6 implementation commits (Tasks 1–6). Task 7 is verification-only, no commit.

- [ ] **Step 2: Confirm the tree matches expectations**

```bash
cd /home/mike/trakrf-infra
git diff --stat main..HEAD
```

Expected: new files under `terraform/azure/` (provider, variables, main, network, outputs) + modified `justfile`, modified `.github/workflows/ci.yml`, new spec under `docs/superpowers/specs/`, new plan under `docs/superpowers/plans/`.

- [ ] **Step 3: Push the branch**

```bash
cd /home/mike/trakrf-infra
git push -u origin feature/tra-436-aks-scaffolding
```

- [ ] **Step 4: Open the PR**

Use `gh pr create`:

```bash
gh pr create --title "feat(tra-436): AKS demo phase 1 — terraform/azure/ scaffolding" --body "$(cat <<'EOF'
## Summary

Phase 1 of the TRA-435 AKS demo epic. Stands up `terraform/azure/` scaffolding with R2-backed state; no `tofu apply` yet.

- New `terraform/azure/` root module (provider, RG, VNet, subnet, NSG) mirroring `terraform/aws/` file shape
- R2 state key `azure.tfstate` alongside `aws.tfstate` / `cloudflare.tfstate` — no new state backend, no bootstrap script
- `just azure` recipe mirrors `just aws`
- `azure` added to CI `tofu-validate` matrix

Design: `docs/superpowers/specs/2026-04-22-tra-436-aks-demo-phase-1-design.md`
Plan: `docs/superpowers/plans/2026-04-22-tra-436-aks-demo-phase-1.md`

## Test plan

- [ ] `just _backend-conf terraform/azure` generates `backend.conf`
- [ ] `tofu -chdir=terraform/azure init -backend=false` succeeds
- [ ] `tofu -chdir=terraform/azure validate` succeeds
- [ ] `tofu fmt -check -recursive terraform/` exits 0
- [ ] `tofu -chdir=terraform/azure plan` shows exactly 6 adds, 0 changes, 0 destroys
- [ ] CI `tofu-validate (azure)` matrix cell passes

Linear: [TRA-436](https://linear.app/trakrf/issue/TRA-436)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Report the PR URL**

`gh pr create` prints the PR URL on success. Paste it back to the user.

- [ ] **Step 6: Verify CI is green**

Wait for CI to run on the PR (usually <2 minutes). Check:

```bash
gh pr checks
```

Expected: all checks passing, including `tofu validate (azure)`.

If a check fails, investigate and fix with a new commit pushed to the branch — do not force-push.

---

## Self-Review Checklist

Walking through the spec section-by-section to confirm coverage:

- **§ State backend** → Task 1 (provider.tf backend block) + Task 5 (_backend-conf recipe usage)
- **§ Root module file layout** → Tasks 1–4 (provider, variables, main, network, outputs)
- **§ Networking** → Task 3 (VNet + subnet + NSG)
- **§ Node sizing** → explicitly out of scope for phase 1 (context for phase 2); plan references it in Task 3 comments only
- **§ Justfile integration** → Task 5
- **§ CI integration** → Task 6
- **§ Definition of done** → Task 7 verifies each of the 5 DoD items from the spec
- **§ Port preference (EKS-first)** → Task 1 provider backend block is a direct copy of `terraform/aws/provider.tf`; hashsphere used only for the `azurerm` + `features` block

No spec requirements are unaddressed.

## Known Constraints

- `tofu plan` in Task 7 requires working Azure CLI auth (`az login`). If the plan step fails with an authentication error, run `az login --tenant $ARM_TENANT_ID` and retry. Does NOT need an actual apply or any real Azure resource provisioning — the `azurerm` provider only needs auth to verify the subscription is reachable.
- `just s3-ls` in Task 7 requires the `cloudflare-r2` AWS CLI profile (already configured for the existing `aws/` module). No setup work needed.
- `tofu init` in Task 6 Step 3 uses `-reconfigure` because Step 2 ran init with `-backend=false`. The `-reconfigure` flag switches the backend mode cleanly without touching state.

## Out of Scope (phase 2+)

- `aks.tf`, `acr.tf`, `dns.tf`, `iam.tf` — TRA-437
- `terraform/cloudflare/azure-delegation.tf` — TRA-437
- ArgoCD / Helm / cert-manager — TRA-438
- GH Actions OIDC for Azure plan/apply — TRA-439
- `tofu apply` of any kind — TRA-437
