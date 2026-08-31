# CLAUDE.md

@AGENTS.md

## Stack
- OpenTofu with Cloudflare + AWS + GCP + Azure providers
- State in a Cloudflare R2 bucket, shared across providers
- `.env.local` (not `.env`), loaded via direnv
- Version pinned in `.opentofu-version`; a minor bump also needs
  `required_version` updated in all five roots

## Commands
- `just cloudflare` / `just aws` / `just bootstrap` — plan and apply
- `tofu -chdir=terraform/<provider> init|plan|apply` — manual
- `tofu -chdir=terraform/<provider> state list|show <resource>`, `just s3-ls`
- `.claude/csw-validate.sh` — local mirror of CI; run before opening a PR

## Layout
`terraform/{bootstrap,cloudflare,aws,gcp,azure}/` — one root per provider.
`helm/` charts, `argocd/` manifests, `scripts/` bootstrap helpers, `docs/` runbooks.

## Rules
- Specs and plans go to `docs/superpowers/`
- If you'll want it tomorrow, Terraform it today — the dashboard is for exploration
- No GitOps yet; apply manually
- Never merge to main locally
- Renaming a stateful resource needs a `moved` block
- A worktree has no `.env.local`: run `tofu` and `just mosquitto-secrets` from the
  main checkout
- Run `tofu plan` before claiming completion, and report the actual output
