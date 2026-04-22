# TRA-439 Azure CI OIDC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions plan-on-PR + `workflow_dispatch`-gated apply for `terraform/azure/`, authenticated via OIDC against a new dedicated `trakrf-infra-ci` Azure AD app registration managed in-repo.

**Architecture:** One new terraform file creates an AAD application + service principal + two federated identity credentials (`pull_request`, `ref:refs/heads/main`) + a `Contributor` role assignment on the main RG. One new GitHub Actions workflow plans on PR (comments plan on the PR) and applies only when manually dispatched from `main` with a typed `APPLY` confirmation. R2 state backend credentials flow via `AWS_*` env vars; the `profile = "cloudflare-r2"` in `provider.tf` is overridden at `tofu init` time with `-backend-config=profile=`.

**Tech Stack:** OpenTofu, azurerm + azuread providers, GitHub Actions (`azure/login@v2`, `opentofu/setup-opentofu@v1`, `actions/github-script@v7`), Cloudflare R2 via the s3 backend.

**Spec:** `docs/superpowers/specs/2026-04-22-tra-439-azure-ci-oidc-design.md`

**Branch:** `feature/tra-439-azure-ci-oidc` (already created; spec committed at `76c6b71`).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `terraform/azure/ci.tf` | create | AAD app + SP + 2 federated creds + `Contributor` role assignment |
| `terraform/azure/outputs.tf` | modify | Add `ci_client_id` output |
| `.github/workflows/terraform-azure.yml` | create | Plan on PR + `workflow_dispatch` apply |

No other files change. `provider.tf` stays untouched by design — the `profile = "cloudflare-r2"` is intentional local documentation; CI overrides it at init.

---

## Task 1: Preflight — confirm clean starting state

**Files:** none (verification only)

- [ ] **Step 1: Verify `tofu plan` shows no drift**

Run: `cd /home/mike/trakrf-infra && just azure` up through the plan phase (answer `no` at the apply prompt or `Ctrl-C` after reviewing plan).

Expected: `No changes. Your infrastructure matches the configuration.`

If there's drift, stop and resolve it before continuing. This plan assumes a clean baseline so the Task 2 plan diff is unambiguous.

- [ ] **Step 2: Confirm operator has AAD app-reg permission**

Run: `az ad app list --filter "displayName eq 'probe-delete-me'" -o none 2>&1 | head -1 || true`

If the `az` CLI returns without an `Insufficient privileges` or `Authorization_RequestDenied` error, you have read. To actually confirm write, run a create+delete round-trip:

```bash
APP_ID=$(az ad app create --display-name probe-delete-me --query appId -o tsv) && \
  az ad app delete --id "$APP_ID" && echo "OK: app-reg create+delete works"
```

Expected: `OK: app-reg create+delete works`

If this fails with `Authorization_RequestDenied`, stop — resolve tenant-level permission before continuing.

---

## Task 2: Add `terraform/azure/ci.tf`

**Files:**
- Create: `terraform/azure/ci.tf`

- [ ] **Step 1: Create `ci.tf`**

Write exactly this content to `/home/mike/trakrf-infra/terraform/azure/ci.tf`:

```hcl
# GitHub Actions OIDC — federated identity for terraform/azure/ CI (TRA-439)
# Dedicated app registration (not shared with hashsphere). See
# docs/superpowers/specs/2026-04-22-tra-439-azure-ci-oidc-design.md.

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

- [ ] **Step 2: Verify formatting**

Run: `tofu fmt -check terraform/azure/ci.tf`

Expected: exit 0, no output.

If it reports the file needs formatting, run `tofu fmt terraform/azure/ci.tf` and re-verify.

- [ ] **Step 3: Verify validation**

Run: `tofu -chdir=terraform/azure validate`

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Run `tofu plan` and verify exact shape of diff**

Run: `just azure` (abort at apply prompt).

Expected plan summary: `Plan: 5 to add, 0 to change, 0 to destroy.`

Expected resources added:
- `azuread_application.trakrf_infra_ci`
- `azuread_service_principal.trakrf_infra_ci`
- `azuread_application_federated_identity_credential.gha_pr`
- `azuread_application_federated_identity_credential.gha_main`
- `azurerm_role_assignment.trakrf_infra_ci_contributor`

Verify: no modifications to existing resources (`azuread_group.aks_admins`, `azurerm_resource_group.main`, AKS, ACR, DNS zone, cert-manager UAI, Traefik PIP). If any existing resource shows changes, stop — drift or unintended coupling.

---

## Task 3: Add `ci_client_id` output

**Files:**
- Modify: `terraform/azure/outputs.tf`

- [ ] **Step 1: Read the existing file to find the append point**

Run: `cat terraform/azure/outputs.tf`

Note the last output block's closing `}` — the new output appends after it.

- [ ] **Step 2: Append the output**

Append to `/home/mike/trakrf-infra/terraform/azure/outputs.tf`:

```hcl

