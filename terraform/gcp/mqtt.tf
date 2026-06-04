# Static regional EXTERNAL IPs for per-env Mosquitto LoadBalancers (TRA-828).
# One per env (preview, prod) so DNS A records and Helm loadBalancerIP can be
# wired before the LB Service exists. Mirrors the traefik LB pattern in
# traefik_lb.tf — regional, EXTERNAL, PREMIUM tier, prevent_destroy.
# A records in dns.tf depend on these IPs being stable across cluster rebuilds.

resource "google_compute_address" "mqtt_preview" {
  name         = "mqtt-preview-${local.name_prefix}"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  description = "Static LB IP for trakrf-mosquitto preview MQTT — pinned via Service.spec.loadBalancerIP (TRA-828)"

  labels = merge(local.common_labels, { ticket = "tra-828" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_address" "mqtt_prod" {
  name         = "mqtt-prod-${local.name_prefix}"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  description = "Static LB IP for trakrf-mosquitto prod MQTT — pinned via Service.spec.loadBalancerIP (TRA-828)"

  labels = merge(local.common_labels, { ticket = "tra-828" })

  lifecycle {
    prevent_destroy = true
  }
}
