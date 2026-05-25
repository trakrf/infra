output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "zone" {
  description = "GCP zone where the cluster lives"
  value       = var.zone
}

# GKE
output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.main.name
}

output "cluster_endpoint" {
  description = "GKE control-plane endpoint (https://...). For phase 3 helm/k8s provider config."
  value       = google_container_cluster.main.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "GKE cluster CA cert (base64). For phase 3 helm/k8s provider config."
  value       = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "workload_identity_pool" {
  description = "Workload Identity pool — for phase 3 cert-manager SA annotation"
  value       = "${var.project_id}.svc.id.goog"
}

output "kubectl_config_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --zone ${var.zone} --project ${var.project_id}"
}

# DNS
output "dns_zone_name" {
  description = "Cloud DNS zone DNS name (trailing dot stripped for human readability)"
  value       = trimsuffix(google_dns_managed_zone.gke_trakrf_app.dns_name, ".")
}

output "dns_nameservers" {
  description = "Cloud DNS nameservers — consumed by Cloudflare for NS delegation"
  value       = google_dns_managed_zone.gke_trakrf_app.name_servers
}

# TRA-461 — wiring for helm values (cert-manager, Traefik)

output "cert_manager_service_account_email" {
  description = "Email of the cert-manager GCP SA (for the K8s SA iam.gke.io annotation)"
  value       = google_service_account.cert_manager.email
}

output "cloud_dns_zone_name" {
  description = "Cloud DNS managed-zone resource name (distinct from dns_zone_name which is the DNS name). Consumed by cert-manager cloudDNS solver."
  value       = google_dns_managed_zone.gke_trakrf_app.name
}

output "traefik_lb_ip" {
  description = "Static IP reserved for Traefik's LoadBalancer Service — passed as spec.loadBalancerIP"
  value       = google_compute_address.traefik.address
}

# TRA-829 — gke.trakrf.id zone outputs (parallel to dns_zone_name / dns_nameservers /
# cloud_dns_zone_name above for gke.trakrf.app).

output "dns_zone_name_id" {
  description = "Cloud DNS zone DNS name for gke.trakrf.id (trailing dot stripped)"
  value       = trimsuffix(google_dns_managed_zone.gke_trakrf_id.dns_name, ".")
}

output "dns_nameservers_id" {
  description = "Cloud DNS nameservers for gke.trakrf.id — consumed by Cloudflare for NS delegation"
  value       = google_dns_managed_zone.gke_trakrf_id.name_servers
}

output "cloud_dns_zone_name_id" {
  description = "Cloud DNS managed-zone resource name for gke.trakrf.id. Consumed by cert-manager cloudDNS solver."
  value       = google_dns_managed_zone.gke_trakrf_id.name
}

# TRA-828 — per-env MQTT broker static IPs. Consumed by:
#   - terraform/gcp/dns.tf A records for mqtt.{env}.gke.trakrf.id
#   - scripts/apply-root-app.sh -> argocd/root values -> trakrf-ingester per-env LB IP

output "mqtt_preview_ip" {
  description = "Static IP for the preview MQTT LoadBalancer (mqtt.preview.gke.trakrf.id)"
  value       = google_compute_address.mqtt_preview.address
}

output "mqtt_prod_ip" {
  description = "Static IP for the prod MQTT LoadBalancer (mqtt.prod.gke.trakrf.id)"
  value       = google_compute_address.mqtt_prod.address
}
