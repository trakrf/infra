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

# App preview subdomain for Railway deployments
resource "cloudflare_record" "app_preview" {
  zone_id = cloudflare_zone.domain.id
  name    = "app.preview"
  content = var.railway_app_preview_endpoint
  type    = "CNAME"
  proxied = false # DNS-only mode for Railway deployments
}

# Docs subdomain for Cloudflare Pages (Docusaurus)
resource "cloudflare_record" "docs" {
  zone_id = cloudflare_zone.domain.id
  name    = "docs"
  content = cloudflare_pages_project.docs.subdomain
  type    = "CNAME"
  proxied = true
}

# DMARC record for email deliverability
resource "cloudflare_record" "dmarc" {
  zone_id = cloudflare_zone.domain.id
  name    = "_dmarc"
  content = "v=DMARC1; p=none; rua=mailto:admin@trakrf.id"
  type    = "TXT"
}



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

