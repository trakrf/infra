# Implementation Plan: JCI-OMH Email Alias
Generated: 2025-11-18
Specification: spec.md

## Understanding

Add a new email alias `jci-omh@trakrf.id` that forwards to **two destinations**:
1. `miks2u+trakrf@gmail.com` (administrative oversight)
2. `stephen.maliszewski@jci.com` (JCI stakeholder)

This is the first multi-destination alias in the infrastructure, breaking from the existing single-destination pattern used by the other five aliases (abuse, admin, info, sales, support). The implementation will add two new Cloudflare resources without modifying the existing `for_each` loop pattern.

## Relevant Files

**Reference Patterns** (existing code to follow):
- `domains/main.tf` (lines 104-107) - `cloudflare_email_routing_address` resource pattern
- `domains/main.tf` (lines 110-127) - `cloudflare_email_routing_rule` resource pattern
- `domains/main.tf` (line 93) - `local.catchall_email` variable reference

**Files to Modify**:
- `domains/main.tf` (append after line 146) - Add two new resources with explanatory comment

## Architecture Impact

- **Subsystems affected**: Cloudflare Email Routing
- **New dependencies**: None (using existing Cloudflare provider)
- **Breaking changes**: None (additive only)

## Task Breakdown

### Task 1: Add Customer-Specific Email Routing Comment
**File**: `domains/main.tf`
**Action**: MODIFY
**Location**: After line 146 (end of file)

**Implementation**:
```hcl
# Customer-specific email routing setup
# JCI-OMH: Multi-destination alias (differs from single-destination pattern above)
```

**Validation**:
- File syntax is valid HCL
- Comment clearly explains why this section is separate

### Task 2: Add Verified Destination Address
**File**: `domains/main.tf`
**Action**: MODIFY
**Pattern**: Reference `domains/main.tf` lines 104-107

**Implementation**:
```hcl
resource "cloudflare_email_routing_address" "jci_stephen" {
  account_id = var.account_id
  email      = "stephen.maliszewski@jci.com"
}
```

**Key Points**:
- Resource name: `jci_stephen` (follows existing underscore convention)
- Uses `var.account_id` (same as existing pattern at line 105)
- Email is hardcoded string (same as existing pattern at line 106)

**Validation**:
- Run `tofu -chdir=domains init` (ensure provider is initialized)
- Run `tofu -chdir=domains plan -out=tfplan` (should show 1 resource to add)
- Verify plan output shows email address resource creation

### Task 3: Add Multi-Destination Routing Rule
**File**: `domains/main.tf`
**Action**: MODIFY
**Pattern**: Reference `domains/main.tf` lines 110-127

**Implementation**:
```hcl
resource "cloudflare_email_routing_rule" "jci_omh" {
  zone_id = cloudflare_zone.domain.id
  name    = "Email Rule for jci-omh"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "jci-omh@${var.domain_name}"
  }

  action {
    type  = "forward"
    value = [
      local.catchall_email,
      cloudflare_email_routing_address.jci_stephen.email
    ]
  }
}
```

**Key Points**:
- Resource name: `jci_omh` (follows existing convention)
- Uses same `zone_id`, `name` pattern, `enabled` as lines 113-115
- Matcher block identical to existing pattern (lines 117-121)
- Action block uses array with TWO destinations (lines 123-126)
- References `local.catchall_email` (defined at line 93)
- References `cloudflare_email_routing_address.jci_stephen.email` (creates implicit dependency)

**Validation**:
- Run `tofu -chdir=domains plan -out=tfplan` (should show 2 resources to add)
- Verify plan output shows:
  - `cloudflare_email_routing_address.jci_stephen` will be created
  - `cloudflare_email_routing_rule.jci_omh` will be created
- Verify rule shows both destination emails in the plan output

### Task 4: Apply Infrastructure Changes
**File**: N/A (execution task)
**Action**: APPLY

**Implementation**:
```bash
tofu -chdir=domains apply tfplan
```

**Expected Output**:
- Cloudflare sends verification email to `stephen.maliszewski@jci.com`
- Two resources created successfully
- No changes to existing resources

**Validation**:
- Apply completes without errors
- Output shows: `Apply complete! Resources: 2 added, 0 changed, 0 destroyed.`

