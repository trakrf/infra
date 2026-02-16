# Feature: peter@ Email Alias

## Origin
User requested adding a new email routing alias for Peter Stankavich.

## Outcome
Emails sent to `peter@trakrf.id` will be routed to `REDACTED_EMAIL` via Cloudflare Email Routing.

## User Story
As the trakrf.id domain administrator
I want to add a `peter@trakrf.id` email alias
So that Peter Stankavich can receive email at a trakrf.id address

## Context
**Current**: Nine email aliases exist — six catchall aliases (abuse, admin, info, mike, sales, support) routing to the catchall Gmail, plus three individual aliases (jci-omh, tim, nick) routing to external addresses.
**Desired**: Add `peter@trakrf.id` → `REDACTED_EMAIL` as a new individual alias, following the same pattern as tim@ and nick@.

## Technical Requirements
- Register `REDACTED_EMAIL` as a verified destination address (`cloudflare_email_routing_address`)
- Create an email routing rule matching `peter@trakrf.id` (`cloudflare_email_routing_rule`)
- Follow the existing individual alias pattern in `domains/main.tf` (see tim/nick blocks, lines ~184–228)

## Validation Criteria
- [ ] `tofu plan` shows exactly 2 new resources, 0 changes to existing
- [ ] `tofu apply` completes successfully
- [ ] Cloudflare sends verification email to `REDACTED_EMAIL`
- [ ] After verification, emails to `peter@trakrf.id` are delivered

## Conversation References
- User request: "i want to add another alias peter@ for REDACTED_EMAIL"
- Pattern: Identical to existing tim@ and nick@ alias blocks
