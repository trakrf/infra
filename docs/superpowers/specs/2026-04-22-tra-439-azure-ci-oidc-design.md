# TRA-439 — AKS demo phase 4: GitHub Actions OIDC for `terraform/azure/`

**Date**: 2026-04-22
**Linear**: [TRA-439](https://linear.app/trakrf/issue/TRA-439) (child of epic [TRA-435](https://linear.app/trakrf/issue/TRA-435))
**Status**: Design approved, pending user review of this document
**Branch**: `feature/tra-439-azure-ci-oidc`

## Context

TRA-438 landed AKS + multi-cluster helm/argocd overlays. `terraform/azure/` is now a real, non-trivial directory managed exclusively by local `just azure` runs. Phase 4 adds GitHub Actions automation: plan-on-PR so terraform changes are visible in review, and a `workflow_dispatch`-gated apply so a human still pulls the trigger.

This phase is the narrowest of the TRA-435 arc — one new terraform file, one new workflow, some GitHub secrets.

## Design decisions (brainstormed 2026-04-22)

### Plan-on-PR + `workflow_dispatch` apply (not auto-apply-on-merge)

Hashsphere's template auto-applies on push-to-main. Rejected here for two reasons:

1. **R2 locking is weaker than S3+DynamoDB.** The s3 backend against R2 uses optimistic locking via object metadata; it works in practice but a CI↔local race during a bad day would corrupt state.
2. **Single-maintainer repo.** The human gate between plan review and apply is already load-bearing — mirroring it in CI as an explicit dispatch keeps the mental model consistent.

`workflow_dispatch` requires typing `APPLY` as a confirmation input, adds a visible GitHub audit trail, and means the same operator reviews the PR plan and then triggers the apply.

### Dedicated `trakrf-infra-ci` app registration (not reused from hashsphere)

TRA-439's original scope said "reuse hashsphere's app reg." Rejected during brainstorming:

- hashsphere and trakrf are **separate concerns**. hashsphere is a standalone consulting demo; trakrf is the SaaS / portfolio piece with real customers.
- Coupling CI identity across the two is convenience debt — destroying hashsphere's app reg would silently break trakrf CI, and the repo is going public so pointing at a hashsphere artifact is a code-smell.
- Creating a new app registration in the (shared, user-owned) tenant is cheap.

### IAM terraformed in `terraform/azure/ci.tf`

Same lane as `identity.tf` (which already manages the `trakrf-aks-admins` AAD group). Self-describing, survives destroy-rebuild cycles without a separate `docs/setup.md` remembering to run `az ad app create`. Consistent with the repo's "if you'll want it tomorrow, Terraform it today" rule.

## Architecture

### New file: `terraform/azure/ci.tf`

```hcl
# GitHub Actions OIDC — federated identity for terraform/azure/ CI (TRA-439)
resource "azuread_application" "trakrf_infra_ci" {
  display_name = "trakrf-infra-ci"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "trakrf_infra_ci" {
  client_id = azuread_application.trakrf_infra_ci.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "gha_pr" {
  application_id = azuread_application.trakrf_infra_ci.id
  display_name   = "github-pull-request"
  description    = "GitHub Actions PR plan jobs"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:trakrf/infra:pull_request"
}

resource "azuread_application_federated_identity_credential" "gha_main" {
  application_id = azuread_application.trakrf_infra_ci.id
  display_name   = "github-main-branch"
  description    = "GitHub Actions apply jobs (workflow_dispatch on main)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:trakrf/infra:ref:refs/heads/main"
}

resource "azurerm_role_assignment" "trakrf_infra_ci_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.trakrf_infra_ci.object_id
}
```

### Addition to `terraform/azure/outputs.tf`

```hcl
output "ci_client_id" {
  description = "Client ID of trakrf-infra-ci app registration (GitHub secret: AZURE_CLIENT_ID)"
  value       = azuread_application.trakrf_infra_ci.client_id
}
```

### Design choices inside the terraform

- **Scope = `Contributor` on `azurerm_resource_group.main`.** The RG owns the VNet, AKS, ACR, DNS zone, and managed identities. Narrower scoping would mean maintaining a denylist of resource types, which is less secure than one tight RG grant.
- **Two separate `federated_identity_credential` resources**, one per subject. Azure's API requires one subject per credential.
- **No `TF_VAR` or variable plumbing** — all values are either data-source-derived or hard-coded constants. Nothing to pass in.

### New file: `.github/workflows/terraform-azure.yml`

Skeleton (full file committed alongside this spec):

```yaml
name: terraform-azure

on:
  pull_request:
    branches: [main]
    paths:
      - 'terraform/azure/**'
      - '.github/workflows/terraform-azure.yml'
  workflow_dispatch:
    inputs:
      confirm:
        description: 'Type APPLY to confirm'
        required: true

concurrency:
  group: terraform-azure-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: false

permissions:
  contents: read
  id-token: write
  pull-requests: write

env:
  ARM_CLIENT_ID:          ${{ secrets.AZURE_CLIENT_ID }}
  ARM_TENANT_ID:          ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID:    ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  ARM_USE_OIDC:           "true"
  TF_VAR_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  AWS_ACCESS_KEY_ID:      ${{ secrets.R2_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY:  ${{ secrets.R2_SECRET_ACCESS_KEY }}
  R2_ENDPOINT:            https://${{ secrets.CLOUDFLARE_ACCOUNT_ID }}.r2.cloudflarestorage.com

jobs:
  plan:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: terraform/azure
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id:       ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: opentofu/setup-opentofu@v1
      - name: Write backend.conf
        run: printf 'endpoints = { s3 = "%s" }\n' "$R2_ENDPOINT" > backend.conf
      - name: Tofu init
        run: tofu init -backend-config=backend.conf -backend-config=profile=
      - name: Tofu plan
        run: tofu plan -no-color -out=tfplan 2>&1 | tee plan_output.txt
      - name: Comment plan on PR
        uses: actions/github-script@v7
        if: always()
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('terraform/azure/plan_output.txt', 'utf8');
            const truncated = plan.length > 60000 ? plan.substring(0, 60000) + '\n...(truncated)' : plan;
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: `### Terraform Plan (terraform/azure)\n\n\`\`\`\n${truncated}\n\`\`\``
            });

  apply:
    if: github.event_name == 'workflow_dispatch' && github.event.inputs.confirm == 'APPLY' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: terraform/azure
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id:       ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: opentofu/setup-opentofu@v1
      - name: Write backend.conf
        run: printf 'endpoints = { s3 = "%s" }\n' "$R2_ENDPOINT" > backend.conf
      - name: Tofu init
        run: tofu init -backend-config=backend.conf -backend-config=profile=
      - name: Tofu apply
        run: tofu apply -auto-approve
