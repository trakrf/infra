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
