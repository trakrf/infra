# Implementation Plan: Alt Domain Zones + Redirects
Generated: 2026-03-29
Specification: spec.md

## Understanding
Add four alt domains (getrf.id, trakrf.app, trakrf.com, trakrfid.com) to Terraform management. Each gets proxied DNS records and a `cloudflare_ruleset` for 301 redirects (root + www → https://trakrf.id). getrf.id additionally gets Cloudflare email routing (az1@ alias forwarding to REDACTED_EMAIL via existing verified address). trakrf.id is untouched.

## Relevant Files

**Reference Patterns** (existing code to follow):
- `domains/main.tf` (lines 1-4) — zone resource pattern
- `domains/main.tf` (lines 87-92) — SPF record pattern
- `domains/main.tf` (lines 103-106) — email routing settings pattern
- `domains/main.tf` (lines 128-145) — email routing rule pattern with for_each
- `domains/main.tf` (lines 148-163) — zone settings override pattern

**Files to Create**:
- `domains/alt-domains.tf` — all alt domain infrastructure

**Files to Modify**:
- None — trakrf.id config is untouched

## Architecture Impact
- **Subsystems affected**: Cloudflare DNS, Cloudflare Rulesets, Cloudflare Email Routing
- **New dependencies**: None
- **Breaking changes**: None

## Task Breakdown

### Task 1: Retrieve Zone IDs from Cloudflare API
**Action**: Shell commands to get zone IDs for import

```bash
# Use CLOUDFLARE_API_TOKEN from env
for domain in getrf.id trakrf.app trakrf.com trakrfid.com; do
  echo "$domain:"
  curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$domain" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" | jq -r '.result[0].id'
done
```

**Validation**: All four zone IDs returned (non-null).

### Task 2: Write `domains/alt-domains.tf` — Zone Resources
**File**: `domains/alt-domains.tf`
**Action**: CREATE

```hcl
# --- Alt Domain Zones ---
# These domains redirect to the canonical trakrf.id

locals {
  alt_domains = {
    getrf_id    = "getrf.id"
    trakrf_app  = "trakrf.app"
    trakrf_com  = "trakrf.com"
    trakrfid_com = "trakrfid.com"
  }
}

resource "cloudflare_zone" "alt" {
  for_each   = local.alt_domains
  account_id = var.account_id
  zone       = each.value
}
```

**Validation**: `tofu -chdir=domains validate`

### Task 3: Add DNS Records for Redirects (all four alt domains)
**File**: `domains/alt-domains.tf`
**Action**: APPEND

Each alt domain needs proxied A records for @ and www pointing to 192.0.2.1 (RFC 5737 dummy) so Cloudflare can intercept traffic and apply redirect rules.

```hcl
# Proxied DNS records for redirect interception
resource "cloudflare_record" "alt_root" {
  for_each = local.alt_domains
  zone_id  = cloudflare_zone.alt[each.key].id
  name     = "@"
  content  = "192.0.2.1"
  type     = "A"
  proxied  = true
}

resource "cloudflare_record" "alt_www" {
  for_each = local.alt_domains
  zone_id  = cloudflare_zone.alt[each.key].id
  name     = "www"
  content  = "192.0.2.1"
  type     = "A"
  proxied  = true
}
```

**Validation**: `tofu -chdir=domains validate`

### Task 4: Add Redirect Rulesets (all four alt domains)
**File**: `domains/alt-domains.tf`
**Action**: APPEND

One ruleset per zone, two rules each (root + www → https://trakrf.id).

```hcl
resource "cloudflare_ruleset" "alt_redirect" {
  for_each    = local.alt_domains
  zone_id     = cloudflare_zone.alt[each.key].id
  name        = "Redirect to trakrf.id"
  description = "301 redirect ${each.value} to canonical trakrf.id"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules {
    ref         = "redirect_root"
    action      = "redirect"
    expression  = "(http.host eq \"${each.value}\")"
    description = "Redirect root to trakrf.id"

    action_parameters {
      from_value {
        status_code = 301
        target_url {
          value = "https://trakrf.id"
        }
        preserve_query_string = false
      }
    }
  }

  rules {
    ref         = "redirect_www"
    action      = "redirect"
    expression  = "(http.host eq \"www.${each.value}\")"
    description = "Redirect www to trakrf.id"

    action_parameters {
      from_value {
        status_code = 301
        target_url {
          value = "https://trakrf.id"
        }
        preserve_query_string = false
      }
    }
  }
}
```

**Validation**: `tofu -chdir=domains validate`

### Task 5: Add Zone Settings (all four alt domains)
**File**: `domains/alt-domains.tf`
**Action**: APPEND

Mirror trakrf.id zone settings (from main.tf lines 148-163).

```hcl
resource "cloudflare_zone_settings_override" "alt_settings" {
  for_each = local.alt_domains
  zone_id  = cloudflare_zone.alt[each.key].id
  settings {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    security_level           = "medium"
    brotli                   = "on"
    automatic_https_rewrites = "on"
    opportunistic_encryption = "on"
    tls_1_3                  = "on"
    security_header {
      enabled = true
    }
  }
}
```

**Validation**: `tofu -chdir=domains validate`

### Task 6: Add Email Routing for getrf.id
**File**: `domains/alt-domains.tf`
**Action**: APPEND

Email routing for getrf.id only. Uses existing verified destination `REDACTED_EMAIL`.

```hcl
# --- getrf.id Email Routing ---

resource "cloudflare_email_routing_settings" "getrf_id" {
  zone_id = cloudflare_zone.alt["getrf_id"].id
  enabled = true
}

resource "cloudflare_record" "getrf_id_mx_1" {
  zone_id  = cloudflare_zone.alt["getrf_id"].id
  name     = "@"
  content  = "isaac.mx.cloudflare.net"
  type     = "MX"
  priority = 40
}

resource "cloudflare_record" "getrf_id_mx_2" {
  zone_id  = cloudflare_zone.alt["getrf_id"].id
  name     = "@"
  content  = "linda.mx.cloudflare.net"
  type     = "MX"
  priority = 80
}

resource "cloudflare_record" "getrf_id_spf" {
  zone_id = cloudflare_zone.alt["getrf_id"].id
  name    = "@"
  content = "v=spf1 include:_spf.mx.cloudflare.net ~all"
  type    = "TXT"
}

resource "cloudflare_email_routing_rule" "getrf_id_az1" {
  zone_id = cloudflare_zone.alt["getrf_id"].id
  name    = "Email Rule for az1"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "az1@getrf.id"
  }

  action {
    type  = "forward"
    value = [local.catchall_email]
  }
}
```

Note: `local.catchall_email` is defined in main.tf as `REDACTED_EMAIL` — reuse it directly.

**Validation**: `tofu -chdir=domains validate`

### Task 7: Import Zones into Terraform State
**Action**: Shell commands

```bash
# Zone IDs retrieved in Task 1
tofu -chdir=domains import 'cloudflare_zone.alt["getrf_id"]' <getrf_id_zone_id>
tofu -chdir=domains import 'cloudflare_zone.alt["trakrf_app"]' <trakrf_app_zone_id>
tofu -chdir=domains import 'cloudflare_zone.alt["trakrf_com"]' <trakrf_com_zone_id>
tofu -chdir=domains import 'cloudflare_zone.alt["trakrfid_com"]' <trakrfid_com_zone_id>
```

**Validation**: `tofu -chdir=domains state list | grep cloudflare_zone.alt`

### Task 8: Plan and Apply
**Action**: Shell commands

```bash
tofu -chdir=domains plan
# Review output — expect creates for DNS records, rulesets, settings, email routing
# Zones should show no changes (imported)
tofu -chdir=domains apply
```

**Validation**:
- Plan shows zones as no-change (already imported)
- Plan shows creates for: DNS records, rulesets, zone settings, email routing resources
- No unexpected modifications to trakrf.id resources
- Apply succeeds

### Task 9: Manual Verification
- Visit http://getrf.id → should 301 to https://trakrf.id
- Visit http://www.trakrf.app → should 301 to https://trakrf.id
- Send test email to az1@getrf.id → should arrive at REDACTED_EMAIL

## Risk Assessment
- **Risk**: Cloudflare email routing MX records may conflict with any existing MX on getrf.id from Namecheap migration
  **Mitigation**: Old DNS records are not imported; Terraform creates fresh. Delete any conflicting records in dashboard before apply if needed.
- **Risk**: `cloudflare_ruleset` resource syntax varies between provider versions
  **Mitigation**: Validate with `tofu validate` before apply; check provider v4 docs.
- **Risk**: `local.catchall_email` is defined in main.tf — referencing from alt-domains.tf requires it to be in same module
  **Mitigation**: Same `domains/` module, locals are shared. No issue.

## VALIDATION GATES
After writing alt-domains.tf:
- `tofu -chdir=domains validate` — syntax check
- `tofu -chdir=domains plan` — review planned changes (after imports)

## Plan Quality Assessment

**Complexity Score**: 3/10 (LOW)
**Confidence Score**: 8/10 (HIGH)

**Confidence Factors**:
✅ Clear requirements from spec — all domains, redirects, and email routing well-defined
✅ Zone, DNS, email routing patterns exist in main.tf to follow
✅ Single new file, no modifications to existing code
✅ `cloudflare_ruleset` syntax confirmed via documentation research
⚠️ First use of `cloudflare_ruleset` in this repo — no existing reference

**Estimated one-pass success probability**: 85%

**Reasoning**: Straightforward infrastructure addition following established patterns. Only uncertainty is `cloudflare_ruleset` syntax since it's new to the repo, but docs are clear.
