# Cloudflare Origin CA certificate for trakrf.id origin TLS.
#
# Cloudflare's "Full (strict)" SSL mode requires the origin present a cert
# valid for the requested hostname. Cloudflare Origin CA certs are signed by
# a Cloudflare CA that the Cloudflare edge trusts but the public internet
# does not — exactly the right scope for origin TLS, with none of the rate
# limits or DNS-01 dance of a public ACME issuer. 15-year validity, instant
# issuance.
#
# SAN covers both preview (this ticket) and the eventual production cutover;
# the resulting Secret is reflected into every trakrf-* namespace that needs
# it.
#
# Wildcards are single-label per RFC 4592: `*.trakrf.id` matches `app.trakrf.id`
# but NOT `app.preview.trakrf.id`. The latter needs a second-level wildcard
# (`*.preview.trakrf.id`) — bake both in so the same cert serves any preview-env
# host (api, app, …) without further re-issuance.

resource "tls_private_key" "origin_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin_ca" {
  private_key_pem = tls_private_key.origin_ca.private_key_pem

  subject {
    common_name  = "trakrf.id"
    organization = "TrakRF"
  }

  dns_names = [
    "trakrf.id",
    "*.trakrf.id",
    "*.preview.trakrf.id",
  ]
}

resource "cloudflare_origin_ca_certificate" "trakrf_id" {
  csr                = tls_cert_request.origin_ca.cert_request_pem
  hostnames          = ["trakrf.id", "*.trakrf.id", "*.preview.trakrf.id"]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}