### Task 5: Verify Email Routing Configuration
**File**: N/A (manual verification)
**Action**: VERIFY

**Verification Steps**:
1. Check Cloudflare dashboard: Email Routing → Destination Addresses
   - Verify `stephen.maliszewski@jci.com` appears (may show "Pending Verification")
2. Inform user that Stephen needs to verify email via Cloudflare verification link
3. After verification, check Email Routing → Routing Rules
   - Verify `jci-omh@trakrf.id` rule exists and is enabled
   - Verify rule shows both destinations

**Post-Verification Test** (optional, after Stephen verifies):
- Send test email to `jci-omh@trakrf.id`
- Confirm both `miks2u+trakrf@gmail.com` and `stephen.maliszewski@jci.com` receive it

## Risk Assessment

- **Risk**: Stephen's email may not verify immediately
  **Mitigation**: Email routing rule is created but won't work until verification completes. User can check verification status in Cloudflare dashboard.

- **Risk**: Terraform state drift if someone modifies email routing in Cloudflare dashboard
  **Mitigation**: Follow project philosophy "If you'll want it tomorrow, Terraform it today" - avoid clickops.

- **Risk**: Typo in email address
  **Mitigation**: Email address is clearly specified in spec (`stephen.maliszewski@jci.com`) - double-check during code review.

## Integration Points

- **Email Routing**: Adds to existing Cloudflare Email Routing configuration (lines 86-127)
- **Variables**: Uses existing `var.account_id`, `var.domain_name`, `local.catchall_email`
- **Zone Reference**: Uses existing `cloudflare_zone.domain.id`

## VALIDATION GATES (MANDATORY)

**Infrastructure Validation Commands**:

After each Terraform change:
1. **Syntax & Plan Check**: `tofu -chdir=domains plan -out=tfplan`
   - Verify plan shows expected changes only
   - Verify no unintended resource modifications
   - Verify resource count matches expectations

2. **Apply Changes**: `tofu -chdir=domains apply tfplan`
   - Verify apply completes successfully
   - Verify output shows correct resource count

**Enforcement Rules**:
- If plan shows unexpected changes → Review code before proceeding
- If apply fails → Check Cloudflare API credentials and quota
- After verification failure → Inform user to check email and Cloudflare dashboard

**Gate Sequence**:
1. Task 1-2 complete → Run `tofu plan` (expect 1 resource to add)
2. Task 3 complete → Run `tofu plan` (expect 2 resources to add)
3. Task 4 complete → Run `tofu apply` (expect successful creation)
4. Task 5 complete → Manual verification in Cloudflare dashboard

## Validation Sequence

1. **After adding verified address resource**:
   ```bash
   tofu -chdir=domains plan -out=tfplan
   ```
   Expected: 1 resource to add

2. **After adding routing rule resource**:
   ```bash
   tofu -chdir=domains plan -out=tfplan
   ```
   Expected: 2 resources to add

3. **Final application**:
   ```bash
   tofu -chdir=domains apply tfplan
   ```
   Expected: Resources: 2 added, 0 changed, 0 destroyed

4. **Manual verification**:
   - Cloudflare dashboard check
   - Email verification status
   - Test email after verification (optional)

## Plan Quality Assessment

**Complexity Score**: 1/10 (LOW)

**Confidence Score**: 9/10 (HIGH)

**Confidence Factors**:
✅ Clear requirements from spec
✅ Existing patterns found at `domains/main.tf:104-107` and `domains/main.tf:110-127`
✅ All clarifying questions answered (placement, comments, dependencies)
✅ Simple additive change (no modifications to existing resources)
✅ Well-established Cloudflare provider with stable API
✅ Validation strategy is straightforward (tofu plan/apply)

⚠️ Minor uncertainty: Timing of email verification (user-dependent, not code-dependent)

**Assessment**: High-confidence implementation. Pattern is well-established, change is additive-only, and validation is straightforward. The only external dependency is Stephen verifying his email address via Cloudflare's verification process.

**Estimated one-pass success probability**: 95%

**Reasoning**: Extremely straightforward infrastructure change following existing patterns. The 5% risk comes from potential typos or misconfiguration, not from architectural complexity. Terraform's plan preview will catch most issues before apply.
