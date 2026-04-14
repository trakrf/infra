# --- trakrf.app Primary Zone ---
# Promoted from alt-redirect to primary zone (TRA-377).
# DNS records (eks.trakrf.app CNAME etc.) land in TRA-381.

resource "cloudflare_zone" "trakrf_app" {
  account_id = var.account_id
  zone       = "trakrf.app"
}

# Zone Settings — .app TLD is on the HSTS preload list,
# so keep SSL strict + always-HTTPS posture aligned with trakrf.id.
resource "cloudflare_zone_settings_override" "trakrf_app" {
  zone_id = cloudflare_zone.trakrf_app.id
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

# eks.trakrf.app — EKS demo environment (TRA-381).
# CNAME to the Traefik NLB hostname, orange-cloud proxied for WAF + cache.
resource "cloudflare_record" "eks_trakrf_app" {
  zone_id = cloudflare_zone.trakrf_app.id
  name    = "eks"
  type    = "CNAME"
  content = var.eks_nlb_hostname
  ttl     = 1 # automatic when proxied
  proxied = true
  comment = "TRA-381 — EKS demo: Cloudflare → NLB → Traefik → trakrf-backend"
}

# WAF — Cloudflare Free Managed Ruleset (TRA-381).
# Block mode from day one (low FP rate, minimal traffic, greenfield demo).
resource "cloudflare_ruleset" "trakrf_app_managed_waf" {
  zone_id     = cloudflare_zone.trakrf_app.id
  name        = "Managed WAF entrypoint"
  description = "Executes Cloudflare Free Managed Ruleset on all zone traffic"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules {
    action      = "execute"
    description = "Free Managed Ruleset"
    expression  = "true"
    enabled     = true
    action_parameters {
      id = "efb7b8c949ac4650a09736fc376e9aee"
    }
  }
}
