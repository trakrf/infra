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

# app.preview.trakrf.id — direct A record to GKE Traefik LB (grey-cloud /
# DNS-only). Cut over from Railway (was CNAME to f67wu1p6.up.railway.app).
#
# Not CF-proxied because CF Universal SSL (Free tier) only covers single-label
# wildcards (`*.trakrf.id` matches `app.trakrf.id`, not `app.preview.trakrf.id`)
# — orange-cloud here would get 552 handshake failures at the edge. Origin TLS
# uses a per-host cert-manager Certificate issued by Let's Encrypt via HTTP-01.
# Same Traefik backend service as `app.preview.gke.trakrf.id`; per-IngressRoute
# breakglass IPAllowList middleware enforces origin lock.
#
# Future: revisit CF Total TLS or Advanced Certificate when adding more hosts
# under preview.trakrf.id or building per-tenant subdomains — at that point
# orange-cloud + the Origin Cert path becomes viable again.
resource "cloudflare_record" "app_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.preview"
  content = var.gke_traefik_lb_ip
  type    = "A"
  proxied = false
  comment = "GKE preview origin (DNS-only; LE cert at Traefik)"
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

