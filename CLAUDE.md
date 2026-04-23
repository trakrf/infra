# CLAUDE.md

## Stack
- **IaC**: OpenTofu (Terraform fork) with Cloudflare + AWS providers
- **State**: Cloudflare R2 bucket (shared across all providers)
- **Env**: `.env.local` (not `.env`), loaded via direnv

## Commands
- `just cloudflare` — plan and apply Cloudflare resources
- `just aws` — plan and apply AWS resources
- `just bootstrap` — bootstrap initial Cloudflare resources (R2, tokens)
- Manual: `tofu -chdir=terraform/cloudflare init/plan/apply`

## Git Workflow
- **Never push directly to main** — all changes via PR
- **Never merge to main locally** — push the branch and open a PR instead. When finishing a branch, default to creating a PR without asking.
- Branch naming: `feature/add-xyz`, `fix/broken-xyz`
- Conventional commits: `feat:`, `fix:`, `chore:`
- Merge PRs with `--merge` (never `--squash` or `--rebase`)

## Project Structure
- `terraform/bootstrap/` — one-time Cloudflare setup (R2 state bucket, API tokens)
- `terraform/cloudflare/` — Cloudflare infrastructure (DNS, Pages, email)
- `terraform/aws/` — AWS infrastructure (Route53, EKS)
- `terraform/gcp/` — GCP infrastructure (future)
- `helm/` — Helm charts (future)
- `argocd/` — ArgoCD application manifests (future)

## Debugging
- `tofu -chdir=terraform/cloudflare state list`
- `tofu -chdir=terraform/cloudflare state show <resource>`
- `just s3-ls`

## Rules
- If you'll want it tomorrow, Terraform it today — dashboard is for exploration only
- No GitOps yet — manual `just cloudflare` / `just aws` to apply
- Repo remote: `git@github.com:trakrf/infra.git`

## Verification
- Run `tofu plan` before claiming completion
- Report actual plan output — no false optimism