output "ci_client_id" {
  description = "Client ID of trakrf-infra-ci app registration (GitHub secret: AZURE_CLIENT_ID)"
  value       = azuread_application.trakrf_infra_ci.client_id
}
```

- [ ] **Step 3: Verify formatting**

Run: `tofu fmt -check terraform/azure/outputs.tf`

Expected: exit 0.

If not, run `tofu fmt terraform/azure/outputs.tf` and re-verify.

- [ ] **Step 4: Verify validation**

Run: `tofu -chdir=terraform/azure validate`

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Run `tofu plan` to confirm output addition**

Run: `just azure` (abort at apply).

Expected: `Plan: 5 to add, 0 to change, 0 to destroy.` (same resource count) plus a `Changes to Outputs:` section listing `+ ci_client_id = (known after apply)`.

- [ ] **Step 6: Commit the terraform additions**

```bash
git add terraform/azure/ci.tf terraform/azure/outputs.tf
git commit -m "$(cat <<'EOF'
feat(tra-439): add trakrf-infra-ci app registration for GH Actions OIDC

New dedicated AAD app reg (not shared with hashsphere) with federated
identity credentials for repo:trakrf/infra pull_request and
ref:refs/heads/main subjects, plus Contributor on the main RG.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Apply locally and capture outputs

**Files:** none (applies state; captures values for next task)

- [ ] **Step 1: Apply**

Run: `just azure` and type `yes` at the apply prompt.

Expected tail: `Apply complete! Resources: 5 added, 0 changed, 0 destroyed.` and `Outputs:` block including `ci_client_id = "<GUID>"`.

- [ ] **Step 2: Capture values into shell vars**

Run:

```bash
cd /home/mike/trakrf-infra
CI_CLIENT_ID=$(tofu -chdir=terraform/azure output -raw ci_client_id)
AZ_TENANT=$(az account show --query tenantId -o tsv)
AZ_SUB=$(az account show --query id -o tsv)
CF_ACCT=$(grep '^CLOUDFLARE_ACCOUNT_ID=' .env.local | cut -d= -f2-)
echo "CI_CLIENT_ID=$CI_CLIENT_ID"
echo "AZ_TENANT=$AZ_TENANT"
echo "AZ_SUB=$AZ_SUB"
echo "CF_ACCT=$CF_ACCT"
```

Expected: all four values print as non-empty GUIDs / account IDs.

- [ ] **Step 3: Capture R2 credentials from local AWS config**

The R2 creds live in `~/.aws/credentials` under the `cloudflare-r2` profile (see `just s3-ls` and `provider.tf`).

Run:

```bash
R2_KEY=$(aws configure get aws_access_key_id --profile cloudflare-r2)
R2_SECRET=$(aws configure get aws_secret_access_key --profile cloudflare-r2)
[[ -n "$R2_KEY" && -n "$R2_SECRET" ]] && echo "OK: R2 creds captured" || echo "FAIL: missing R2 creds"
```

Expected: `OK: R2 creds captured`.

If missing, re-run `just bootstrap` to regenerate the R2 token, or grab from your credentials manager. Do NOT continue without these.

- [ ] **Step 4: Verify AAD objects exist**

