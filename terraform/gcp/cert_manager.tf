# GCP service account that cert-manager pods federate into via GKE Workload Identity.
# Scoped to roles/dns.admin on the gke.trakrf.app zone ONLY — the Cloud DNS solver
# needs TXT record create/delete for _acme-challenge.* during DNS-01 validation.
resource "google_service_account" "cert_manager" {
  account_id   = "cert-manager-${var.environment}"
  display_name = "cert-manager DNS-01 solver (${local.name_prefix})"
  description  = "Used by cert-manager pods via Workload Identity to solve ACME DNS-01 on gke.trakrf.app"
}

# Zone-scoped role binding: grants dns.admin ONLY on the gke-trakrf-app managed zone.
# Uses google_dns_managed_zone_iam_member rather than a project-level google_project_iam_member
# so the blast radius stays tight — cert-manager cannot touch other zones or project resources.
resource "google_dns_managed_zone_iam_member" "cert_manager_dns_admin" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.gke_trakrf_app.name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${google_service_account.cert_manager.email}"
}

# Workload Identity binding: grants the Kubernetes SA cert-manager/cert-manager
# the ability to impersonate this GCP SA. Subject must exactly match the actual
# Helm-chart-default cert-manager SA namespace/name.
resource "google_service_account_iam_member" "cert_manager_wi" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[cert-manager/cert-manager]"
}
