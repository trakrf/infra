# CLAUDE.md

## Stack
- **IaC**: OpenTofu (Terraform fork) with Cloudflare provider
- **State**: Cloudflare R2 bucket
- **Env**: `.env.local` (not `.env`), loaded via direnv

## Commands
- `just domains` — plan and apply `domains/` resources
- `just bootstrap` — bootstrap initial Cloudflare resources
- Manual: `tofu -chdir=domains init/plan/apply`

## Git Workflow
- **Never push directly to main** — all changes via PR
- Branch naming: `feature/add-xyz`, `fix/broken-xyz`
- Conventional commits: `feat:`, `fix:`, `chore:`
- Merge PRs with `--merge` (never `--squash` or `--rebase`)

## Project Structure
- `bootstrap/` — initial Cloudflare setup (R2, tokens)
- `domains/` — main infrastructure (DNS, Pages, Email)

## Debugging
- `tofu -chdir=domains state list`
- `tofu -chdir=domains state show <resource>`
- `just s3-ls`

## Rules
- If you'll want it tomorrow, Terraform it today — dashboard is for exploration only
- No GitOps yet — manual `just domains` to apply
- Repo remote: `git@github.com:trakrf/infra.git`

## Verification
- Run `tofu plan` before claiming completion
- Report actual plan output — no false optimism
