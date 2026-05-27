# Logical migration runbook — TimescaleDB Cloud → CNPG

> Used by the preview-half rebuild and re-used verbatim by the prod-half
> rebuild. Substitute `<env>` placeholders throughout: `preview` for the
> preview-half, `prod` for the prod-half.

## Preconditions

- kubectl context points at the target GKE cluster.
- `gcloud auth login --update-adc` recently (so `gcloud storage` works for
  the row-count snapshot and the GCS-side checks).
- TSC psql endpoint reachable from the kubectl host (port 5432 TLS); creds
  for the TSC migration source role in `.env.local` (or equivalent).
- New CNPG Cluster `trakrf-db-<env>` Ready in namespace `trakrf-<env>`.
- Platform FDW pull script available (trakrf/platform PR #413, branch /
  `cutover/<env>-fdw-pull.sql`).
- Application Apps (`trakrf-backend-<env>`, `trakrf-ingester-<env>`) are
  scaled down or already CrashLoopBackOff (post-DSN-flip, pre-data).

## Steps

### 1. Snapshot source row counts

From a host that can reach TSC:

```bash
psql "${TSC_<ENV>_DSN}" -c "
  SELECT relname, n_live_tup
  FROM pg_stat_user_tables
  WHERE schemaname='trakrf'
  ORDER BY relname;
" > /tmp/migration-source-counts.txt
```

Keep `/tmp/migration-source-counts.txt` for the post-pull diff.

### 2. Schema bootstrap via the trakrf-backend migrate Job

The existing migrate Job pattern runs as the migrate role and applies the
golang-migrate set to the new DB. It's already part of the trakrf-backend
chart; trigger it manually:

```bash
kubectl -n trakrf-<env> create job migrate-bootstrap \
  --from=cronjob/trakrf-backend-migrate \
  || kubectl -n trakrf-<env> rollout restart deploy/trakrf-backend  # if migrate is a deploy-init pattern
```

Confirm completion:

```bash
kubectl -n trakrf-<env> get jobs
kubectl -n trakrf-<env> logs job/migrate-bootstrap
```

Expected: Job Complete, all migrations applied, `\dn` shows `trakrf` schema
present in the new DB.

### 3. Enable FDW

The FDW pull needs superuser. Pull the CNPG-managed superuser secret for
the target Cluster:

```bash
SUPER_PW=$(kubectl -n trakrf-<env> get secret trakrf-db-<env>-superuser \
  -o jsonpath='{.data.password}' | base64 -d)
```

Run the FDW setup SQL against the new Cluster's external LB endpoint
(`db.preview.gke.trakrf.id` for preview; equivalent for prod when added):

```bash
PGPASSWORD="$SUPER_PW" psql \
  "host=db.<env>.gke.trakrf.id user=postgres dbname=trakrf_<env> \
   sslmode=verify-ca sslrootcert=/tmp/trakrf-db-<env>-ca.crt" \
  -f <(curl -fsSL https://raw.githubusercontent.com/trakrf/platform/<sha>/cutover/<env>-fdw-pull.sql)
```

(See trakrf/platform PR #413 for the latest SQL.)

The script performs:
- `CREATE EXTENSION postgres_fdw`
- `CREATE SERVER tsc_source`
- `CREATE USER MAPPING FOR postgres SERVER tsc_source ...`
- `IMPORT FOREIGN SCHEMA trakrf FROM SERVER tsc_source INTO trakrf_remote`
- Per-table `INSERT INTO trakrf.<table> SELECT * FROM trakrf_remote.<table>`
  in FK-respecting order
- For Timescale hypertables, bracket with
  `SELECT timescaledb_pre_restore(); ... SELECT timescaledb_post_restore();`
  (per `feedback_timescale_logical_restore_bracket`)

### 4. Sanity check

```bash
kubectl -n trakrf-<env> exec deploy/trakrf-db-<env>-1 -- \
  psql -U postgres -d trakrf_<env> -c "
    SELECT relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname='trakrf'
    ORDER BY relname;
  " > /tmp/migration-target-counts.txt
diff /tmp/migration-source-counts.txt /tmp/migration-target-counts.txt
```

Expected: empty diff (or only differences in tables intentionally not
migrated).

### 5. Tear down FDW

```bash
PGPASSWORD="$SUPER_PW" psql \
  "host=db.<env>.gke.trakrf.id user=postgres dbname=trakrf_<env> \
   sslmode=verify-ca sslrootcert=/tmp/trakrf-db-<env>-ca.crt" -c "
  DROP USER MAPPING IF EXISTS FOR postgres SERVER tsc_source;
  DROP SERVER IF EXISTS tsc_source;
  DROP SCHEMA IF EXISTS trakrf_remote CASCADE;
  DROP EXTENSION IF EXISTS postgres_fdw;
"
```

### 6. Bring apps back online

Argo will auto-reconcile, but a manual restart accelerates the recovery
from CrashLoopBackOff:

```bash
kubectl -n trakrf-<env> rollout restart deploy/trakrf-backend
kubectl -n trakrf-<env> rollout restart deploy/trakrf-ingester
kubectl -n trakrf-<env> get pods -w
```

Expected: backend Ready, `/healthz` returns 200 via port-forward.

### 7. Negative-auth test

Confirm the env's app role cannot reach the other env's DB:

```bash
PW=$(kubectl -n trakrf-<env> get secret trakrf-app-<env>-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
# For preview: target = trakrf_prod on shared Cluster.
# For prod: target = trakrf_preview on the new preview Cluster (or its
# remnant if reachable).
kubectl run --rm -it psql-neg -n trakrf-<env> --restart=Never --image=postgres:17 \
  --env=PGPASSWORD="$PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app-<env> -d trakrf_<other-env> -c "SELECT 1;"
```

Expected: connection / authentication failure.

### 8. Drop source-env objects from the previous Cluster (preview-half only)

On the shared Cluster `trakrf-db` in `trakrf-system`:

```bash
kubectl -n trakrf-system exec trakrf-db-1 -- \
  psql -U postgres -c '
    DROP DATABASE trakrf_<env>;
    DROP ROLE "trakrf-app-<env>";
    DROP ROLE "trakrf-migrate-<env>";
  '
kubectl -n trakrf-system delete secret \
  trakrf-app-<env>-credentials \
  trakrf-migrate-<env>-credentials \
  --ignore-not-found
```

(For the prod-half, the equivalent step is "destroy the shared Cluster
entirely" once prod has cut over to its dedicated Cluster.)

## Rollback

If sanity check (step 4) fails:

1. Drop the partial data: `psql ... -c "TRUNCATE trakrf.<table> CASCADE;"`
   for the tables that imported.
2. Investigate the failed table — usually a FK ordering issue or a
   trigger needing EXECUTE grants that the init-grants Job did not apply.
3. Re-run the pull SQL (idempotent on TRUNCATE + INSERT pattern).

The apps stay pointed at the new Cluster (the chart change has merged).
If recovery exceeds the disruption budget, point apps back at the old
shared Cluster by reverting the DSN flip commit on the branch (a
one-line edit in `argocd/root/templates/trakrf-backend.yaml` +
`trakrf-ingester.yaml`).
