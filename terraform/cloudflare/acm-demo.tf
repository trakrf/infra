# Advanced Certificate (ACM) for the two-label demo host app.demo.trakrf.id (TRA-957).
#
# Free Universal SSL covers `trakrf.id` + `*.trakrf.id` only (one label deep), so
# `app.demo.trakrf.id` fails the edge TLS handshake when proxied via the Cloudflare
# Tunnel (sslv3 alert handshake failure — no edge cert for the SNI). An ACM advanced
# certificate provides the edge cert. Same pattern as prod_app_advanced (acm-prod.tf),
# single host (no wildcard needed — only app.demo is exposed).
#
# PREREQUISITE: the trakrf.id zone already has ACM enabled (preview_advanced /
# prod_app_advanced use it), so no additional billing action is required.
resource "cloudflare_certificate_pack" "demo_app_advanced" {
  zone_id               = cloudflare_zone.domain.id
  type                  = "advanced"
  hosts                 = ["app.demo.trakrf.id"]
  validation_method     = "txt"
  validity_days         = 90
  certificate_authority = "google"
  cloudflare_branding   = false

  # TXT validation is automatic for a Cloudflare-hosted zone; wait until the pack
  # is active so the edge cert is verified-live for the proxied tunnel host.
  wait_for_active_status = true

  lifecycle {
    create_before_destroy = true
  }
}
