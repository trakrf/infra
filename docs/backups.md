# Database backups

## What's covered

Two layers, one per-env CNPG cluster each, both writing to the same GCS
bucket:

- **Phase 1 — logical dumps.** Daily `pg_dump` of the env's single
  `trakrf` database. Restore granularity: per env, per day (or whenever
  the last dump ran). Restore depth: 14 days (GCS lifecycle policy).
- **Phase 2 — physical WAL archiving + scheduled base backups.**
  Point-in-time recovery (PITR) anywhere inside the 14-day window,
  scoped to that env's cluster only — preview and prod each have their
  own independent WAL chain and base backups (see Phase 2 section
  below).

**Not** covered:

- Cross-provider/cross-region DR.
- Encryption with customer-managed keys (default Google-managed
  encryption is in use).

## Bucket layout

```
gs://<bucket>/<cluster-name>/dump/YYYY/MM/DD/HHMM.pgdump
```

`<cluster-name>` is `trakrf-db-preview` or `trakrf-db-prod` — the CNPG
Cluster name, not the env name alone.

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
gcloud storage ls "gs://${bucket}/trakrf-db-preview/dump/"
gcloud storage ls "gs://${bucket}/trakrf-db-prod/dump/"
```

## Restoring (verification / scratch)

```sh
just db-restore-test preview
just db-restore-test prod
```

`ENV` is required — there is no default, since this recipe can mutate
the live primary. Against prod it prints what it is about to do and
prompts for typed confirmation (`YES=1` skips the prompt for scripted
runs); preview runs unguarded.

The recipe resolves the backup bucket from the live Cluster's own
`spec.backup.barmanObjectStore.destinationPath` rather than a tofu
output, so it needs no `.env.local` and no initialized R2 backend, and
it reports where the cluster actually writes rather than where docs
say it should. It pulls the latest dump for the named env, restores it
into a scratch database (`trakrf_restore_test_<epoch>`) on that env's
live CNPG primary, prints `\dn` and table row counts from the `trakrf`
schema, then drops the scratch database. A cleanup trap drops the
scratch database even if the run fails partway through, so a mid-run
failure never leaves it behind on the live primary. Safe to run on the
live cluster — no side effects on the real `trakrf` database.

The recipe brackets `pg_restore` with `SELECT timescaledb_pre_restore()`
and `SELECT timescaledb_post_restore()` per the Timescale logical-restore
procedure — without this, pg_restore fails on hypertable foreign-key
constraints. Any manual restore needs the same bracketing.

## Restoring (real)

For a real restore-to-prod scenario:

1. **Stop writers.** Scale the `trakrf-backend` Deployment to 0 in the
   affected namespace (it runs the MQTT ingestion subscriber). The
   `trakrf-mosquitto` broker is not a DB writer and can stay up.
2. **Identify the dump.** Pick the target object in
   `gs://<bucket>/trakrf-db-<env>/dump/`.
3. **Restore into a parallel database** (e.g. `trakrf_restore`), not on
   top of the live `trakrf` database — use the recipe above as a
   template for the `kubectl exec ... pg_restore` invocation, but skip
   the drop step.
4. **Rename databases** when the restored DB looks correct: `ALTER
   DATABASE <live> RENAME TO <live>_old; ALTER DATABASE <restore>
   RENAME TO <live>;`.
5. **Restart writers** and verify.

This is intentionally not a one-button recipe — a real restore should
be a deliberate, supervised operation.

## How it works

- `helm/trakrf-db/templates/backup-cronjob.yaml` renders one
  `batch/v1 CronJob` per `trakrf-db` helm release, running in that
  release's own namespace (`trakrf-preview` or `trakrf-prod` — one per
  env cluster, not a shared `trakrf-system` job). Two containers: an
  init container with the CNPG postgres image runs
  `pg_dump -Fc -Z 6 -f /dump/dump.pgdump`; the main container
  (curlimages/curl) uploads the file to GCS via the JSON API's simple
  media upload, authenticating with an OAuth access token fetched from
  the GKE metadata server. EmptyDir volume between them. We use curl
  rather than the gcloud CLI because Google does not publish a
  multi-arch `google/cloud-sdk` image, and the GKE primary node pool
  here is ARM64.
