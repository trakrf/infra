# Cloudflare's published IP ranges. Consumed by the GKE Traefik
# `cloudflare-allow` IPAllowList middleware via root-chart inline values
# (scripts/apply-root-app.sh reads the outputs below).
#
# CF rotates these occasionally. Re-run `just cloudflare` and
# `scripts/apply-root-app.sh gke` to refresh the allowlist.

data "cloudflare_ip_ranges" "this" {}