```

### Workflow design choices

- **`opentofu/setup-opentofu@v1`**, not `hashicorp/setup-terraform@v3`. The repo is OpenTofu (per `CLAUDE.md`); keep CI parity with local.
- **`paths:` filter** on `terraform/azure/**` — PRs that only touch `helm/`, `argocd/`, or other providers don't trigger an Azure plan.
- **`cancel-in-progress: false`** — safe for plans, critical for the apply dispatch. Don't cancel anything in this group.
- **`-backend-config=profile=`** (empty value) at `tofu init` time overrides the `profile = "cloudflare-r2"` baked into `provider.tf`. Tofu's s3 backend then falls back to `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars. No edits to `provider.tf` — the profile reference there stays as documentation for local usage.
- **No `fmt` / `validate` in this workflow** — `ci.yml` already runs both across all four terraform dirs in a matrix. No duplication.
- **Apply job `if:` triple-guard** — event is `workflow_dispatch`, input `confirm == 'APPLY'`, ref is `main`. Any two of the three failing still blocks apply.

## GitHub secrets (manual, one-time)

| Secret | Source |
|---|---|
| `AZURE_CLIENT_ID` | `tofu -chdir=terraform/azure output -raw ci_client_id` |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
| `CLOUDFLARE_ACCOUNT_ID` | `.env.local` → `CLOUDFLARE_ACCOUNT_ID` |
| `R2_ACCESS_KEY_ID` | bootstrap output (R2 s3-compatible token) |
| `R2_SECRET_ACCESS_KEY` | bootstrap output |

Set via `gh secret set <NAME>`.

## Operator bootstrap sequence

1. Create feature branch, add `ci.tf` + `outputs.tf` addition + workflow file.
2. Locally: `just azure` — applies the new app reg, SP, federated creds, role assignment.
3. Grab the new client ID: `tofu -chdir=terraform/azure output -raw ci_client_id`.
4. `gh secret set` the six secrets listed above (the Azure trio, the R2 trio).
5. Push branch, open PR. First plan comment on this same PR is the smoke test.
6. Merge (standard repo workflow — PR only, no local merges to main).
7. First dispatch apply as verification: `gh workflow run terraform-azure.yml -f confirm=APPLY` against `main`. Expect zero diff.

## Testing

Three ordered checkpoints; no unit tests.

| # | Test | Pass criteria |
|---|---|---|
| 1 | Local `just azure` after adding `ci.tf` | Plan shows exactly: 1 app, 1 SP, 2 federated creds, 1 role assignment, 1 output. No drift in `identity.tf` / `main.tf` / `aks.tf`. |
| 2 | Open PR that touches `terraform/azure/` trivially | Plan job runs, comments plan on PR, plan shows "No changes." (OIDC federation + RBAC smoke test.) |
| 3 | `gh workflow run terraform-azure.yml -f confirm=APPLY` on `main` with no pending changes | Apply job runs, `tofu apply` exits clean with zero changes. |

Writing `terratest` or similar for a ~50-line terraform file plus an ~80-line workflow would be pure ceremony.

## Failure modes and mitigations

| Failure | Why it happens | Mitigation |
|---|---|---|
| `just azure` fails at step 2 with "insufficient privileges" | Operator lacks Azure AD permissions to create app registrations | Prerequisite — must have this, no in-repo workaround |
| `AADSTS70021: Sub claim does not match` on first PR plan | Federated credential subject misconfigured | Error message is explicit; compare against the two subjects in `ci.tf` |
| `AuthorizationFailed` at plan time | Role assignment hasn't propagated yet (Azure AD eventual consistency) | Re-run the job; first-apply SP→role propagation can take 30–60s |
| Stale R2 state lock | Concurrent apply attempted despite `workflow_dispatch` gate | `tofu force-unlock` locally; investigate whether gate was bypassed |
| Fork PR triggers the workflow | GH Actions `id-token: write` is denied for fork PRs by default | Safe default — OIDC exchange fails, plan job errors with no tokens minted, nothing applies. No action needed until fork contributors exist. |

## Out of scope

- CI automation for `terraform/aws/` or `terraform/cloudflare/` — those stay manual per current pattern. Separate ticket if/when needed.
- Narrower-than-`Contributor` RBAC. Revisit if the blast radius of the RG grows (e.g., non-AKS subscriptions).
- Automatic `tofu fmt` or `tofu validate` in this workflow — already in `ci.yml`.
- Any handling of fork PRs. GH defaults are safe; no engineering until there are fork contributors.

## Rollout

One PR containing: `terraform/azure/ci.tf`, `terraform/azure/outputs.tf` diff, `.github/workflows/terraform-azure.yml`. The operator applies locally first, sets GitHub secrets, then merges. Merging before secrets are set causes the first PR plan to fail non-destructively — annoying, re-run after secrets land.

## Acceptance

- `terraform/azure/ci.tf` applied; `tofu output ci_client_id` returns a GUID.
- Six GitHub secrets set.
- Workflow file merged to `main`.
- Checkpoint 2 passes (PR plan comment renders).
- Checkpoint 3 passes (dispatch apply exits zero-diff).
- TRA-439 moved to Done; TRA-435 epic reflects phase 4 complete.
