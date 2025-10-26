# Implementation Plan: Fix DNS Configuration for App and Preview Subdomains
Generated: 2025-10-26
Specification: spec.md

## Understanding

This plan addresses two DNS configuration issues:

1. **Railway App Proxy Misconfiguration**: The `app.trakrf.id` and `app.preview.trakrf.id` DNS records currently have Cloudflare proxy enabled (`proxied = true`). Railway deployments typically require DNS-only mode to properly handle WebSocket connections, Server-Sent Events, client IP detection, and to avoid Cloudflare timeout limits.

2. **Cloudflare Pages Preview Verification**: The `preview.trakrf.id` DNS record points to `preview.www-ch0.pages.dev`, which should work for the preview branch workflow. However, we need to verify that:
   - The `preview` branch exists in the `trakrf/www` repository
   - Cloudflare Pages is configured to deploy the preview branch
   - The branch-based URL is accessible (not just hash-based commit URLs)

**Key Decision from Clarification**: The `preview.trakrf.id` record will remain proxied (orange cloud) to benefit from Cloudflare's CDN and SSL handling. Only the Railway app subdomains need the proxy disabled.

## Relevant Files

**Files to Modify**:
- `domains/main.tf` (lines 26-50) - DNS record configuration for app, app.preview subdomains
  - Line 31: Change `cloudflare_record.app` from `proxied = true` to `proxied = false`
  - Line 49: Change `cloudflare_record.app_preview` from `proxied = true` to `proxied = false`

**Reference Patterns**:
- `domains/main.tf` (line 57) - `cloudflare_record.mail` already uses `proxied = false` pattern
- `domains/pages.tf` (lines 1-34) - Cloudflare Pages project configuration for reference
- `domains/variables.tf` (lines 11-21) - Railway endpoint variables

**Configuration Files**:
- `justfile` (lines 21-27) - Command to apply Terraform changes: `just domains`

## Architecture Impact

**Subsystems affected**:
- DNS configuration (Cloudflare DNS records)
- Cloudflare Pages deployment (verification only)

**New dependencies**: None

**Breaking changes**: None - changes are configuration adjustments with immediate reversion path if needed

## Task Breakdown

### Task 1: Verify Preview Branch Deployment Status
**Action**: INVESTIGATE

**Steps**:
1. Check if `preview` branch exists in `trakrf/www` repository:
   ```bash
   gh repo view trakrf/www --json defaultBranchRef
   gh api repos/trakrf/www/branches/preview 2>/dev/null || echo "Preview branch not found"
   ```

2. Test if branch-based URL is accessible:
   ```bash
   curl -I https://preview.www-ch0.pages.dev/
   ```

3. Check Cloudflare Pages dashboard (manual):
   - Navigate to Cloudflare dashboard → Pages → www project
   - Check if preview branch shows in deployment list
   - Verify `preview_deployment_setting = "all"` in pages.tf is active

**Expected Outcomes**:
- **If preview branch exists and deploys**: Current DNS configuration is correct, no changes needed
- **If preview branch doesn't exist**: User's GitHub Actions workflow may not be running, or branch may be named differently
- **If preview deployment setting is off**: May need to update `pages.tf` configuration

**Validation**:
- Preview branch found in repository OR reason for absence identified
- Branch-based URL accessibility confirmed OR investigation findings documented

### Task 2: Update Railway App DNS Records (Disable Proxy)
**File**: `domains/main.tf`
**Action**: MODIFY

**Changes**:

**Change 1** (line 31):
```hcl
# Before:
resource "cloudflare_record" "app" {
  zone_id = cloudflare_zone.domain.id
  name    = "app"
  content = var.railway_app_prod_endpoint
  type    = "CNAME"
  proxied = true  # ← Change this
}

# After:
resource "cloudflare_record" "app" {
  zone_id = cloudflare_zone.domain.id
  name    = "app"
  content = var.railway_app_prod_endpoint
  type    = "CNAME"
  proxied = false  # ← Changed to DNS-only mode
}
```

