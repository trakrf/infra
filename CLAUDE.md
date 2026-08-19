# CLAUDE.md

## Stack
- **IaC**: OpenTofu (Terraform fork) with Cloudflare + AWS providers
- **State**: Cloudflare R2 bucket (shared across all providers)
- **Env**: `.env.local` (not `.env`), loaded via direnv
- **OpenTofu version**: pinned in `.opentofu-version` (repo root) — the single
  source CI reads via `setup-opentofu`'s `tofu_version_file`. Bumping across a
  minor (1.12 → 1.13) also requires updating `required_version` in all five
  roots (`terraform/{gcp,aws,azure}/provider.tf`,
  `terraform/{bootstrap,cloudflare}/versions.tf`), which is deliberately
  bounded (`~> 1.12`) so an unintended jump fails loudly at `init`.

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

## Worktrees
- **Canonical location**: worktrees go in `.claude/worktrees/<name>/` (repo-relative), one per branch — gitignored by the narrow `.claude/worktrees/` rule, and the same convention across all trakrf repos (docs/platform/infra). The ignore is deliberately narrow (matching trakrf/docs) so the rest of `.claude/` stays tracked and shared agent config is versioned: `.claude/csw.json` (csw workflow config — tracker, base branch, validate command) and `.claude/csw-validate.sh` (local mirror of `.github/workflows/ci.yml`; run it before opening a PR).
- **Create** with the native `EnterWorktree` tool (writes to `.claude/worktrees/<name>`, auto-creates branch `worktree-<name>` — rename to a `feat/...`/`fix/...` branch after if desired). Do NOT use manual `git worktree add`, and do NOT create a `.worktrees/` dir or a `.claude/worktrees -> ../.worktrees` symlink (fresh-clone footgun). Manual `git worktree` is only the superpowers fallback for harnesses with no native tool — not us.
- **Cleanup**: `git worktree list` is authoritative (empty leftover dirs are not worktrees); use `ExitWorktree` (or `git worktree remove`) to leave/remove.

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
