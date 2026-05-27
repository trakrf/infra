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

  # Phase 1 retention: delete pg_dump artifacts > 14d.
  #
  # Path layout: gs://<bucket>/<cluster-name>/dump/YYYY/MM/DD/HHMM.pgdump
  # where <cluster-name> is the CNPG Cluster fullnameOverride (e.g.
  # trakrf-db, trakrf-db-preview). Phase 2 CNPG paths under
  # <cluster-name>/{base,wals}/... are NOT covered — CNPG manages those
  # via spec.backup.retentionPolicy which deletes base + WAL atomically.
  # A blanket age-based rule would orphan WAL segments and break PITR.
  #
  # Legacy "preview/" / "prod/" prefixes from the old multi-env shared
  # cluster also age out, so any dumps still under those paths are
  # cleaned up automatically within 14d.
  lifecycle_rule {
    condition {
      age = 14
      matches_prefix = [
        "trakrf-db/dump/",
        "trakrf-db-preview/dump/",
        "preview/",
        "prod/",
      ]
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

# barman-cloud-wal-archive (Phase 2) calls GET /b/<bucket>?fields=name
# to verify the bucket exists before each upload. objectAdmin grants
# object perms only — not bucket metadata. legacyBucketReader is the
# smallest add: storage.buckets.get + .list, scoped to this bucket. The
# Phase 1 pg_dump path uses object PUTs only and does not need this.
resource "google_storage_bucket_iam_member" "cnpg_backups_bucket_reader" {
  bucket = google_storage_bucket.cnpg_backups.name
  role   = "roles/storage.legacyBucketReader"
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

# Phase 2: the CNPG Cluster pod SA also needs to impersonate this GSA so
# the live cluster can write WAL + base backups to the same bucket. CNPG
# names the pod SA after the Cluster (trakrf-db).
resource "google_service_account_iam_member" "cnpg_backups_wi_cluster" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-system/trakrf-db]"
}

# Phase 2: scratch Cluster used by `just db-restore-pitr-test` is always
# named trakrf-restore-test so this binding is reusable across runs
# without re-applying tofu.
resource "google_service_account_iam_member" "cnpg_backups_wi_restore_test" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-system/trakrf-restore-test]"
}

# CNPG preview Cluster pods (phase-2 WAL archiving + base backups).
# Cluster's pod SA is named after the Cluster (trakrf-db-preview).
resource "google_service_account_iam_member" "cnpg_backups_wi_cluster_preview" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-preview/trakrf-db-preview]"
}

# Preview pg_dump CronJob KSA (phase-1 logical backup).
resource "google_service_account_iam_member" "cnpg_backups_wi_pgdump_preview" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-preview/cnpg-backups]"
}
