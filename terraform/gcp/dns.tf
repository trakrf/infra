# Public DNS zone for GKE demo workloads.
# Cloudflare delegates gke.trakrf.app here via terraform/cloudflare/gcp-delegation.tf.
resource "google_dns_managed_zone" "gke_trakrf_app" {
  name        = "gke-trakrf-app"
  dns_name    = "gke.trakrf.app."
  description = "Public DNS zone for GKE demo workloads (TRA-460)"

  labels = local.common_labels

  # Zone holds the delegation that Cloudflare NS records point at. GCP assigns
  # random nameservers at create time, so destroying it forces CF NS rotation on
  # every rebuild. Mirrors the prevent_destroy pattern on aws_route53_zone and
  # azurerm_dns_zone.aks_trakrf_app.
  lifecycle {
    prevent_destroy = true
  }
}

# Apex A record: gke.trakrf.app -> static Traefik LB IP
resource "google_dns_record_set" "gke_apex" {
  managed_zone = google_dns_managed_zone.gke_trakrf_app.name
  name         = google_dns_managed_zone.gke_trakrf_app.dns_name # "gke.trakrf.app."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.traefik.address]
}

# Wildcard A record: *.gke.trakrf.app -> same IP. Traefik IngressRoute hostname
# matching handles the per-subdomain routing server-side.
resource "google_dns_record_set" "gke_wildcard" {
  managed_zone = google_dns_managed_zone.gke_trakrf_app.name
  name         = "*.${google_dns_managed_zone.gke_trakrf_app.dns_name}" # "*.gke.trakrf.app."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.traefik.address]
}

# Public DNS zone for GKE-served `.id` hosts that need a GKE-issued public ACME
# cert — i.e. hosts that can't ride the Cloudflare edge cert. Two consumers
# queued behind this: the Mosquitto broker (TRA-828, device-facing) and the
# Grafana hostname move (browser-facing). Cloudflare delegates gke.trakrf.id
# here via terraform/cloudflare/gcp-delegation.tf.
resource "google_dns_managed_zone" "gke_trakrf_id" {
  name        = "gke-trakrf-id"
  dns_name    = "gke.trakrf.id."
  description = "Public DNS zone for GKE-issued-cert .id hosts (TRA-829)"

  labels = local.common_labels

  # Mirrors the prevent_destroy pattern on gke_trakrf_app and on the Route53/
  # Azure zones — GCP assigns random nameservers at create time, so destroying
  # the zone forces CF NS rotation on every rebuild.
  lifecycle {
    prevent_destroy = true
  }
}

# Apex A record: gke.trakrf.id -> static Traefik LB IP. Future Traefik-routed
# .id hosts (Grafana first) resolve here via the wildcard below; the broker
# (TRA-828) uses its own host-specific A record on its own LB IP.
resource "google_dns_record_set" "gke_id_apex" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = google_dns_managed_zone.gke_trakrf_id.dns_name # "gke.trakrf.id."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.traefik.address]
}

# Wildcard A record: *.gke.trakrf.id -> same IP. Traefik IngressRoute hostname
# matching handles per-subdomain routing server-side.
resource "google_dns_record_set" "gke_id_wildcard" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = "*.${google_dns_managed_zone.gke_trakrf_id.dns_name}" # "*.gke.trakrf.id."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.traefik.address]
}

# TRA-828 — Per-env broker A records on dedicated static IPs (not the wildcard,
# which points at Traefik). DNS for the device-facing Mosquitto LoadBalancers.
resource "google_dns_record_set" "mqtt_preview" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = "mqtt.preview.${google_dns_managed_zone.gke_trakrf_id.dns_name}"
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.mqtt_preview.address]
}

resource "google_dns_record_set" "mqtt_prod" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = "mqtt.prod.${google_dns_managed_zone.gke_trakrf_id.dns_name}"
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.mqtt_prod.address]
}

# Per-env backend A records. The `*.gke.trakrf.id` wildcard is single-label
# (RFC 4592) so it covers `mqtt.gke.trakrf.id` etc. but not two-label hosts
# like `app.preview.gke.trakrf.id`. Explicit records bridge the gap. Same
# Traefik LB IP as the apex/wildcard — IngressRoute Host matching does the
# per-env routing.
resource "google_dns_record_set" "app_preview_gke" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = "app.preview.${google_dns_managed_zone.gke_trakrf_id.dns_name}"
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.traefik.address]
}
