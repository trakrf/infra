# API token for cert-manager DNS-01 ACME challenges on trakrf.app
# Scoped: Zone > DNS > Write on trakrf.app only
# TRA-378 (child of TRA-368). Pattern mirrors traefik_dns token in d2ai-infra/bootstrap.
resource "cloudflare_api_token" "cert_manager" {
  name = "cert-manager-dns01-trakrf-app"

  policy {
    permission_groups = [
      data.cloudflare_api_token_permission_groups.all.zone["DNS Write"],
    ]
    resources = {
      "com.cloudflare.api.account.zone.${var.trakrf_app_zone_id}" = "*"
    }
  }
}
