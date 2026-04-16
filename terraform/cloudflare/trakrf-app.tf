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
    # HSTS — 2y, include subdomains, preload. CF overrides any origin HSTS,
    # so configure it here (Traefik's middleware would otherwise be silently
    # replaced with max-age=0 default). .app TLD is on the HSTS preload list.
    security_header {
      enabled            = true
      max_age            = 63072000
      include_subdomains = true
      preload            = true
      nosniff            = true
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

# grafana.eks.trakrf.app — public Grafana ingress (TRA-386).
# Same NLB target as eks.trakrf.app; Traefik routes by Host header.
# Grey-cloud (proxied=false): CF Universal SSL on the Free plan doesn't
# cover two-label-deep hosts (*.eks.trakrf.app), so we bypass the edge and
# let Traefik's letsencrypt cert terminate TLS directly. Revisit if we
# adopt Advanced Certificate Manager for WAF/CDN parity on *.eks.
resource "cloudflare_record" "grafana_eks_trakrf_app" {
  zone_id = cloudflare_zone.trakrf_app.id
  name    = "grafana.eks"
  type    = "CNAME"
  content = var.eks_nlb_hostname
  ttl     = 300
  proxied = false
  comment = "TRA-386 — Grafana public ingress (DNS-only; TLS at Traefik)"
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
      id = "77454fe2d30c4220b5701f6fdfb893ba"
    }
  }
}

# Cache rules — SPA/API split on eks.trakrf.app (TRA-381).
resource "cloudflare_ruleset" "trakrf_app_cache_rules" {
  zone_id     = cloudflare_zone.trakrf_app.id
  name        = "eks.trakrf.app cache policy"
  description = "Bypass cache on /api/*, aggressive edge cache on /assets/*"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules {
    action      = "set_cache_settings"
    description = "Bypass cache on API"
    expression  = "(http.host eq \"eks.trakrf.app\" and starts_with(http.request.uri.path, \"/api/\"))"
    enabled     = true
    action_parameters {
      cache = false
    }
  }

  rules {
    action      = "set_cache_settings"
    description = "Aggressive edge cache on hashed SPA assets"
    expression  = "(http.host eq \"eks.trakrf.app\" and starts_with(http.request.uri.path, \"/assets/\"))"
    enabled     = true
    action_parameters {
      cache = true
      edge_ttl {
        mode    = "override_origin"
        default = 31536000 # 1 year
      }
      browser_ttl {
        mode = "respect_origin"
      }
    }
  }
}