- The CronJob pod runs as the `cnpg-backups` ServiceAccount in that same
  per-env namespace
  (`helm/trakrf-db/templates/backup-serviceaccount.yaml`), annotated with
  the GCP SA. GKE Workload Identity federates a short-lived token at
  request time.
- The GCP SA has `roles/storage.objectAdmin` on this one bucket only.
  See `terraform/gcp/cnpg_backups.tf`.

## Physical backups + PITR (Phase 2)

In addition to the daily per-env `pg_dump` (Phase 1, above), each env's
CNPG cluster runs continuous WAL archiving + a daily base backup to its
own prefix in the same GCS bucket. Together these give point-in-time
recovery (PITR) anywhere inside the retention window, scoped to that
one cluster.

**Granularity:** physical PITR is per-Cluster, and since preview and
prod are now separate clusters (`trakrf-db-preview`, `trakrf-db-prod`),
that means per-env — recovering preview never touches prod's WAL chain
or base backups, and vice versa. This replaces the older shared-cluster
topology, where a single CNPG cluster held both env databases and PITR
could not recover one without dragging the other along.

> **Deprecation note.** The in-tree `barmanObjectStore` used here is
> deprecated in CNPG 1.26 and scheduled for removal in **CNPG 1.30**.
> When 1.30 ships, this chart will need to migrate to the
> `plugin-barman-cloud` CNPG-i model (separate operator, `ObjectStore`
> CR). The bucket, GSA, and Workload Identity bindings all carry over
> unchanged.

### Layout

```
gs://<bucket>/
├── trakrf-db-preview/
│   ├── dump/YYYY/MM/DD/HHMM.pgdump    ← Phase 1 (logical)
│   ├── base/<basebackup-id>/{data.tar.gz,backup.info}   ← Phase 2 (physical)
│   └── wals/<timeline>/<segment>.gz
└── trakrf-db-prod/
    ├── dump/YYYY/MM/DD/HHMM.pgdump
    ├── base/<basebackup-id>/{data.tar.gz,backup.info}
    └── wals/<timeline>/<segment>.gz
```

Each env's Phase 1 and Phase 2 artifacts live under that env's own
`trakrf-db-<env>/` prefix — there is no shared cluster-level prefix
anymore.

### Schedule + retention

- Continuous WAL archiving: always on while each cluster is up
- Scheduled base backup: daily at `30 9 * * *` UTC in both clusters
  (30 min staggered from the Phase 1 pg_dump)
- Retention: 14 days, CNPG-managed per cluster
  (`spec.backup.retentionPolicy: 14d`). Base backups + their WAL chain
  are deleted atomically once outside the window — do **not** add a
  GCS lifecycle rule to either `trakrf-db-<env>/base/` or
  `trakrf-db-<env>/wals/` prefix; it would orphan WAL segments and
  break PITR. The Phase 1 GCS lifecycle rule is scoped to the
  `trakrf-db-preview/dump/` and `trakrf-db-prod/dump/` prefixes only,
  for this reason (see `terraform/gcp/cnpg_backups.tf`; it also still
  lists the legacy `trakrf-db/dump/`, `preview/`, and `prod/` prefixes
  so any leftover objects from the old shared-cluster topology keep
  aging out).

### Workload Identity

Each env's CNPG Cluster pod ServiceAccount — `trakrf-preview/trakrf-db-preview`
and `trakrf-prod/trakrf-db-prod`, both named after their Cluster — and
the fixed-name scratch SA used by the PITR restore recipe
(`trakrf-system/trakrf-restore-test`) all impersonate the shared
`cnpg-backups-demo` GSA via Workload Identity. The GSA has
bucket-scoped `roles/storage.objectAdmin` + `roles/storage.legacyBucketReader`
(barman calls `GET /b/<bucket>?fields=name` to verify the bucket
exists; objectAdmin alone is insufficient for that metadata read). The
scratch SA stays in `trakrf-system` — not per-env — because it's a
throwaway PITR-proof cluster (see below) whose WI binding in
`terraform/gcp/cnpg_backups.tf` is a static, reusable fixture keyed on
that exact name and namespace.

### Inspecting state

