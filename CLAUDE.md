# Claude Code Instructions for trakrf-infra

## Project Overview
This is the infrastructure-as-code repository for trakrf.id, managing Cloudflare resources via OpenTofu/Terraform.

## Development Workflow

### IMPORTANT: Use Claude Spec Workflow (CSW)
This project uses the Claude Spec Workflow for all infrastructure changes. **DO NOT bypass this workflow.**

### Workflow Steps (MANDATORY)

1. **Create Specification**: `/spec [feature-name]`
   - Captures requirements and context
   - Saves to `spec/[feature]/spec.md`
   - Get user approval before proceeding

2. **Generate Plan**: `/plan spec/[feature]/spec.md`
   - Analyzes spec and creates detailed implementation plan
   - Assesses complexity and risks
   - Saves to `spec/[feature]/plan.md`
   - Wait for user to review plan

3. **Execute Build**: `/build`
   - Implements according to plan
   - Runs validation gates
   - Tracks progress in `spec/[feature]/log.md`

4. **Ship Changes**: `/ship`
   - Final validation
   - Creates PR with proper documentation
   - Cleans up artifacts

### DO NOT Skip Steps
❌ **NEVER** create spec and immediately start coding
❌ **NEVER** bypass `/plan` and `/build` commands
❌ **NEVER** manually create PRs when using CSW
❌ **NEVER** push directly to main - ALWAYS use feature branches and PRs

✅ **ALWAYS** follow the four-step workflow
✅ **ALWAYS** wait for user approval between steps
✅ **ALWAYS** use validation gates
✅ **ALWAYS** create feature branch → commit → push → PR → merge

## Git Workflow (MANDATORY)

### Feature Branch Process
1. Create feature branch: `git checkout -b feature/descriptive-name`
2. Make changes and commit
3. Push branch: `git push -u origin feature/descriptive-name`
4. Create PR: `gh pr create --title "..." --body "..."`
5. Merge PR: `gh pr merge N --merge --delete-branch`

### Merge Strategy (CRITICAL)
- ✅ **ALWAYS** use `--merge` for merge commits
- ❌ **NEVER** use `--squash` - preserves full audit trail
- ❌ **NEVER** use `--rebase` unless explicitly requested
- 💡 If squashing is desired, do interactive rebase on feature branch BEFORE merging
- 💡 Full commit history = clear audit trail = easier debugging

### Branch Protection
- ❌ **NEVER** push directly to `main`
- ❌ **NEVER** commit directly to `main`
- ✅ **ALWAYS** use feature branches
- ✅ **ALWAYS** create PRs for review

## Infrastructure Management

### Stack
- **IaC Tool**: OpenTofu (Terraform fork)
- **State Backend**: Cloudflare R2 bucket
- **Provider**: Cloudflare (cloudflare/cloudflare)
- **Modules**: None (flat structure in `domains/`)

### Running Terraform

#### Commands (via justfile)
```bash
just domains    # Plan and apply domains/ resources
just bootstrap  # Bootstrap initial Cloudflare resources
```

#### Manual Commands
```bash
cd domains
tofu init
tofu plan
tofu apply
```

### Environment Variables
- Stored in `.env.local` (not `.env`)
- Loaded via direnv (see `.envrc`)
- Required vars: See `.env.local` for complete list

### Key Resources Managed
- `cloudflare_zone.domain` - trakrf.id zone
- `cloudflare_pages_project.www` - Astro site deployment
- `cloudflare_pages_domain.www_custom` - Custom domain attachment
- `cloudflare_record.*` - DNS records (root, www, mail, etc.)
- `cloudflare_email_routing_*` - Email routing rules
- `cloudflare_zone_settings_override.*` - Zone configuration

## Project Structure
```
trakrf-infra/
├── bootstrap/          # Initial Cloudflare setup (R2, tokens)
├── domains/            # Main infrastructure (DNS, Pages, Email)
│   ├── main.tf         # Zone and DNS records
│   ├── pages.tf        # Cloudflare Pages resources
│   ├── provider.tf     # Cloudflare provider config
│   ├── variables.tf    # Input variables
│   └── outputs.tf      # Output values
├── spec/               # CSW specifications and plans
└── .env.local          # Environment variables (gitignored)
```

## Common Tasks

### Adding New Infrastructure
1. Use `/spec` to document the requirement
2. Wait for approval
3. Run `/plan` to generate implementation plan
4. Run `/build` to execute
5. Run `/ship` to create PR

### Updating DNS
- Edit `domains/main.tf`
- Use CSW workflow for changes
- Run `just domains` to apply

### Debugging
- Check Terraform state: `tofu -chdir=domains state list`
- View resource: `tofu -chdir=domains state show <resource>`
- Check R2 state: `just s3-ls`

## Important Notes

### Repository Name
- Renamed from `trakrf/trakrf-infra` to `trakrf/infra`
- Remote URL: `git@github.com:trakrf/infra.git`

### Interactive Terraform
- No GitOps/automation yet
- Manual `just domains` to apply changes
- This is OK for solo operation

### Clickops Avoidance
- **Rule**: If you'll want it tomorrow, Terraform it today
- Dashboard is for exploration only
- All production config goes in Terraform

## Mistakes to Avoid
1. ❌ Creating specs and then coding without `/plan` + `/build`
2. ❌ Using clickops for production configuration
3. ❌ Skipping validation gates
4. ❌ Creating PRs manually when CSW is active
5. ❌ Using `.env` instead of `.env.local`
6. ❌ Pushing directly to main instead of using feature branches
7. ❌ **Using `--squash` or `--rebase` when merging PRs - ALWAYS use `--merge`**

## Contact
Solo developer: @mikestankavich (admin@trakrf.id)
