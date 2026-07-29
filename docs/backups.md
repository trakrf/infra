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
schema, then drops the scratch database. Before dropping it, the recipe
**gates** on those counts: a restore that comes back with zero tables,
or with zero live rows across the whole `trakrf` schema, fails the proof
non-zero instead of reporting a hollow success. The judgement is made on
the schema as a whole, so a legitimately empty individual table (today:
`tag_scans` / `asset_scans`) does not trip it, and a query that cannot
run is reported as `INCONCLUSIVE`, distinct from an empty restore.
A cleanup trap drops the
scratch database even if the run fails partway through, so a mid-run
failure never leaves it behind on the live primary. Safe to run on the
live cluster — no side effects on the real `trakrf` database.

> **Note:** "no side effects on `trakrf`" is not the same as "no side
> effects at all" — restoring the dump into the scratch database is
> real write activity on the live primary, and it is WAL-logged like
> any other write. If you're also going to run `db-restore-pitr-test`
> against the same env, see "Interaction with `db-restore-test`" under
> the restore-proof recipe section below before deciding the order to
> run them in.

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

# Override how long to wait for the scratch cluster to become Ready
# (default 120m — see "Recovery time and the Ready-wait timeout" below):
RESTORE_READY_TIMEOUT=3h just db-restore-pitr-test preview
```

`ENV` is required; `TARGET_TIME` is optional and defaults to latest
available WAL. This recipe does **not** touch the live cluster — it
only reads that env's object store — so it runs unguarded even against
prod, with no confirmation prompt.

#### Recovery time and the Ready-wait timeout

Recovering to latest (no `TARGET_TIME`) replays every WAL segment
written since the source's last base backup, so how long the recipe
waits for the scratch cluster to reach Ready depends entirely on how
much WAL has piled up since then — not on dataset size.

Crucially, that pile-up is **not** driven by steady-state ingestion.
Measured on preview 2026-07-29: steady-state WAL is only **~21 MB per
hour** — and that baseline already includes live MQTT scan ingestion,
ambient tag reads, continuous BLE reads, and the continuous-aggregate
refresh policy. A full day of that is roughly 0.5 GB, which replays
quickly.

What actually inflates it is `just db-restore-test <env>`, which writes
a full logical restore into a scratch database on the live primary.
Each run burst **~1.4–1.7 GB of compressed WAL** on preview. Three runs
in one session left **~5.1 GB** to replay, and that — not elapsed time
— is what exhausted the previous 20m wait. See
[Interaction with db-restore-test](#interaction-with-db-restore-test)
below.

The default wait (`RESTORE_READY_TIMEOUT`, 120m) is therefore sized to
absorb several preceding logical-proof runs plus base-backup fetch and
instance startup, rather than to cover elapsed clock time. Prod's WAL
volume is negligible (15 objects / 5 MB in 13h in the same
measurement) and finishes in a few minutes regardless of this default.

Override the wait with the `RESTORE_READY_TIMEOUT` env var (e.g.
`RESTORE_READY_TIMEOUT=3h`) — not a recipe argument, so it can't
collide with `ENV`/`TARGET_TIME` ordering. A malformed value (not a
duration like `20m`, `90m`, `2h`) is rejected with a warning and falls
back to the default rather than silently becoming a zero or unbounded
wait.

Two ways to make a **preview** proof fast instead of slow-but-honest:

- Run it **before** `just db-restore-test <env>`, not after. Ordering
  matters far more than time of day: steady-state WAL is ~21 MB/hour,
  so waiting for the next scheduled base backup saves little, while
  each preceding logical proof adds ~1.4–1.7 GB to replay.
- Pass a `TARGET_TIME` close to the most recent base backup's
  timestamp. CNPG picks the closest backup completed before that
  target and stops WAL replay at the target, so this bounds replay
  instead of chasing latest — it does not depend on how much WAL has
  piled up since.

Taking a fresh base backup first (`just db-pitr-trigger-base`) is
**not** a shortcut: that recipe itself takes ~18 minutes to complete
(see above), so it costs more time than it saves.

#### Interaction with `db-restore-test`

Running the logical restore-proof (`just db-restore-test <env>`)
before this one, against the *same* env, makes this one slower — the
two are not independent. `db-restore-test` restores a full logical
dump into a scratch database on that env's live primary (see
"Restoring (verification / scratch)" above), and that write activity
is WAL-logged like any other. Recovering to latest here means
replaying every WAL segment written since the last base backup,
including whatever `db-restore-test` just generated — so a
`db-restore-test` run immediately beforehand directly inflates the
wait measured above.

Measured on preview (2026-07-29): steady-state WAL at rest runs around
**~21 MB/hour** — this baseline already includes live MQTT scan
ingestion, ambient tag reads, and the continuous-aggregate refresh
policy, so ordinary ingestion traffic is not what produces the large
bursts described below. A single `db-restore-test preview` run — which
writes roughly 16.8M rows from a ~504 MB compressed dump (expanding to
~6 GB) into the scratch database — produced a burst of roughly
**300–380 WAL objects / ~1.4–1.7 GB compressed** in the surrounding
30-minute window. Three such runs accumulated in one session added up
to ~5.1 GB of extra WAL, which pushed a later `db-restore-pitr-test
preview` past what was then a 20m Ready timeout — the burst, not the
baseline, is what did that.

Prod is unaffected in practice: its logical dump is ~220 KB and its
steady-state WAL is a few MB per day, so a `db-restore-test prod` run
barely moves the needle.

This is inherent to what `db-restore-test` does — it writes real data
to the live primary — not a defect in either recipe. If you intend to
run both proofs against the same env:

- **Prefer running `db-restore-pitr-test` before `db-restore-test`.**
  Reversing the order is the simplest way to keep both proofs fast.
- If `db-restore-test` has to go first, budget extra time for the
  PITR proof afterwards, or raise `RESTORE_READY_TIMEOUT` (see above)
  rather than assuming a slow run has hung.

The recipe spins up a scratch Cluster always named `trakrf-restore-test`
in `trakrf-system` (recovering from whichever env's object store you
named), runs `\l` + per-DB rowcount checks against the single `trakrf`
database, and tears the scratch cluster down. A cleanup trap deletes
the scratch cluster even if the run fails partway, so a failed attempt
doesn't leak it. It also pre-deletes any leftover scratch cluster from
a previous run before applying a new one, so it's safe to re-run.
WI for the scratch SA is preconfigured in
`terraform/gcp/cnpg_backups.tf`.

**To inspect the recovered cluster before teardown**, you must defeat
*both* deletion paths — the success-path teardown and the cleanup trap.
In the `db-restore-pitr-test` recipe, near the end:

```sh
    echo "Tearing down scratch cluster..."
    # kubectl -n "$ns" delete cluster "$scratch" --wait=true   # <- comment out
    scratch_applied=0                                          # <- KEEP this line
```

Commenting out the `kubectl delete` line alone is not enough *unless*
the `scratch_applied=0` line immediately below it still runs — that
assignment is what disarms the EXIT trap. If you comment out the whole
block (or the `scratch_applied=0` line with it), the trap still sees
`scratch_applied=1` and deletes the cluster on normal exit; in that case
also comment out the `trap cleanup EXIT` line further up, immediately
after `scratch_applied=1`.

The cluster then survives the run. Inspect it with
`kubectl -n trakrf-system exec <pod> -- psql -U postgres -d trakrf`, and
clean up by hand afterwards:

```sh
kubectl -n trakrf-system delete cluster trakrf-restore-test
```

(The next `just db-restore-pitr-test` run also pre-deletes it.)

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
