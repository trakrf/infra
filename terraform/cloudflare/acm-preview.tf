# Advanced Certificate (ACM) for the two-label preview host (TRA-856).
#
# Free Universal SSL covers `trakrf.id` + `*.trakrf.id` only (one label deep),
# so `app.preview.trakrf.id` fails the edge TLS handshake when orange-clouded.
# An ACM advanced certificate for `*.preview.trakrf.id` provides the edge cert.
# Revives the intent of canceled TRA-388 in the GKE/trakrf.id world.
#
# PREREQUISITE: the trakrf.id zone must have an Advanced Certificate Manager
# subscription (~$10/mo). On the Free plan without ACM, ordering this cert
# returns API error 1450. Enabling ACM is a billing action (dashboard:
# SSL/TLS → Edge Certificates → enable ACM, or zone subscription API) and must
# be done before `tofu apply` of this resource will succeed.
resource "cloudflare_certificate_pack" "preview_advanced" {
  zone_id               = cloudflare_zone.domain.id
  type                  = "advanced"
  hosts                 = ["preview.trakrf.id", "*.preview.trakrf.id"]
  validation_method     = "txt"
  validity_days         = 90
  certificate_authority = "google"
  cloudflare_branding   = false

  # TXT validation is automatic for a Cloudflare-hosted zone; wait until the
  # pack is active so a same-run DNS proxy flip doesn't precede a live edge cert.
  wait_for_active_status = true

  lifecycle {
    create_before_destroy = true
  }
}
