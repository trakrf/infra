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
