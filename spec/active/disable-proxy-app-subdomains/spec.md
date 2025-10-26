# Feature: Fix DNS Configuration for App and Preview Subdomains

## Origin
This specification addresses two DNS configuration issues:
1. Railway application deployments require Cloudflare proxy to be disabled
2. Cloudflare Pages preview subdomain needs verification for correct branch targeting

## Outcome
1. DNS records for `app.trakrf.id` and `app.preview.trakrf.id` will be configured with DNS-only mode (grey cloud) instead of proxied mode (orange cloud)
2. DNS record for `preview.trakrf.id` will be verified to correctly point to the preview branch deployment

## User Stories

### Story 1: Railway App Deployments
As a developer deploying Railway applications
I want direct DNS resolution without Cloudflare proxy
So that Railway can properly handle requests and connections without proxy interference

### Story 2: Cloudflare Pages Preview
As a developer using a preview branch workflow
I want `preview.trakrf.id` to always point to the latest preview branch deployment
So that stakeholders can view all in-flight features at a stable URL

## Context

### Issue 1: Railway App Proxy Configuration

**Discovery**: The app and app.preview subdomains are currently configured with Cloudflare proxy enabled, which may interfere with Railway's expected behavior.

**Current State**:
- `app.trakrf.id` → CNAME to Railway production endpoint (proxied: true)
- `app.preview.trakrf.id` → CNAME to Railway preview endpoint (proxied: true)

**Desired State**:
- `app.trakrf.id` → CNAME to Railway production endpoint (proxied: false)
- `app.preview.trakrf.id` → CNAME to Railway preview endpoint (proxied: false)

**Why Disable Proxy?**
Railway deployments often require direct DNS access for:
- WebSocket connections
- Server-Sent Events (SSE)
- Correct client IP detection
- Avoiding Cloudflare's timeout limits
- Railway's own SSL/TLS handling

### Issue 2: Cloudflare Pages Preview DNS

**Discovery**: Preview deployments are accessible at hash-based URLs (e.g., `f9b0b7e9.www-ch0.pages.dev`) which change with each commit, but the CNAME points to `preview.www-ch0.pages.dev`.

**Current State**:
- `preview.trakrf.id` → CNAME to `preview.www-ch0.pages.dev` (proxied: true)
- Current config _should_ work if `preview` branch exists
- Hash-based URLs (`f9b0b7e9.www-ch0.pages.dev`) are commit-specific, not stable

**Workflow Context**:
- GitHub Actions workflow merges all in-flight PR feature branches to `preview` branch
- `preview` branch should trigger Cloudflare Pages deployment
- Branch-based URL (`preview.www-ch0.pages.dev`) should point to latest preview branch deployment

**Verification Needed**:
- Confirm `preview` branch exists and is being deployed by Cloudflare Pages
- Confirm `preview.www-ch0.pages.dev` resolves correctly
- Current CNAME configuration is likely correct, just needs verification

## Technical Requirements

### Railway App Changes (Required)
1. Modify `domains/main.tf`
2. Update `cloudflare_record.app` resource:
   - Change `proxied = true` to `proxied = false` (line 31)
3. Update `cloudflare_record.app_preview` resource:
   - Change `proxied = true` to `proxied = false` (line 49)

### Cloudflare Pages Preview Verification (Investigation + Potential Fix)
1. Verify `preview` branch exists in `trakrf/www` repository
2. Verify Cloudflare Pages is building the `preview` branch
3. Test that `preview.www-ch0.pages.dev` resolves and shows preview content
4. If verification passes:
   - ✅ No changes needed - current CNAME is correct
5. If verification fails:
   - Investigate why `preview` branch isn't being deployed
   - May need to update Cloudflare Pages configuration
   - May need to ensure GitHub Actions workflow is working correctly

### Files Affected
- `domains/main.tf` - DNS record configuration (app/app.preview changes)
- `domains/pages.tf` - Potentially (if Pages config needs updates)

## Code Changes

**File**: `domains/main.tf`

**Before (lines 26-32)**:
```hcl
resource "cloudflare_record" "app" {
  zone_id = cloudflare_zone.domain.id
  name    = "app"
  content = var.railway_app_prod_endpoint
  type    = "CNAME"
  proxied = true  # ← Change this
}
```

**After**:
```hcl
resource "cloudflare_record" "app" {
  zone_id = cloudflare_zone.domain.id
  name    = "app"
  content = var.railway_app_prod_endpoint
  type    = "CNAME"
  proxied = false  # ← Changed
}
```

**Before (lines 44-50)**:
```hcl
resource "cloudflare_record" "app_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.preview"
  content = var.railway_app_preview_endpoint
  type    = "CNAME"
  proxied = true  # ← Change this
}
```

**After**:
```hcl
resource "cloudflare_record" "app_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.preview"
  content = var.railway_app_preview_endpoint
  type    = "CNAME"
  proxied = false  # ← Changed
}
```

## Validation Criteria

### Railway App DNS (app/app.preview)
- [ ] DNS records still resolve correctly to Railway endpoints
- [ ] Cloudflare dashboard shows "DNS only" (grey cloud) for `app` and `app.preview` records
- [ ] Railway applications remain accessible at both URLs
- [ ] Terraform plan shows only the proxied field changing for these records
- [ ] Terraform apply completes without errors

### Cloudflare Pages Preview DNS
- [ ] `preview` branch exists in `trakrf/www` repo
- [ ] Cloudflare Pages dashboard shows preview branch deployments
- [ ] `preview.www-ch0.pages.dev` resolves and loads the preview site
- [ ] `preview.trakrf.id` resolves to the preview deployment
- [ ] Preview site shows combined features from all in-flight PRs
- [ ] DNS record configuration is verified correct (or updated if needed)

## Deployment Process
Following the project's git workflow:
1. Create feature branch: `git checkout -b fix/dns-app-preview-config`
2. Investigate Cloudflare Pages preview deployment status
3. Make necessary Terraform changes (app/app.preview proxy disable + any Pages fixes)
4. Run `just domains` to validate and apply
5. Verify both Railway apps and Pages preview are accessible
6. Commit changes
7. Push branch and create PR
8. Merge with `--merge` strategy

## Risk Assessment
**Risk Level**: Low

**Potential Issues**:
- Brief DNS propagation delay (typically <5 minutes) for Railway app changes
- Temporary disruption if Railway expects proxy to be enabled (unlikely)
- Preview deployment may not be working as expected (investigation needed)

**Mitigation**:
- Changes are reversible by setting `proxied = true` again
- Monitor application accessibility after deployment
- No data loss risk - only DNS configuration changes
- Preview DNS is already configured correctly, just needs verification
- If preview isn't working, root cause is likely in GitHub Actions or Pages config, not DNS

## Notes
- This is a configuration fix/verification, not a new feature
- No breaking changes to application code
- Railway changes align with Railway's recommended DNS setup
- Pages preview DNS is likely already correct, just needs confirmation
- If preview branch deploys aren't working, that's a separate GitHub Actions/Pages build issue