**Change 2** (line 49):
```hcl
# Before:
resource "cloudflare_record" "app_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.preview"
  content = var.railway_app_preview_endpoint
  type    = "CNAME"
  proxied = true  # ← Change this
}

# After:
resource "cloudflare_record" "app_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.preview"
  content = var.railway_app_preview_endpoint
  type    = "CNAME"
  proxied = false  # ← Changed to DNS-only mode
}
```

**Pattern Reference**: Similar to `cloudflare_record.mail` at line 52-58, which uses `proxied = false` for direct DNS resolution.

**Validation**:
- File saved successfully
- No syntax errors introduced

### Task 3: Validate Terraform Configuration
**Action**: VALIDATE

**Steps**:
```bash
cd domains
tofu fmt
tofu validate
```

**Expected Output**:
- `tofu fmt`: No formatting errors or formatting applied automatically
- `tofu validate`: "Success! The configuration is valid."

**Validation**:
- Terraform configuration passes validation
- No syntax or structural errors

### Task 4: Review Terraform Plan
**Action**: PLAN

**Steps**:
```bash
just domains
# This runs:
# - tofu -chdir=domains init
# - tofu -chdir=domains plan -out=tfplan
# - tofu -chdir=domains apply tfplan
```

**Or run plan separately first**:
```bash
tofu -chdir=domains init
tofu -chdir=domains plan
```

**Expected Plan Output**:
```
Terraform will perform the following actions:

  # cloudflare_record.app will be updated in-place
  ~ resource "cloudflare_record" "app" {
      ~ proxied = true -> false
        # (other attributes unchanged)
    }

  # cloudflare_record.app_preview will be updated in-place
  ~ resource "cloudflare_record" "app_preview" {
      ~ proxied = true -> false
        # (other attributes unchanged)
    }

Plan: 0 to add, 2 to change, 0 to destroy.
```

**Validation**:
- Plan shows ONLY the `proxied` field changing for `app` and `app_preview` records
- No unexpected changes (zone, name, content, type should remain unchanged)
- Plan shows 2 resources to update, 0 to add, 0 to destroy

**⚠️ GATE**: If plan shows unexpected changes, STOP and investigate before applying.

### Task 5: Apply Terraform Changes
**Action**: APPLY

**Steps**:
```bash
just domains
# Or if already planned:
tofu -chdir=domains apply tfplan
```

**Expected Output**:
```
cloudflare_record.app: Modifying...
cloudflare_record.app_preview: Modifying...
cloudflare_record.app: Modifications complete
cloudflare_record.app_preview: Modifications complete

Apply complete! Resources: 0 added, 2 changed, 0 destroyed.
```

**Validation**:
- Apply completes without errors
- Both DNS records updated successfully
- No rollback or error messages

### Task 6: Verify DNS Resolution
**Action**: VERIFY

**Steps**:
```bash
# Wait 30-60 seconds for DNS propagation
sleep 60

# Check DNS records resolve correctly
dig app.trakrf.id CNAME +short
# Expected: hlvn5pcb.up.railway.app (from variables.tf)

dig app.preview.trakrf.id CNAME +short
# Expected: f67wu1p6.up.railway.app (from variables.tf)

# Verify DNS-only mode (no Cloudflare IPs)
dig app.trakrf.id A +short
# Should resolve to Railway's IP, not Cloudflare proxy IPs (104.x.x.x)
```

**Alternative (if dig not available)**:
```bash
nslookup app.trakrf.id
nslookup app.preview.trakrf.id
```

**Validation**:
- DNS records resolve to correct Railway endpoints
- No Cloudflare proxy IPs in resolution chain
- DNS propagation complete

### Task 7: Verify HTTP Accessibility
**Action**: VERIFY

**Steps**:
```bash
# Test app.trakrf.id (production)
curl -I https://app.trakrf.id/
# Expected: HTTP 200 or appropriate response from Railway app

# Test app.preview.trakrf.id
curl -I https://app.preview.trakrf.id/
# Expected: HTTP 200 or appropriate response from Railway app

# Alternative: Test with full response
curl -v https://app.trakrf.id/ 2>&1 | grep -E '(HTTP|Server|Host)'
```

