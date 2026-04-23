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
