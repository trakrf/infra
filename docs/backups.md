# Database backups

## What's covered

Daily logical `pg_dump` of every env database on the shared CNPG cluster
to GCS. Restore granularity: per env database, per day (or whenever the
last dump ran). Restore depth: 14 days (GCS lifecycle policy).

**Not** covered (yet):

- Continuous WAL archiving or point-in-time recovery (PITR). Tracked
  separately as Phase 2 of the same effort.
- Cross-provider/cross-region DR.
- Encryption with customer-managed keys (default Google-managed
  encryption is in use).

## Bucket layout

```
gs://<bucket>/<env>/YYYY/MM/DD/HHMM.pgdump
```

Bucket name is created by Terraform and not stable across rebuilds.
Fetch it any time:

```sh
tofu -chdir=terraform/gcp output -raw cnpg_backup_bucket
```

## Schedule + retention

- Schedule: `0 9 * * *` UTC (daily 09:00 UTC). Configurable per cluster
  overlay via `backups.schedule` in `helm/trakrf-db/values-<cluster>.yaml`.
- Retention: 14 days. Enforced by the bucket's lifecycle rule in
  `terraform/gcp/cnpg_backups.tf`. The `backups.retentionDays` value in
  the chart is documentation only — changing it does not change retention.

## Listing dumps

```sh
bucket=$(tofu -chdir=terraform/gcp output -raw cnpg_backup_bucket)
gcloud storage ls "gs://${bucket}/preview/"
gcloud storage ls "gs://${bucket}/prod/"
```

## Restoring (verification / scratch)

```sh
just db-restore-test           # preview by default
just db-restore-test prod
```

This recipe pulls the latest dump for the named env, restores it into a
scratch database (`trakrf_restore_test_<epoch>`) on the live CNPG
primary, prints `\dn` and table row counts from the `trakrf` schema,
then drops the scratch database. Safe to run on the live cluster — no
side effects on the env databases.

## Restoring (real)

For a real restore-to-prod scenario:

1. **Stop writers.** Scale `trakrf-backend` and `trakrf-ingester`
   Deployments to 0 in the affected namespace.
2. **Identify the dump.** Pick the target object in
   `gs://<bucket>/<env>/`.
3. **Restore into a parallel database** (e.g. `trakrf_<env>_restore`),
   not on top of the live database — use the recipe above as a template
   for the `kubectl exec ... pg_restore` invocation, but skip the drop
   step.
4. **Rename databases** when the restored DB looks correct: `ALTER
   DATABASE <live> RENAME TO <live>_old; ALTER DATABASE <restore>
   RENAME TO <live>;`.
5. **Restart writers** and verify.

This is intentionally not a one-button recipe — a real restore should
be a deliberate, supervised operation.

## How it works

- `helm/trakrf-db/templates/backup-cronjob.yaml` renders one
  `batch/v1 CronJob` per env database. Two containers: an init container
  with the CNPG postgres image runs `pg_dump -Fc -Z 6 -f /dump/dump.pgdump`;
  the main container with `google/cloud-sdk:slim` uploads the file with
  `gcloud storage cp`. EmptyDir volume between them.
- The CronJob pod runs as the `cnpg-backups` ServiceAccount in the
  `trakrf-system` namespace
  (`helm/trakrf-db/templates/backup-serviceaccount.yaml`), annotated with
  the GCP SA. GKE Workload Identity federates a short-lived token at
  request time.
- The GCP SA has `roles/storage.objectAdmin` on this one bucket only.
  See `terraform/gcp/cnpg_backups.tf`.
