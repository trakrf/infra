# --- Alt Domain Zones ---
# These domains redirect to the canonical trakrf.id

locals {
  alt_domains = {
    getrf_id     = "getrf.id"
    trakrf_app   = "trakrf.app"
    trakrf_com   = "trakrf.com"
    trakrfid_com = "trakrfid.com"
  }
}

resource "cloudflare_zone" "alt" {
  for_each   = local.alt_domains
  account_id = var.account_id
  zone       = each.value
}

# --- DNS Records for Redirect Interception ---
# Proxied A records to RFC 5737 dummy IP so Cloudflare can apply redirect rules

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

# --- 301 Redirect Rulesets ---
# One ruleset per zone: root + www → https://trakrf.id

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

# --- Zone Settings (mirror trakrf.id) ---

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

# --- getrf.id Email Routing ---

resource "cloudflare_email_routing_settings" "getrf_id" {
  zone_id = cloudflare_zone.alt["getrf_id"].id
  enabled = true
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
