# Feature: Email Deliverability Fixes

## Origin
This specification emerged from investigating email deliverability issues to `mike@trakrf.id`.

## Outcome
Emails sent to `mike@trakrf.id` will be successfully delivered, and overall email deliverability for the domain will be improved through proper DNS configuration.

## User Story
As the domain owner
I want to receive emails at mike@trakrf.id
So that I can be contacted at my personal domain address

## Context
**Discovery**: Investigation revealed multiple issues:
1. No routing rule exists for `mike@trakrf.id` - emails are dropped/bounced
2. Typo in Terraform: `name = "main"` instead of `name = "mail"` (line 54)
3. No DMARC record exists, hurting sender reputation checks

**Current State**:
- Email aliases configured: `abuse`, `admin`, `info`, `sales`, `support`
- All route to `miks2u+trakrf@gmail.com`
- MX records exist (auto-managed by Cloudflare Email Routing)
- SPF record exists: `v=spf1 include:_spf.mx.cloudflare.net ~all`
- No DMARC record
- `mail.trakrf.id` CNAME doesn't exist (typo created `main.trakrf.id`)

**Desired State**:
- `mike@trakrf.id` routes to catchall email
- `tim@trakrf.id` routes to `tim.buckley@rfidready.net`
- `nick@trakrf.id` routes to `nicholusmuwonge@gmail.com`
- DMARC record in place for better deliverability
- `mail` CNAME typo corrected

## Technical Requirements

### R1: Add mike@ email alias
Add `mike` to the `email_aliases` map in `domains/main.tf`:
```terraform
email_aliases = {
  abuse   = local.catchall_email
  admin   = local.catchall_email
  info    = local.catchall_email
  mike    = local.catchall_email  # NEW
  sales   = local.catchall_email
  support = local.catchall_email
}
```

### R1b: Add tim@ and nick@ aliases (external destinations)
These route to external addresses, so they need separate routing resources (similar to jci-omh pattern):

```terraform
# Destination address registrations
resource "cloudflare_email_routing_address" "tim" {
  account_id = var.account_id
  email      = "tim.buckley@rfidready.net"
}

resource "cloudflare_email_routing_address" "nick" {
  account_id = var.account_id
  email      = "nicholusmuwonge@gmail.com"
}

# Routing rules
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

Note: External destinations require `cloudflare_email_routing_address` registration (triggers verification email).

### R2: Fix mail CNAME typo
Change line 54 from `name = "main"` to `name = "mail"`:
```terraform
resource "cloudflare_record" "mail" {
  zone_id = cloudflare_zone.domain.id
  name    = "mail"  # Fixed from "main"
  content = var.domain_name
  type    = "CNAME"
  proxied = false
}
```

### R3: Add DMARC record
Add a DMARC TXT record for `_dmarc.trakrf.id`:
```terraform
resource "cloudflare_record" "dmarc" {
  zone_id = cloudflare_zone.domain.id
  name    = "_dmarc"
  content = "v=DMARC1; p=none; rua=mailto:admin@trakrf.id"
  type    = "TXT"
}
```

Note: Starting with `p=none` for monitoring. Can tighten to `p=quarantine` or `p=reject` after observing reports.

## Validation Criteria
- [ ] `dig MX trakrf.id` returns Cloudflare MX records
- [ ] `dig TXT trakrf.id` returns SPF record
- [ ] `dig TXT _dmarc.trakrf.id` returns DMARC record
- [ ] `dig CNAME mail.trakrf.id` returns `trakrf.id`
- [ ] Send test email to `mike@trakrf.id` and confirm delivery to Gmail
- [ ] Send test email to `tim@trakrf.id` and confirm delivery to rfidready.net
- [ ] Send test email to `nick@trakrf.id` and confirm delivery to Gmail
- [ ] `tofu plan` shows expected changes (add aliases, fix mail CNAME, add DMARC)

## Out of Scope
- Tightening DMARC policy beyond `p=none` (future iteration)
- DKIM configuration (Cloudflare Email Routing handles this)
- Removing commented-out MX records from Terraform (cosmetic)

## Conversation References
- Key insight: "There is no `mike@trakrf.id` routing rule, so emails are likely being dropped or bounced"
- Discovery: Typo `name = "main"` instead of `name = "mail"` at line 54
- Discovery: No DMARC record exists (`dig TXT _dmarc.trakrf.id` returned empty)
