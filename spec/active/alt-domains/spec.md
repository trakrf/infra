# Feature: Alt Domain Zones + Redirects

## Origin
TrakRF owns several alternate domains (getrf.id, trakrf.app, trakrf.com, trakrfid.com) that were onboarded to Cloudflare via dashboard. These need to be managed in Terraform with 301 redirects to the canonical domain (trakrf.id).

## Outcome
All four alt domains are managed in Terraform with DNS records, 301 redirects to https://trakrf.id, and getrf.id has Cloudflare email routing configured. The canonical trakrf.id domain also gets root+www redirects via the same mechanism (it already has Pages/DNS config, but needs the redirect rules for consistency — actually, trakrf.id is the canonical domain so it should NOT get redirects).

## User Story
As the TrakRF infrastructure admin
I want all alt domains redirecting to the canonical trakrf.id with IaC management
So that brand domains resolve correctly and are not managed via clickops

## Context
**Discovery**: Four alt domains already exist in Cloudflare (onboarded via dashboard). They need Terraform import and redirect configuration.
**Current**: Domains exist in Cloudflare but are not in Terraform state. No redirects configured.
**Desired**: All four domains in Terraform with 301 redirects; getrf.id also has email routing.

## Technical Requirements

### New Zones (import existing)
- `cloudflare_zone` for: getrf.id, trakrf.app, trakrf.com, trakrfid.com

### 301 Redirects (root @ and www → https://trakrf.id)
Apply to all four alt domains. Use Cloudflare redirect rules (ruleset) or Page Rules.
- Root (@) → 301 → https://trakrf.id
- www → 301 → https://trakrf.id
- **trakrf.id is excluded** — it is the canonical domain, leave existing config as-is

### DNS Records for Redirects
Each alt domain needs proxied DNS records (CNAME or A) for @ and www so Cloudflare can intercept and apply redirect rules. Typically a proxied A record to 192.0.2.1 (RFC 5737 dummy) or similar pattern.

### Email Routing (getrf.id only)
- Enable `cloudflare_email_routing_settings` for getrf.id
- Add MX records: isaac.mx.cloudflare.net (priority 40), linda.mx.cloudflare.net (priority 80)
- Add SPF TXT record: `v=spf1 include:_spf.mx.cloudflare.net ~all`
- Single alias: az1@getrf.id → REDACTED_EMAIL
- Register destination address: REDACTED_EMAIL

### No Email for Other Alt Domains
- trakrf.app, trakrf.com, trakrfid.com: NO MX records, no email routing

### Zone Settings
Apply same security/TLS settings as trakrf.id zone to all alt domains.

## File Organization
- New file: `domains/alt-domains.tf` — all alt domain zones, DNS, redirects, and getrf.id email routing
- Keep existing `main.tf` untouched (trakrf.id config stays as-is)

## Validation Criteria
- [ ] `tofu plan` shows clean plan after import (no unexpected changes)
- [ ] All four zones declared with correct zone names
- [ ] Redirect rules configured for @ and www on all four alt domains
- [ ] getrf.id has email routing enabled with az1@ alias
- [ ] getrf.id has MX + SPF records
- [ ] trakrf.app, trakrf.com, trakrfid.com have NO email config
- [ ] trakrf.id is completely untouched
- [ ] Zone settings (TLS, HTTPS, security) applied to all alt domains
- [ ] Resource naming follows existing patterns in main.tf

## Import Strategy
Zones were onboarded via dashboard, so `tofu import` commands will be needed:
```bash
tofu -chdir=domains import cloudflare_zone.getrf_id <zone_id>
tofu -chdir=domains import cloudflare_zone.trakrf_app <zone_id>
tofu -chdir=domains import cloudflare_zone.trakrf_com <zone_id>
tofu -chdir=domains import cloudflare_zone.trakrfid_com <zone_id>
```
Zone IDs will need to be retrieved from Cloudflare dashboard or API before import.

## Decisions
- **Redirect mechanism**: Use `cloudflare_ruleset` (modern). Do NOT use deprecated `cloudflare_page_rule`.
- **Existing DNS records**: No need to import old DNS records from dashboard — Terraform will create fresh records. Any pre-existing records can be manually deleted or will be replaced.