**Expected Outcomes**:
- Both URLs return valid HTTP responses
- No 522 (connection timeout) errors
- No 503 (service unavailable) errors
- Railway application responds correctly

**If failures occur**:
- Check Railway deployment status
- Verify Railway endpoints in variables.tf are correct
- Consider temporarily reverting to `proxied = true` if Railway requires it

**Validation**:
- `app.trakrf.id` is accessible via HTTPS
- `app.preview.trakrf.id` is accessible via HTTPS
- Applications respond correctly

### Task 8: Verify Cloudflare Dashboard Shows DNS-Only Mode
**Action**: VERIFY (Manual)

**Steps**:
1. Log into Cloudflare Dashboard
2. Navigate to the `trakrf.id` zone → DNS → Records
3. Locate `app` and `app.preview` CNAME records
4. Verify both show **grey cloud** (DNS only) icon, not orange cloud (proxied)

**Expected State**:
- `app` record: Grey cloud, CNAME to `hlvn5pcb.up.railway.app`
- `app.preview` record: Grey cloud, CNAME to `f67wu1p6.up.railway.app`
- `preview` record: **Orange cloud** (still proxied), CNAME to `preview.www-ch0.pages.dev`

**Validation**:
- Dashboard confirms DNS-only mode for Railway app subdomains
- Preview subdomain remains proxied as intended

### Task 9: Document Preview Branch Investigation Findings
**Action**: DOCUMENT

**Steps**:
1. Summarize findings from Task 1 (preview branch verification)
2. If preview branch/deployment issues found, document:
   - What's not working (branch missing, deployment disabled, etc.)
   - Suggested configuration changes for `domains/pages.tf`
   - Next steps for user (check GitHub Actions workflow, etc.)

**Validation**:
- Investigation findings clearly documented
- Any required follow-up actions identified

## Risk Assessment

### Risk 1: DNS Propagation Delays
**Description**: DNS changes may take 30-300 seconds to fully propagate globally.

**Mitigation**:
- Wait 60 seconds after applying changes before verification
- Use Cloudflare's fast propagation (typically < 5 minutes)
- Changes are in Cloudflare-managed zone, so propagation is fast

**Likelihood**: Low
**Impact**: Low (temporary only)

### Risk 2: Railway Application Incompatibility
**Description**: Railway apps might unexpectedly require Cloudflare proxy (unlikely but possible).

**Mitigation**:
- Railway typically recommends DNS-only mode
- Changes are easily reversible via Terraform
- Can revert by changing `proxied = false` back to `true` and re-running `just domains`

**Likelihood**: Very Low
**Impact**: Medium (requires quick revert)

**Revert Steps** (if needed):
```bash
# Edit domains/main.tf - change proxied back to true
tofu -chdir=domains plan
tofu -chdir=domains apply
```

### Risk 3: Preview Branch Not Deployed
**Description**: The `preview` branch may not exist or may not be deployed by Cloudflare Pages.

**Mitigation**:
- This is investigation/verification only, not a blocking issue for Railway changes
- DNS configuration for `preview.trakrf.id` is likely correct
- Root cause would be GitHub Actions workflow or Pages configuration, not DNS
- Can address in follow-up changes if needed

