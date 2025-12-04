# Implementation Plan: Email Deliverability Fixes
Generated: 2025-12-04
Specification: spec.md

## Understanding
Fix email deliverability for `mike@trakrf.id` by adding missing routing rule, plus add two new external aliases (`tim@`, `nick@`). Also fix the `mail` CNAME typo and add a DMARC record for improved deliverability.

## Relevant Files

**Reference Patterns** (existing code to follow):
- `domains/main.tf` (lines 92-101) - `email_aliases` local map pattern
- `domains/main.tf` (lines 149-152) - External destination address registration pattern (jci_stephen)
- `domains/main.tf` (lines 154-173) - External routing rule pattern (jci_omh)
- `domains/main.tf` (lines 78-83) - TXT record pattern (SPF)

**Files to Modify**:
- `domains/main.tf` - All changes in this single file

## Architecture Impact
- **Subsystems affected**: Cloudflare Email Routing, DNS
- **New dependencies**: None
- **Breaking changes**: None (additive changes + typo fix)

## Task Breakdown

### Task 1: Add mike@ to email_aliases map
**File**: `domains/main.tf`
**Action**: MODIFY (lines 95-101)
**Pattern**: Existing `email_aliases` map

**Implementation**:
Add `mike = local.catchall_email` to the map:
```terraform
email_aliases = {
  abuse   = local.catchall_email
  admin   = local.catchall_email
  info    = local.catchall_email
  mike    = local.catchall_email
  sales   = local.catchall_email
  support = local.catchall_email
}
```

**Validation**: `tofu validate`

---

### Task 2: Add tim@ external alias
**File**: `domains/main.tf`
**Action**: MODIFY (add after line 173)
**Pattern**: Reference `cloudflare_email_routing_address.jci_stephen` (lines 149-152)

**Implementation**:
```terraform
# Tim alias - external destination
resource "cloudflare_email_routing_address" "tim" {
  account_id = var.account_id
  email      = "REDACTED_EMAIL"
}

resource "cloudflare_email_routing_rule" "tim" {
  zone_id = cloudflare_zone.domain.id
  name    = "Email Rule for tim"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "tim@${var.domain_name}"
  }

  action {
    type  = "forward"
    value = [cloudflare_email_routing_address.tim.email]
  }
}
```

**Validation**: `tofu validate`

---

### Task 3: Add nick@ external alias
**File**: `domains/main.tf`
**Action**: MODIFY (add after tim resources)
**Pattern**: Same as Task 2

**Implementation**:
```terraform
# Nick alias - external destination
resource "cloudflare_email_routing_address" "nick" {
  account_id = var.account_id
  email      = "REDACTED_EMAIL"
}

resource "cloudflare_email_routing_rule" "nick" {
  zone_id = cloudflare_zone.domain.id
  name    = "Email Rule for nick"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "nick@${var.domain_name}"
  }

  action {
    type  = "forward"
    value = [cloudflare_email_routing_address.nick.email]
  }
}
```

**Validation**: `tofu validate`

---

### Task 4: Fix mail CNAME typo
**File**: `domains/main.tf`
**Action**: MODIFY (line 54)
**Pattern**: N/A - simple fix

**Implementation**:
Change `name = "main"` to `name = "mail"`:
```terraform
resource "cloudflare_record" "mail" {
  zone_id = cloudflare_zone.domain.id
  name    = "mail"
  content = var.domain_name
  type    = "CNAME"
  proxied = false
}
```

**Validation**: `tofu validate`

---

### Task 5: Add DMARC record
**File**: `domains/main.tf`
**Action**: MODIFY (add after SPF record, ~line 83)
**Pattern**: Reference `cloudflare_record.spf` (lines 78-83)

**Implementation**:
```terraform
# Add DMARC record for email deliverability
resource "cloudflare_record" "dmarc" {
  zone_id = cloudflare_zone.domain.id
  name    = "_dmarc"
  content = "v=DMARC1; p=none; rua=mailto:admin@trakrf.id"
  type    = "TXT"
}
```

**Validation**: `tofu validate`

---

### Task 6: Plan and Apply
**Action**: Run Terraform

**Implementation**:
```bash
cd domains
tofu plan
# Review changes - expect:
#   + cloudflare_email_routing_address.tim
#   + cloudflare_email_routing_address.nick
#   + cloudflare_email_routing_rule.tim
#   + cloudflare_email_routing_rule.nick
#   + cloudflare_email_routing_rule.alias["mike"]
#   + cloudflare_record.dmarc
#   ~ cloudflare_record.mail (name: "main" -> "mail")
tofu apply
```

**Validation**:
- `tofu plan` shows expected changes
- `tofu apply` succeeds

---

### Task 7: DNS Verification
**Action**: Verify DNS propagation

**Implementation**:
```bash
dig TXT _dmarc.trakrf.id +short
dig CNAME mail.trakrf.id +short
```

**Validation**:
- DMARC returns: `"v=DMARC1; p=none; rua=mailto:admin@trakrf.id"`
- mail CNAME returns: `trakrf.id.`

## Risk Assessment

- **Risk**: Verification emails to tim/nick may go to spam
  **Mitigation**: Coordinate with recipients to check spam folders; Cloudflare sends from recognizable address

- **Risk**: CNAME rename may cause brief DNS inconsistency
  **Mitigation**: Low TTL on Cloudflare records; change is atomic

## Integration Points
- No code changes outside `domains/main.tf`
- No new dependencies
- External verification required for tim@ and nick@ before routing activates

## VALIDATION GATES (MANDATORY)

After EVERY code change:
- `tofu -chdir=domains validate` - Terraform syntax/config validation
- `tofu -chdir=domains fmt -check` - Format check

Final validation:
- `tofu -chdir=domains plan` - Review all changes
- `tofu -chdir=domains apply` - Apply changes

## Post-Apply Verification
1. `dig TXT _dmarc.trakrf.id +short` - Verify DMARC record
2. `dig CNAME mail.trakrf.id +short` - Verify mail CNAME fix
3. Coordinate tim/nick verification email clicks
4. Send test emails to mike@, tim@, nick@ to confirm delivery

## Plan Quality Assessment

**Complexity Score**: 2/10 (LOW)
**Confidence Score**: 9/10 (HIGH)

**Confidence Factors**:
✅ Clear requirements from spec
✅ Similar patterns found in codebase (jci-omh at lines 149-173)
✅ All clarifying questions answered
✅ Single file modification
✅ Additive changes with one simple fix

**Assessment**: Straightforward infrastructure change following established patterns.

**Estimated one-pass success probability**: 95%

**Reasoning**: All changes follow existing patterns in the codebase, single file modification, no new dependencies, well-documented Cloudflare resources.
