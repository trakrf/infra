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

resource "cloudflare_record" "mail" {
  zone_id = cloudflare_zone.domain.id
  name    = "mail"
  content = var.domain_name
  type    = "CNAME"
  proxied = false
}

# # Add required MX records
# resource "cloudflare_record" "mx_1" {
#   zone_id  = cloudflare_zone.domain.id
#   name     = "@"
#   content  = "isaac.mx.cloudflare.net"
#   type     = "MX"
#   priority = 40
# }
#
# resource "cloudflare_record" "mx_2" {
#   zone_id  = cloudflare_zone.domain.id
#   name     = "@"
#   content  = "linda.mx.cloudflare.net"
#   type     = "MX"
#   priority = 80
# }

# Add required SPF record
resource "cloudflare_record" "spf" {
  zone_id = cloudflare_zone.domain.id
  name    = "@"
  content = "v=spf1 include:_spf.mx.cloudflare.net ~all"
  type    = "TXT"
}

# Add DMARC record for email deliverability
resource "cloudflare_record" "dmarc" {
  zone_id = cloudflare_zone.domain.id
  name    = "_dmarc"
  content = "v=DMARC1; p=none; rua=mailto:admin@trakrf.id"
  type    = "TXT"
}

# Enable Email Routing for the zone
resource "cloudflare_email_routing_settings" "main" {
  zone_id = cloudflare_zone.domain.id
  enabled = true
}

# todo: change these aliases to groups
locals {
  catchall_email = "REDACTED_EMAIL"

  email_aliases = {
    abuse   = local.catchall_email
    admin   = local.catchall_email
    info    = local.catchall_email
    mike    = local.catchall_email
    sales   = local.catchall_email
    support = local.catchall_email
  }
}

resource "cloudflare_email_routing_address" "example_email_routing_address" {
  account_id = var.account_id
  email      = local.catchall_email
}

# Create a specific email routing rule (example)
resource "cloudflare_email_routing_rule" "alias" {
  for_each = local.email_aliases

  zone_id = cloudflare_zone.domain.id
  name    = "Email Rule for ${each.key}"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "${each.key}@${var.domain_name}"
  }

  action {
    type  = "forward"
    value = [each.value]
  }
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

# Customer-specific email routing setup
# JCI-OMH: Multi-destination alias (differs from single-destination pattern above)
resource "cloudflare_email_routing_address" "jci_stephen" {
  account_id = var.account_id
  email      = "REDACTED_EMAIL"
}

resource "cloudflare_email_routing_rule" "jci_omh" {
  zone_id = cloudflare_zone.domain.id
  name    = "Email Rule for jci-omh"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "jci-omh@${var.domain_name}"
  }

  action {
    type = "forward"
    value = [
      local.catchall_email
      # Temporarily disabled for testing - will re-add after initial verification
      # cloudflare_email_routing_address.jci_stephen.email
    ]
  }
}

# Tim alias - external destination
resource "cloudflare_email_routing_address" "tim" {
  account_id = var.account_id
  email      = "REDACTED_EMAIL"
}

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

# Nick alias - external destination
resource "cloudflare_email_routing_address" "nick" {
  account_id = var.account_id
  email      = "REDACTED_EMAIL"
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

# Peter alias - external destination
resource "cloudflare_email_routing_address" "peter" {
  account_id = var.account_id
  email      = "REDACTED_EMAIL"
}

resource "cloudflare_email_routing_rule" "peter" {
  zone_id = cloudflare_zone.domain.id
  name    = "Email Rule for peter"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "peter@${var.domain_name}"
  }

  action {
    type  = "forward"
    value = [cloudflare_email_routing_address.peter.email]
  }
}
