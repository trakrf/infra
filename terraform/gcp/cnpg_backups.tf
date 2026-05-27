# Phase 1 logical backups for the trakrf-db CNPG cluster.
# Per-env pg_dump CronJobs in trakrf-system upload to this bucket via
# Workload Identity. Retention is enforced here (lifecycle rule), not in
# the CronJob — the CronJob just appends.
#
# Blast radius: the GSA gets objectAdmin scoped to this bucket only; no
# project-level grants. Mirrors the pattern in cert_manager.tf.

resource "google_storage_bucket" "cnpg_backups" {
  name     = "${local.name_prefix}-cnpg-backups-${random_string.suffix.result}"
  location = var.region

  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = false
  }

  lifecycle_rule {
    condition {
      age = 14
    }
    action {
      type = "Delete"
    }
  }

  labels = merge(local.common_labels, { ticket = "tra-798" })
}

resource "google_service_account" "cnpg_backups" {
  account_id   = "cnpg-backups-${var.environment}"
  display_name = "CNPG logical backups (${local.name_prefix})"
  description  = "Used by per-env pg_dump CronJobs in trakrf-system via Workload Identity to write to the CNPG backups bucket."
}

# Bucket-scoped grant — keeps blast radius to this bucket only.
resource "google_storage_bucket_iam_member" "cnpg_backups_object_admin" {
  bucket = google_storage_bucket.cnpg_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cnpg_backups.email}"
}

# Workload Identity: allow the K8s SA trakrf-system/cnpg-backups to
# impersonate this GCP SA. Subject must match the KSA created by
# helm/trakrf-db/templates/backup-serviceaccount.yaml exactly.
resource "google_service_account_iam_member" "cnpg_backups_wi" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-system/cnpg-backups]"
}
