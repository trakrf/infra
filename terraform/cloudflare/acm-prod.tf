# Advanced Certificate (ACM) for the prod public host app.trakrf.id (TRA-375).
#
# Universal SSL covers `trakrf.id` + `*.trakrf.id` (one label), so app.trakrf.id
# IS technically covered — but Universal SSL provisions a per-hostname edge cert
# lazily, only once the host first goes proxied. That opens a TLS-provisioning
# race at the exact moment of the customer-facing orange flip (zone ssl=strict).
# An ACM advanced cert provisions independent of proxy status
# (wait_for_active_status), so the edge cert is verified-active BEFORE the DNS
# flip. Same pattern as preview_advanced (acm-preview.tf), minus the two-label
# wildcard — app.trakrf.id is a single host.
#
# PREREQUISITE: the trakrf.id zone already has ACM enabled (preview_advanced
# uses it), so no additional billing action is required.
resource "cloudflare_certificate_pack" "prod_app_advanced" {
  zone_id               = cloudflare_zone.domain.id
  type                  = "advanced"
  hosts                 = ["app.trakrf.id"]
  validation_method     = "txt"
  validity_days         = 90
  certificate_authority = "google"
  cloudflare_branding   = false

  # TXT validation is automatic for a Cloudflare-hosted zone; wait until the
  # pack is active so the same-run DNS proxy flip can't precede a live edge cert.
  wait_for_active_status = true

  lifecycle {
    create_before_destroy = true
  }
}
