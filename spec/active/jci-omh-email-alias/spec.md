# Feature: JCI-OMH Email Alias

## Origin
This specification emerged from a request to add a new email alias for JCI (Johnson Controls International) OMH communications.

## Outcome
Add `jci-omh@trakrf.id` email alias that forwards to multiple recipients, enabling both administrative oversight and stakeholder delivery.

## User Story
As the trakrf.id administrator,
I want jci-omh@trakrf.id to forward to both my personal email and a JCI stakeholder,
So that I maintain oversight while ensuring JCI receives communications directly.

## Context

**Discovery**: Current email routing infrastructure exists with 5 aliases (abuse, admin, info, sales, support) that each forward to a single destination (REDACTED_EMAIL).

**Current**: All existing aliases use a `for_each` loop over `local.email_aliases` map where each alias maps to a single destination email address.

**Desired**: New alias that forwards to TWO recipients:
- `REDACTED_EMAIL` (administrative oversight)
- `REDACTED_EMAIL` (JCI stakeholder)

**Pattern Break**: This is the first alias requiring multiple destinations, breaking the current single-destination pattern.

## Technical Requirements

### Email Routing Configuration
- **Alias**: `jci-omh@trakrf.id`
- **Destinations**:
  - `REDACTED_EMAIL` (already verified)
  - `REDACTED_EMAIL` (needs verification)

### Infrastructure Changes Required
1. Add `REDACTED_EMAIL` to verified destination addresses
2. Create dedicated email routing rule for `jci-omh` with multi-destination forwarding
3. Keep implementation separate from existing `for_each` loop to preserve current pattern

### Cloudflare Resources
- **New**: `cloudflare_email_routing_address` for REDACTED_EMAIL
- **New**: `cloudflare_email_routing_rule` for jci-omh alias with multiple destinations

### Technical Notes
- Cloudflare email routing rules support arrays in `action.value` for multi-destination forwarding
- All destination emails must be verified via `cloudflare_email_routing_address` resources
- Current TODO exists to "change these aliases to groups" - this change maintains compatibility with future group migration

## Implementation Approach

Since this alias differs from the existing pattern (single vs. multiple destinations), implement as a standalone rule rather than modifying the `local.email_aliases` structure:

```hcl
# Add new verified destination
resource "cloudflare_email_routing_address" "jci_stephen" {
  account_id = var.account_id
  email      = "REDACTED_EMAIL"
}

# Create multi-destination routing rule
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

## Validation Criteria
- [ ] `REDACTED_EMAIL` receives verification email from Cloudflare
- [ ] Test email to `jci-omh@trakrf.id` forwards to both destinations
- [ ] `tofu plan` shows only new resources (no changes to existing aliases)
- [ ] Email routing rule appears in Cloudflare dashboard as enabled

## Conversation References
- **Request**: "lets add a new alias jci-omh@trakrf.id. you can ass the same gmail for me and add REDACTED_EMAIL"
- **Context**: Existing aliases in `domains/main.tf` lines 92-127
- **Pattern**: Current aliases use single-destination forwarding via `for_each` loop

## Future Considerations
- When migrating to email routing groups (per existing TODO), this multi-destination alias could become a group
- If more multi-destination aliases are needed, consider refactoring `local.email_aliases` to support arrays