Run: `az ad app show --id "$CI_CLIENT_ID" --query "{displayName:displayName, appId:appId}" -o table`

Expected: `displayName` is `trakrf-infra-ci`, `appId` is the same GUID as `$CI_CLIENT_ID`.

Run: `az ad app federated-credential list --id "$CI_CLIENT_ID" --query "[].{name:name, subject:subject}" -o table`

Expected: two rows — `github-pull-request` / `repo:trakrf/infra:pull_request` and `github-main-branch` / `repo:trakrf/infra:ref:refs/heads/main`.

---

## Task 5: Set GitHub secrets

**Files:** none (repo-level GitHub state)

- [ ] **Step 1: Set all six secrets**

With the shell vars from Task 4 still in scope:

```bash
gh secret set AZURE_CLIENT_ID       --body "$CI_CLIENT_ID"
gh secret set AZURE_TENANT_ID       --body "$AZ_TENANT"
gh secret set AZURE_SUBSCRIPTION_ID --body "$AZ_SUB"
gh secret set CLOUDFLARE_ACCOUNT_ID --body "$CF_ACCT"
gh secret set R2_ACCESS_KEY_ID      --body "$R2_KEY"
gh secret set R2_SECRET_ACCESS_KEY  --body "$R2_SECRET"
```

Expected: each command exits 0 with a message like `✓ Set secret AZURE_CLIENT_ID for trakrf/infra`.

- [ ] **Step 2: Verify all six are present**

Run: `gh secret list`

Expected: output includes all six secret names (value is redacted; only names + timestamps shown).

---

## Task 6: Add the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/terraform-azure.yml`

- [ ] **Step 1: Create the workflow file**

Write exactly this content to `/home/mike/trakrf-infra/.github/workflows/terraform-azure.yml`:

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

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/terraform-azure.yml'))" && echo "OK: yaml parses"`

Expected: `OK: yaml parses`.

- [ ] **Step 3: Lint the workflow if `actionlint` is available**

Run: `command -v actionlint && actionlint .github/workflows/terraform-azure.yml || echo "skip: actionlint not installed"`

Expected: either clean actionlint output, or `skip: actionlint not installed`. If actionlint flags anything, fix it.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/terraform-azure.yml
git commit -m "$(cat <<'EOF'
feat(tra-439): add terraform-azure workflow for PR plan + dispatch apply