**Likelihood**: Medium (unknown until verified)
**Impact**: Low (doesn't affect Railway app changes)

## Integration Points

**Cloudflare DNS**:
- Changes to two CNAME records (`app`, `app.preview`)
- No changes to zone settings or other records

**Railway Applications**:
- No Railway configuration changes required
- Applications should benefit from direct IP access

**Cloudflare Pages**:
- Investigation only, no configuration changes planned
- May identify issues requiring follow-up work

## VALIDATION GATES (MANDATORY)

This infrastructure project has simpler validation gates than code projects:

### Gate 1: Terraform Syntax & Format
**Command**: `tofu fmt && tofu validate`
**Location**: `domains/` directory
**Pass Criteria**: No formatting errors, validation succeeds

### Gate 2: Terraform Plan Review
**Command**: `tofu -chdir=domains plan`
**Pass Criteria**:
- Only `proxied` field changes on `app` and `app_preview` records
- No unexpected resource changes
- Plan shows "2 to change, 0 to add, 0 to destroy"

### Gate 3: Terraform Apply Success
**Command**: `just domains` or `tofu -chdir=domains apply`
**Pass Criteria**: Apply completes without errors

### Gate 4: DNS Resolution
**Command**: `dig app.trakrf.id CNAME +short`
**Pass Criteria**: Resolves to correct Railway endpoint

### Gate 5: HTTP Accessibility
**Command**: `curl -I https://app.trakrf.id/`
**Pass Criteria**: Returns valid HTTP response (not 522/503)

**Enforcement Rules**:
- If any gate fails → Fix immediately or document issue
- Re-run validation after fix
- Do not proceed to next task until current task passes
- If Gate 5 fails with Railway deployment issues (not DNS), can document and proceed

## Validation Sequence

**After Task 2 (Edit main.tf)**:
- Run Gate 1: Terraform Syntax & Format

**After Task 3 (Validate Terraform)**:
- Already covered by task execution

**After Task 4 (Review Plan)**:
- Run Gate 2: Terraform Plan Review (human review)

**After Task 5 (Apply Changes)**:
- Run Gate 3: Terraform Apply Success

**After Task 6 (Verify DNS)**:
- Run Gate 4: DNS Resolution

**After Task 7 (Verify HTTP)**:
- Run Gate 5: HTTP Accessibility

**Final Validation**:
- All Railway apps accessible
- Cloudflare dashboard confirms grey cloud (DNS-only) mode
- Investigation findings documented

## Plan Quality Assessment

**Complexity Score**: 1/10 (LOW)
- Simple boolean flag changes in Terraform
- Single file modification
- Well-understood infrastructure change
- Easy rollback path

**Confidence Score**: 9/10 (HIGH)

**Confidence Factors**:
- ✅ Clear requirements from spec and user clarification
- ✅ Similar pattern exists in codebase (`cloudflare_record.mail` uses `proxied = false`)
- ✅ All clarifying questions answered
- ✅ Terraform/OpenTofu is well-established tool
- ✅ Railway documentation supports DNS-only mode
- ✅ Easy revert path if issues arise
- ⚠️ Preview branch verification is investigative - outcome uncertain

**Assessment**: High-confidence implementation. The Railway DNS proxy change is straightforward with low risk. The preview branch verification is exploratory and may reveal issues requiring follow-up work, but this doesn't block the main objective.

**Estimated one-pass success probability**: 95%

**Reasoning**:
- Terraform changes are simple and well-validated
- Railway typically works better with DNS-only mode
- DNS propagation is fast with Cloudflare
- Only uncertainty is preview branch status, which is investigation-only
- 5% risk accounts for unexpected Railway configuration requirements or DNS edge cases

## Additional Notes

### Railway DNS Best Practices
Railway deployments typically perform better with DNS-only mode because:
- Direct connection to Railway infrastructure
- No Cloudflare timeout limits (100s default)
- Accurate client IP detection for rate limiting/analytics
- Better WebSocket and SSE performance
- Railway handles its own SSL/TLS termination

### Cloudflare Pages Preview Workflow
The user's GitHub Actions workflow merges all in-flight PRs to a `preview` branch. For this to work:
- `preview` branch must exist in `trakrf/www` repository
- Cloudflare Pages must have `preview_deployment_setting = "all"` (already configured in `pages.tf`)
- Branch-based URL format is `<branch-name>.<project-name>.pages.dev`
- Hash-based URLs (like `f9b0b7e9.www-ch0.pages.dev`) are commit-specific and not stable

If the preview branch doesn't exist or isn't deploying, that's a GitHub Actions or Pages build issue, not a DNS problem. The current DNS configuration (`preview.trakrf.id` → `preview.www-ch0.pages.dev`) is correct for the intended workflow.
