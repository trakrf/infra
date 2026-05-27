# Database backups

## What's covered

Two layers on the shared CNPG cluster, both writing to the same GCS
bucket:

- **Phase 1 — logical per-DB dumps.** Daily `pg_dump` of every env
  database. Restore granularity: per env database, per day (or whenever
  the last dump ran). Restore depth: 14 days (GCS lifecycle policy).
- **Phase 2 — physical WAL archiving + scheduled base backups.**
  Whole-cluster point-in-time recovery (PITR) anywhere inside the
  14-day window. Granularity is the whole Cluster — physical PITR
  cannot recover one env database without the other (see Phase 2
  section below).

**Not** covered:

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

The recipe brackets `pg_restore` with `SELECT timescaledb_pre_restore()`
and `SELECT timescaledb_post_restore()` per the Timescale logical-restore
procedure — without this, pg_restore fails on hypertable foreign-key
constraints. Any manual restore needs the same bracketing.

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
  the main container (curlimages/curl) uploads the file to GCS via the
  JSON API's simple media upload, authenticating with an OAuth access
  token fetched from the GKE metadata server. EmptyDir volume between
  them. We use curl rather than the gcloud CLI because Google does not
  publish a multi-arch `google/cloud-sdk` image, and the GKE primary
  node pool here is ARM64.
- The CronJob pod runs as the `cnpg-backups` ServiceAccount in the
  `trakrf-system` namespace
  (`helm/trakrf-db/templates/backup-serviceaccount.yaml`), annotated with
  the GCP SA. GKE Workload Identity federates a short-lived token at
  request time.
- The GCP SA has `roles/storage.objectAdmin` on this one bucket only.
  See `terraform/gcp/cnpg_backups.tf`.

## Physical backups + PITR (Phase 2)

In addition to the daily per-env `pg_dump` (Phase 1, above), the CNPG
cluster runs continuous WAL archiving + a daily base backup to the same
GCS bucket. Together these give whole-cluster point-in-time recovery
(PITR) anywhere inside the retention window.

**Granularity caveat:** physical PITR is **whole-Cluster**. You cannot
point-in-time restore one env's database without dragging the other
along — that is the explicit tradeoff of consolidating preview + prod
on a single CNPG. Per-env granularity stays with the Phase 1 logical
dumps.

> **Deprecation note.** The in-tree `barmanObjectStore` used here is
> deprecated in CNPG 1.26 and scheduled for removal in **CNPG 1.30**.
> When 1.30 ships, this chart will need to migrate to the
> `plugin-barman-cloud` CNPG-i model (separate operator, `ObjectStore`
> CR). The bucket, GSA, and Workload Identity bindings all carry over
> unchanged.

### Layout

```
gs://<bucket>/
├── preview/YYYY/MM/DD/HHMM.pgdump    ← Phase 1 (per-env logical)
├── prod/YYYY/MM/DD/HHMM.pgdump
└── trakrf-db/                         ← Phase 2 (whole-cluster physical)
    ├── base/<basebackup-id>/{data.tar.gz,backup.info}
    └── wals/<timeline>/<segment>.gz
```

### Schedule + retention

- Continuous WAL archiving: always on while the cluster is up
- Scheduled base backup: daily at `30 9 * * *` UTC (30 min staggered
  from the Phase 1 pg_dump)
- Retention: 14 days, CNPG-managed
  (`spec.backup.retentionPolicy: 14d`). Base backups + their WAL chain
  are deleted atomically once outside the window — do **not** add a
  GCS lifecycle rule to the `trakrf-db/` prefix; it would orphan WAL
  segments and break PITR. The Phase 1 GCS lifecycle rule is scoped to
  `preview/` and `prod/` prefixes only for this reason.

### Workload Identity

The CNPG cluster's pod ServiceAccount (`trakrf-system/trakrf-db`, named
after the Cluster) and the fixed-name scratch SA used by the restore
recipe (`trakrf-system/trakrf-restore-test`) both impersonate the
shared `cnpg-backups-demo` GSA via Workload Identity. The GSA has
bucket-scoped `roles/storage.objectAdmin` + `roles/storage.legacyBucketReader`
(barman calls `GET /b/<bucket>?fields=name` to verify the bucket
exists; objectAdmin alone is insufficient for that metadata read).

### Inspecting state

```bash
# Cluster condition (look for ContinuousArchiving=True):
kubectl -n trakrf-system describe cluster trakrf-db | grep -A 5 ContinuousArchiving

# Scheduled + completed backups:
kubectl -n trakrf-system get scheduledbackup
kubectl -n trakrf-system get backup --sort-by=.status.startedAt

# What's in GCS:
bucket=$(tofu -chdir=terraform/gcp output -raw cnpg_backup_bucket)
gcloud storage ls "gs://${bucket}/trakrf-db/base/"
gcloud storage ls -r "gs://${bucket}/trakrf-db/wals/" | head
```

### Force a base backup (ad-hoc)

```bash
just db-pitr-trigger-base
kubectl -n trakrf-system get backup -w
```

### Restore-proof recipe

```bash
# Recover to latest available WAL:
just db-restore-pitr-test

# Recover to a specific point in time (RFC3339 UTC):
just db-restore-pitr-test "2026-05-27T10:30:00Z"
```

The recipe spins up a scratch Cluster named `trakrf-restore-test` in
`trakrf-system`, runs `\l` + per-DB rowcount checks, and tears it down.
WI for the scratch SA is preconfigured in
`terraform/gcp/cnpg_backups.tf`. To inspect the recovered cluster
before teardown, comment out the final `kubectl delete cluster` line
in the recipe.

### Real-recovery procedure (manual)

When recovering for real (not just verifying), don't use the
restore-test recipe — its scratch cluster gets torn down at the end.
Instead:

1. **Stop writers.** Scale the trakrf-backend Deployments to zero so
   no new writes land in the failed cluster.
2. **Decide your recovery target time** (if any). For corruption
   recovery, pick a timestamp just before the bad event.
3. **Add a WI binding** in `terraform/gcp/cnpg_backups.tf` for the
   recovery cluster's pod SA (CNPG names the SA after the Cluster).
   Apply with `just gcp`. Skip this step only if you're reusing the
   `trakrf-db` name and the old cluster is fully gone.
4. **Apply a recovery Cluster manifest.** Model on the one rendered by
   `just db-restore-pitr-test`. Use a permanent name like
   `trakrf-db-recovered`, set `instances: 1`, and DO NOT delete it.
5. **Verify recovered data** with `\l` + table rowcount checks.
6. **Cut traffic over.** Either rename the recovered cluster (delete
   the old one first, then re-apply the recovered manifest with name
   `trakrf-db`), or repoint downstream DSNs from `trakrf-db-rw` to
   `trakrf-db-recovered-rw`.
7. **Write up the incident.** Capture which target time was used and
   why.

This is intentionally manual — real DR scenarios benefit from human
pause points and visibility into each step.