Plan job comments tofu plan on PRs that touch terraform/azure/** or
this workflow. Apply job runs only via workflow_dispatch on main with
a typed APPLY confirmation. R2 backend profile is overridden at init
time via -backend-config=profile= so CI uses AWS_* env vars.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Push branch and open PR

**Files:** none (git + GitHub state)

- [ ] **Step 1: Push the branch**

Run: `git push -u origin feature/tra-439-azure-ci-oidc`

Expected: remote branch created.

- [ ] **Step 2: Open the PR**

Run:

```bash
gh pr create --title "feat(tra-439): Azure CI OIDC + terraform-azure workflow" --body "$(cat <<'EOF'
## Summary
- New `trakrf-infra-ci` Azure AD app registration with federated credentials for GH Actions OIDC (`terraform/azure/ci.tf`).
- New `terraform-azure.yml` workflow: plan on PR, `workflow_dispatch`-gated apply on main.
- Rejects reuse of hashsphere's app reg (separate concerns) and rejects auto-apply-on-merge (R2 locking + single-maintainer gate).

Spec: `docs/superpowers/specs/2026-04-22-tra-439-azure-ci-oidc-design.md`
Plan: `docs/superpowers/plans/2026-04-22-tra-439-azure-ci-oidc.md`
Linear: [TRA-439](https://linear.app/trakrf/issue/TRA-439)

## Test plan
- [ ] The plan comment on this PR itself renders with `No changes.` (ci.tf already applied locally pre-PR)
- [ ] After merge, `gh workflow run terraform-azure.yml -f confirm=APPLY` on main exits zero-diff

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

---

## Task 8: Verify the plan-comment smoke test (checkpoint 2)

**Files:** none (CI observation)

- [ ] **Step 1: Watch the workflow run**

Run: `gh pr checks --watch` (from the PR branch)

Expected: `terraform-azure / plan` job transitions through queued → in_progress → ✓ completed with success. If it fails:
- `AADSTS70021 Sub claim doesn't match` → federated credential subject mismatch. Re-check Task 2 subjects against the workflow name.
- `AuthorizationFailed` → role assignment not propagated yet. Re-run the job after 60s.
- `Error: Failed to get existing workspaces: ... Access Denied` → R2 creds wrong. Re-verify Task 4 step 3 and Task 5.
- `Error: error configuring S3 Backend ... profile "cloudflare-r2" not found` → `-backend-config=profile=` didn't override. Fallback: edit `provider.tf` to remove `profile = "cloudflare-r2"` and update the justfile's `_backend-conf` helper to append `profile = "cloudflare-r2"` to the generated backend.conf locally (option 3b from the spec). Commit as a follow-up in this same PR.

- [ ] **Step 2: Verify plan comment rendered on PR**

Run: `gh pr view --comments | grep -A 5 'Terraform Plan (terraform/azure)'`

Expected: the plan header plus a fenced code block containing `No changes.` (since we applied locally in Task 4, CI sees state == config).

---

## Task 9: Merge the PR

**Files:** none (PR merge)

Per repo memory `feedback_never_merge_to_main.md`, always merge via PR UI / `gh`, never locally.

- [ ] **Step 1: Merge with `--merge` per CLAUDE.md**

Run: `gh pr merge --merge --delete-branch`

Expected: PR merged, branch deleted remotely.

- [ ] **Step 2: Pull `main` locally**

Run: `git checkout main && git pull`

Expected: fast-forward to the merge commit.

---

## Task 10: Verify the dispatch-apply path (checkpoint 3)

**Files:** none (CI observation)

- [ ] **Step 1: Trigger the apply workflow**

Run: `gh workflow run terraform-azure.yml -f confirm=APPLY --ref main`

Expected: `✓ Created workflow_dispatch event for terraform-azure.yml at main`.

- [ ] **Step 2: Watch the run**

Run: `gh run list --workflow=terraform-azure.yml --limit 1` to get the run ID, then `gh run watch <ID>`.

Expected: `terraform-azure / apply` succeeds. The `tofu apply -auto-approve` step's tail should read: `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.`

If it fails with a reason other than the ones listed in Task 8 Step 1, stop and investigate before marking the feature done.

- [ ] **Step 3: Negative-path sanity check (optional but recommended)**

Run: `gh workflow run terraform-azure.yml -f confirm=nope --ref main`

Expected: the apply job's `if:` guard skips it — the run completes with the apply job reported as skipped (not failed). Confirms the confirm-string gate actually gates.

---

## Task 11: Close out Linear

**Files:** none (Linear state)

- [ ] **Step 1: Mark TRA-439 Done**

Via Linear MCP or web UI, move TRA-439 to `Done`. Note in the closing comment the two verification checkpoints passed (plan comment rendered, dispatch apply zero-diffed) and link the merged PR.

- [ ] **Step 2: Check parent epic TRA-435**

If TRA-439 was the last open child, move TRA-435 to `Done`. Otherwise leave as-is.

---

## Acceptance

All of:

- `terraform/azure/ci.tf` + `outputs.tf` change applied; `tofu output ci_client_id` returns a GUID.
- Six GitHub secrets present (`gh secret list`).
- `.github/workflows/terraform-azure.yml` merged to `main`.
- Task 8 plan comment rendered on the PR.
- Task 10 dispatch apply succeeded with zero-diff.
- TRA-439 in `Done`.

## Out of scope (do NOT expand)

- Narrower RBAC scoping (stay at `Contributor` on the main RG).
- `tofu fmt` / `validate` in the new workflow (duplicates `ci.yml`).
- Fork-contributor handling.
- CI for `terraform/aws/` or `terraform/cloudflare/`.
- Removing `profile = "cloudflare-r2"` from `provider.tf` — only do this if Task 8 Step 1's fallback path is actually needed.
