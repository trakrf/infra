# Static regional EXTERNAL IP for the preview CNPG primary LoadBalancer
# (TRA-810). Lets external psql clients reach the preview database for the
# M3 FDW-pull-migration development work; reuses the static-IP + DNS A
# pattern from the MQTT broker (TRA-828) and the Traefik LB (TRA-461).
#
# Preview only — prod stays in-cluster-only by structure. The Helm chart
# emits the LoadBalancer Service only when dbPreviewIp is set (root chart
# gates on cluster=gke), so an empty IP keeps prod and non-GKE overlays
# from accidentally getting a public Postgres surface.

resource "google_compute_address" "db_preview" {
  name         = "db-preview-${local.name_prefix}"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  description = "Static LB IP for the preview CNPG primary — pinned via Service.spec.loadBalancerIP (TRA-810)"

  labels = merge(local.common_labels, { ticket = "tra-810" })

  lifecycle {
    prevent_destroy = true
  }
}
