# Implementation Plan: peter@ Email Alias
Generated: 2026-02-15
Specification: spec.md

## Understanding
Add `peter@trakrf.id` → `peter.stankavich@gmail.com` email routing by appending two Cloudflare resources to `domains/main.tf`, copying the exact pattern used for the nick@ alias.

## Relevant Files

**Reference Pattern** (existing code to copy):
- `domains/main.tf` (lines 207–228) — nick@ alias: `cloudflare_email_routing_address` + `cloudflare_email_routing_rule`

**Files to Modify**:
- `domains/main.tf` (append after line 228) — add peter routing address + rule

## Task Breakdown

### Task 1: Add peter email routing resources
**File**: `domains/main.tf`
**Action**: MODIFY (append after line 228)

**Implementation**:
```hcl
# Peter alias - external destination
resource "cloudflare_email_routing_address" "peter" {
  account_id = var.account_id
  email      = "peter.stankavich@gmail.com"
}

resource "cloudflare_email_routing_rule" "peter" {
  zone_id = cloudflare_zone.domain.id
  name    = "Email Rule for peter"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "peter@${var.domain_name}"
  }

  action {
    type  = "forward"
    value = [cloudflare_email_routing_address.peter.email]
  }
}
```

### Task 2: Validate with tofu plan
Run `tofu -chdir=domains plan` and confirm:
- Exactly 2 resources to add
- 0 changes to existing resources

## Risk Assessment
- **Risk**: None — exact copy of proven pattern, no existing resources affected.

## Validation Gates
1. `tofu -chdir=domains plan` — 2 to add, 0 to change, 0 to destroy

## Plan Quality Assessment

**Complexity Score**: 1/10 (LOW)
**Confidence Score**: 10/10 (HIGH)

**Confidence Factors**:
✅ Clear requirements from spec
✅ Identical pattern at domains/main.tf:207-228
✅ No new dependencies or subsystems
✅ Single file, single append operation

**Estimated one-pass success probability**: 99%
**Reasoning**: Direct copy of existing pattern with only name/email substitution.