```bash
# Cluster condition (look for ContinuousArchiving=True):
kubectl -n trakrf-preview describe cluster trakrf-db-preview | grep -A 5 ContinuousArchiving
kubectl -n trakrf-prod describe cluster trakrf-db-prod | grep -A 5 ContinuousArchiving

# Scheduled + completed backups:
kubectl -n trakrf-<env> get scheduledbackup
kubectl -n trakrf-<env> get backup --sort-by=.status.startedAt

# What's in GCS:
bucket=$(tofu -chdir=terraform/gcp output -raw cnpg_backup_bucket)
gcloud storage ls "gs://${bucket}/trakrf-db-<env>/base/"
gcloud storage ls -r "gs://${bucket}/trakrf-db-<env>/wals/" | head
```

`just db-status <env>` (see [ops.md](ops.md)) covers the common
"is the cluster healthy" case — reach for the raw commands above when
you specifically need `ContinuousArchiving`, `scheduledbackup`, or the
`backup` CR history that `db-status` doesn't print.

### Force a base backup (ad-hoc)

```bash
just db-pitr-trigger-base preview
just db-pitr-trigger-base prod       # prompts

kubectl -n trakrf-<env> get backup -w
```

`ENV` is required; against prod it prompts for confirmation before
submitting the `Backup` CR (`YES=1` skips it).

**A base backup is not fast.** A manual trigger on this cluster took
**~18 minutes** to reach `completed` — the same-day scheduled backup
for the same dataset took about as long. `phase: running` with WAL
archiving still active is healthy, not stalled; don't bail early
assuming something is stuck. Budget 15–20+ minutes depending on
dataset size before treating a `running` backup as a problem.

### Restore-proof recipe

```bash
# Recover to latest available WAL:
just db-restore-pitr-test preview
just db-restore-pitr-test prod

# Recover to a specific point in time (RFC3339 UTC):
just db-restore-pitr-test prod "2026-05-27T10:30:00Z"
```

`ENV` is required; `TARGET_TIME` is optional and defaults to latest
available WAL. This recipe does **not** touch the live cluster — it
only reads that env's object store — so it runs unguarded even against
prod, with no confirmation prompt.

The recipe spins up a scratch Cluster always named `trakrf-restore-test`
in `trakrf-system` (recovering from whichever env's object store you
named), runs `\l` + per-DB rowcount checks against the single `trakrf`
database, and tears the scratch cluster down. A cleanup trap deletes
the scratch cluster even if the run fails partway, so a failed attempt
doesn't leak it. It also pre-deletes any leftover scratch cluster from
a previous run before applying a new one, so it's safe to re-run.
WI for the scratch SA is preconfigured in
`terraform/gcp/cnpg_backups.tf`. To inspect the recovered cluster
before teardown, comment out the final `kubectl delete cluster` line
in the recipe.

### Real-recovery procedure (manual)

When recovering for real (not just verifying), don't use the
restore-test recipe — its scratch cluster gets torn down at the end.
Instead:

1. **Stop writers.** Scale the `trakrf-backend` Deployment in the
   affected env's namespace (`trakrf-preview` or `trakrf-prod`) to zero
   so no new writes land in the failed cluster.
2. **Decide your recovery target time** (if any). For corruption
   recovery, pick a timestamp just before the bad event.
3. **Add a WI binding** in `terraform/gcp/cnpg_backups.tf` for the
   recovery cluster's pod SA (CNPG names the SA after the Cluster).
   Apply with `just gcp`. Skip this step only if you're reusing the
   affected cluster's existing name (e.g. `trakrf-db-prod`) and the old
   cluster is fully gone.
4. **Apply a recovery Cluster manifest.** Model on the one rendered by
   `just db-restore-pitr-test`. Use a permanent name like
   `trakrf-db-<env>-recovered`, set `instances: 1`, and DO NOT delete it.
5. **Verify recovered data** with `\l` + table rowcount checks against
   the single `trakrf` database.
6. **Cut traffic over.** Either rename the recovered cluster (delete
   the old one first, then re-apply the recovered manifest with the
   affected cluster's original name, e.g. `trakrf-db-prod`), or repoint
   downstream DSNs from `trakrf-db-<env>-rw` to
   `trakrf-db-<env>-recovered-rw`.
7. **Write up the incident.** Capture which target time was used and
   why.

This is intentionally manual — real DR scenarios benefit from human
pause points and visibility into each step.
