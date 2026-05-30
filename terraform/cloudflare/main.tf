resource "cloudflare_zone" "domain" {
  account_id = var.account_id
  zone       = var.domain_name
}

# DNS Records
# note that Cloudflare supports CNAME flattening, so we can use a CNAME record for the root domain
# todo: move content value to tfvars
resource "cloudflare_record" "root" {
  zone_id = cloudflare_zone.domain.id
  name    = "@"
  content = cloudflare_pages_project.www.subdomain
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "www" {
  zone_id = cloudflare_zone.domain.id
  name    = "www"
  content = var.domain_name
  type    = "CNAME"
  proxied = true
}

# App subdomain for Railway production deployment
resource "cloudflare_record" "app" {
  zone_id = cloudflare_zone.domain.id
  name    = "app"
  content = var.railway_app_prod_endpoint
  type    = "CNAME"
  ttl     = 60    # lowered pre-cutover (TRA-375) so the Phase-3 orange flip propagates fast
  proxied = false # DNS-only mode for Railway deployments
}

# Preview subdomain for Cloudflare Pages preview deployments
resource "cloudflare_record" "preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "preview"
  content = "preview.${cloudflare_pages_project.www.subdomain}"
  type    = "CNAME"
  proxied = true
}

# app.preview.trakrf.id — public preview API, orange-clouded (TRA-856).
# A record → GKE Traefik LB; Cloudflare-proxied so the edge owns TLS + WAF + DDoS.
#
# The two-label host isn't covered by Free Universal SSL (`*.trakrf.id` matches
# `app.trakrf.id`, not `app.preview.trakrf.id`), so the edge cert comes from an
# ACM advanced certificate for `*.preview.trakrf.id` (see acm-preview.tf). The
# CF→origin leg uses the Cloudflare Origin Cert (origin-cert.tf, SAN
# `*.preview.trakrf.id`); the origin is locked to Cloudflare via the
# `cloudflare-allow` IPAllowList on the public Traefik route (later hardened to
# private-CA Authenticated Origin Pulls). The direct `app.preview.gke.trakrf.id`
# route stays grey + breakglass-gated for origin/test access.
#
# APPLY ORDER (lockstep): ACM cert active → flip this record to proxied → THEN
# add cloudflare-allow on the Traefik route. (Adding cloudflare-allow while the
# record is still grey would 403 all direct traffic.)
resource "cloudflare_record" "app_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.preview"
  content = var.gke_traefik_lb_ip
  type    = "A"
  proxied = true
  comment = "Orange preview origin via CF edge; ACM cert + cloudflare-allow origin lock (TRA-856)"
}

# Docs subdomain for Cloudflare Pages (Docusaurus)
resource "cloudflare_record" "docs" {
  zone_id = cloudflare_zone.domain.id
  name    = "docs"
  content = cloudflare_pages_project.docs.subdomain
  type    = "CNAME"
  proxied = true
}

# Docs preview subdomain — stable alias for the `preview` branch deployment
resource "cloudflare_record" "docs_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "docs.preview"
  content = "preview.${cloudflare_pages_project.docs.subdomain}"
  type    = "CNAME"
  proxied = true
}

# DMARC record is managed by Cloudflare DMARC Management (Email Security UI),
# which auto-publishes _dmarc with a zone-specific rua mailto so the dashboard
# can ingest aggregate reports. Enable per zone in the Cloudflare dashboard.


# Zone Settings
resource "cloudflare_zone_settings_override" "domain_settings" {
  zone_id = cloudflare_zone.domain.id
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

