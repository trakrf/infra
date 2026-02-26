# Implementation Plan: Cloudflare DNS + Hosting Infra for docs.trakrf.id
Generated: 2026-02-25
Specification: spec.md

## Understanding
Mirror the existing `www` Cloudflare Pages setup for a new `docs` site. Create a Pages project connected to `trakrf/docs` GitHub repo (Docusaurus, output dir `build`), attach `docs.trakrf.id` as a custom domain, and add the corresponding DNS CNAME record. Preview deployments enabled via default Pages URLs but no custom preview subdomain.

## Relevant Files

**Reference Patterns** (existing code to follow):
- `domains/pages.tf` (lines 1-34) - `cloudflare_pages_project.www` resource structure to mirror
- `domains/pages.tf` (lines 37-41) - `cloudflare_pages_domain.www_custom` pattern for custom domain attachment
- `domains/main.tf` (lines 9-15) - `cloudflare_record.root` CNAME pattern pointing to Pages subdomain
- `domains/pages.tf` (lines 51-54) - `pages_url` output pattern

**Files to Create**: None

**Files to Modify**:
- `domains/pages.tf` - Add `cloudflare_pages_project.docs`, `cloudflare_pages_domain.docs_custom`, and `docs_pages_url` output
- `domains/main.tf` - Add `cloudflare_record.docs` CNAME

## Architecture Impact
- **Subsystems affected**: Cloudflare Pages, DNS
- **New dependencies**: None
- **Breaking changes**: None — purely additive

## Task Breakdown

### Task 1: Add Cloudflare Pages project for docs
**File**: `domains/pages.tf`
**Action**: MODIFY (append)
**Pattern**: Mirror `cloudflare_pages_project.www` (lines 1-34)

**Implementation**:
```hcl
resource "cloudflare_pages_project" "docs" {
  account_id        = var.account_id
  name              = "docs"
  production_branch = "main"

  build_config {
    build_command   = "pnpm build"
    destination_dir = "build"        # Docusaurus default (not "dist")
    root_dir        = ""
  }

  source {
    type = "github"
    config {
      owner                         = "trakrf"
      repo_name                     = "docs"
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
```

**Validation**: `tofu -chdir=domains validate`

### Task 2: Add custom domain attachment for docs
**File**: `domains/pages.tf`
**Action**: MODIFY (append)
**Pattern**: Mirror `cloudflare_pages_domain.www_custom` (lines 37-41)

**Implementation**:
```hcl
resource "cloudflare_pages_domain" "docs_custom" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.docs.name
  domain       = "docs.${var.domain_name}"
}
```

**Validation**: `tofu -chdir=domains validate`

### Task 3: Add docs Pages URL output
**File**: `domains/pages.tf`
**Action**: MODIFY (append)
**Pattern**: Mirror `pages_url` output (lines 51-54)

**Implementation**:
```hcl
output "docs_pages_url" {
  value       = cloudflare_pages_project.docs.subdomain
  description = "Cloudflare Pages URL for the docs project"
}
```

**Validation**: `tofu -chdir=domains validate`

### Task 4: Add DNS CNAME record for docs subdomain
**File**: `domains/main.tf`
**Action**: MODIFY (insert after existing DNS records, before email section)
**Pattern**: Mirror `cloudflare_record.root` (lines 9-15), pointing to docs Pages subdomain

**Implementation**:
```hcl
resource "cloudflare_record" "docs" {
  zone_id = cloudflare_zone.domain.id
  name    = "docs"
  content = cloudflare_pages_project.docs.subdomain
  type    = "CNAME"
  proxied = true
}
```

**Validation**: `tofu -chdir=domains validate`

## Risk Assessment
- **Risk**: Cloudflare Pages GitHub app not authorized for `trakrf/docs` repo
  **Mitigation**: Verify in Cloudflare dashboard that the GitHub integration has access to the `docs` repo. If not, authorize it before `tofu apply`.

- **Risk**: Build command or output dir mismatch
  **Mitigation**: Confirmed `pnpm build` with `build` output dir (Docusaurus default). If first deploy fails, check `trakrf/docs` package.json for actual build script.

## VALIDATION GATES (MANDATORY)

After all tasks complete:
1. `tofu -chdir=domains fmt -check` — formatting
2. `tofu -chdir=domains validate` — syntax and config validity
3. `tofu -chdir=domains plan` — verify only expected resources appear:
   - `cloudflare_pages_project.docs` (create)
   - `cloudflare_pages_domain.docs_custom` (create)
   - `cloudflare_record.docs` (create)
   - No unexpected changes to existing resources

## Validation Sequence
After each task: `tofu -chdir=domains validate`

Final validation: `tofu -chdir=domains plan` (dry run showing 3 new resources, 0 changes)

Post-apply (manual):
- `tofu -chdir=domains apply`
- Verify `docs.trakrf.id` resolves via DNS
- Verify HTTPS loads with valid certificate
- Push to `trakrf/docs` main triggers deployment

## Plan Quality Assessment

**Complexity Score**: 1/10 (LOW)
**Confidence Score**: 10/10 (HIGH)

**Confidence Factors**:
✅ Clear requirements from spec — exact resources and file locations specified
✅ Direct pattern match found in codebase (`www` Pages project is identical structure)
✅ All clarifying questions answered (build dir = `build`, previews = enabled)
✅ Purely additive changes — zero risk to existing infrastructure
✅ Only 2 files modified, 0 files created

**Assessment**: This is a straightforward copy-and-adapt of an existing, proven pattern with zero ambiguity.

**Estimated one-pass success probability**: 98%

**Reasoning**: Every resource has an exact template in the codebase. The only uncertainty is external (GitHub app authorization), which is outside Terraform's control.
