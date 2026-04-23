# Static regional IP for Traefik's LoadBalancer Service. PREMIUM network tier
# (default for new projects) — matches the GKE zonal LB classic Network LB.
# prevent_destroy guards against accidental rotation; the DNS A records in
# dns.tf depend on this IP being stable across cluster rebuilds.
resource "google_compute_address" "traefik" {
  name         = "traefik-${local.name_prefix}"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  description = "Static LB IP for Traefik — pinned via Service.spec.loadBalancerIP (TRA-461)"

  labels = merge(local.common_labels, { ticket = "tra-461" })

  lifecycle {
    prevent_destroy = true
  }
}
