# Feature: Terraform Cloudflare Pages Deployment

## Origin
This specification emerged from attempting to deploy the trakrf.id Astro website via Cloudflare Pages. Initial approach used dashboard clickops which proved "tweaky and not repeatable" - hitting token permission issues, deploy command confusion, and 404 errors. User requested infrastructure-as-code approach instead.

## Outcome
Cloudflare Pages project for `trakrf/www` Astro site is fully managed via Terraform, enabling repeatable GitOps deployments with custom domain configuration.

## User Story
As an infrastructure engineer
I want the Cloudflare Pages deployment managed in Terraform
So that it's repeatable, version-controlled, and doesn't require error-prone clickops

## Context
**Discovery**:
- Clickops approach required multiple iterations to get token permissions right
- Deploy command was confusing (GitHub integration doesn't need wrangler deploy)
- Custom domain wasn't properly configured, resulting in 522/404 errors
- Manual configuration is not documented or repeatable

**Current**:
- Astro site in `trakrf/www` repo on GitHub
- DNS for trakrf.id managed in Terraform (`domains/main.tf`)
- Pages project exists in dashboard but incomplete/broken configuration

**Desired**:
- `cloudflare_pages_project` resource managing build settings
- `cloudflare_pages_domain` resource attaching trakrf.id custom domain
- DNS CNAME already points to Pages (updated in domains/main.tf)
- Clean, documented, repeatable infrastructure

## Technical Requirements

### Cloudflare Pages Project
- **Name**: `www` (matches existing project)
- **Production branch**: `main`
- **Build configuration**:
  - Framework preset: `astro` (auto-detected)
  - Build command: `pnpm build`
  - Build output directory: `dist`
  - Node version: 22.21.0 (from .nvmrc in repo)
  - Package manager: `pnpm@9.15.0` (from package.json)
- **Source**: GitHub repo `trakrf/www`
- **Deploy method**: GitOps (auto-deploy on push to main)

### Custom Domain
- **Domain**: `trakrf.id` (apex domain)
- **Subdomain**: `www.trakrf.id` (via existing DNS CNAME)
- **SSL**: Managed by Cloudflare (automatic)

### DNS Configuration
- Already updated in `domains/main.tf`:
  - Root CNAME: `@ → www.miks2u-trakrf.workers.dev` (or update to .pages.dev URL)
  - WWW CNAME: `www → trakrf.id`

### Preview Deployments
- Automatic for all non-main branches
- URL pattern: `<branch>.www.pages.dev`

## Implementation Approach

**Option 1: Full Terraform** (RECOMMENDED)
1. Destroy existing dashboard-created project (if needed)
2. Create `cloudflare_pages_project` resource
3. GitHub OAuth connection: One-time manual step (click "Connect to Git" after terraform creates project)
4. Add `cloudflare_pages_domain` for custom domain
5. Update DNS CNAME to correct `.pages.dev` URL

**Option 2: Import Existing**
1. Import dashboard project: `tofu import cloudflare_pages_project.www <account_id>/www`
2. Write Terraform to match existing state
3. Add `cloudflare_pages_domain` resource
4. Manage via Terraform going forward

## Code Examples

### Terraform Resource Structure
```hcl
resource "cloudflare_pages_project" "www" {
  account_id        = var.account_id
  name              = "www"
  production_branch = "main"

  build_config {
    build_command       = "pnpm build"
    destination_dir     = "dist"
    root_dir            = ""
  }

  source {
    type = "github"
    config {
      owner                         = "trakrf"
      repo_name                     = "www"
      production_branch             = "main"
      pr_comments_enabled           = true
      deployments_enabled           = true
      production_deployment_enabled = true
      preview_deployment_setting    = "all"
    }
  }

  deployment_configs {
    preview {
      environment_variables = {}
    }
    production {
      environment_variables = {}
    }
  }
}

resource "cloudflare_pages_domain" "www_custom" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.www.name
  domain       = var.domain_name  # trakrf.id
}
```

### Updated DNS (if needed)
```hcl
resource "cloudflare_record" "root" {
  zone_id = cloudflare_zone.domain.id
  name    = "@"
  content = "${cloudflare_pages_project.www.subdomain}.pages.dev"
  type    = "CNAME"
  proxied = true
}
```

## Validation Criteria
- [ ] `tofu plan` shows Pages project creation
- [ ] `tofu apply` successfully creates project
- [ ] GitHub OAuth connection completed (one-time manual step)
- [ ] Build triggers on push to main branch
- [ ] Astro build completes successfully (typecheck + build)
- [ ] Site accessible at `www.pages.dev`
- [ ] Custom domain attached via `cloudflare_pages_domain`
- [ ] `trakrf.id` resolves and loads the Astro site (not 522/404)
- [ ] Preview deployments work for non-main branches

## Conversation References
- **Key insight**: "i am not liking this clickops it seems tweaky and not repeatable can we just terraform it?"
- **Decision**: Option 1 (Full Terraform) recommended - clean slate approach
- **Constraint**: GitHub OAuth is one-time manual step (unavoidable with any approach)
- **Build details**: From successful dashboard deploy logs - `pnpm build` → `astro check && astro build` → generates `dist/`

## Known Issues from Clickops Attempt
1. **Token permissions**: Needed `Cloudflare Pages > Edit` permission (fixed)
2. **Deploy command**: GitHub integration doesn't need `npx wrangler pages deploy` (used no-op `true` instead)
3. **Custom domain**: Not properly attached, causing 522 errors
4. **Workers.dev vs Pages.dev**: URL was `www.miks2u-trakrf.workers.dev` but should be `.pages.dev`

## Out of Scope
- R2 bucket approach (Pages is correct solution for static sites)
- Multiple environments beyond preview/production (current setup sufficient)
- Advanced Pages features (Functions, KV, etc.) - static site only for now
