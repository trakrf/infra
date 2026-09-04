# Logical migration runbook — TimescaleDB Cloud → CNPG

> Source-agnostic shape: substitute `<env>` placeholders (`preview` / `prod`)
> for the K8s namespace and Cluster name. The DB, roles, and Secrets are
> unsuffixed (`trakrf`, `trakrf-app`, `trakrf-migrate`, `trakrf-{app,migrate}-credentials`)
> — they have the same names in every Cluster.
>
> The procedure here is **TSC → CNPG** specifically. For a future
> CNPG → CNPG cutover (prod-half if TRA-375 lands on the shared Cluster
> before the prod-half ticket), the schema bootstrap + FDW source SQL
> differ; this runbook can be adapted but is not drop-in.

## Preconditions

- kubectl context points at the target GKE cluster.
- `gcloud auth login --update-adc` recently (so `gcloud storage` works for
  the row-count snapshot and the GCS-side checks).
- TSC psql endpoint reachable from the kubectl host (port 5432 TLS); creds
  for the TSC migration source role in `.env.local` (or equivalent).
- New CNPG Cluster `trakrf-db-<env>` Ready in namespace `trakrf-<env>`.
- Platform FDW pull script available (trakrf/platform PR #413,
  `cutover/<env>-fdw-pull.sql` or equivalent on a current branch).
- Application Applications (`trakrf-backend-<env>`)
  are scaled down or already CrashLoopBackOff (post-DSN-flip, pre-data).

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

> **CRITICAL — bootstrap with the CUTOVER image, never the old default.**
> The migrate Job's golang-migrate lineage is baked into the backend image.
> The post-TRA-720 "clean stack" is versions 000001–000011; the legacy
> lineage went to v44. If the Cluster is first bootstrapped by an older image
> (e.g. a stale `image.tag` default in `values-gke.yaml`), `schema_migrations`
> records v44 and the cutover image's migrate **cannot reconcile it**
> (`no migration found for version 44`), blocking the ArgoCD sync. Pin
> `envs.<env>.imageTag` to the cutover image BEFORE the Cluster's first
> migrate. Correct order: cluster up → migrate (cutover image) → init-grants
> → FDW pull. (TRA-850 dry-run caught this: prod was bootstrapped on the old
> default while the target image carried the renumbered lineage.)
>
> **Recovering a wrong-lineage Cluster** (only if already bootstrapped on the
> wrong image — non-destructive to real data, which is re-pullable from source):
> ```bash
> kubectl -n trakrf-<env> exec <cluster>-1 -c postgres -- psql -U postgres -d trakrf \
>   -c "DROP SCHEMA IF EXISTS trakrf CASCADE" \
>   -c "DROP TABLE IF EXISTS public.schema_migrations"   # lives in public when search_path=public,trakrf
> ```
> Then force an ArgoCD sync so migrate re-bootstraps clean, re-run init-grants
> (step 2a), then re-run the FDW pull. `app.obfuscation_key` is ALTER DATABASE
> -scoped and SURVIVES the schema drop — `SHOW app.obfuscation_key` to confirm
> rather than blindly re-applying.

The existing migrate Job runs as the migrate role and applies the
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

### 2a. Re-grant the app/migrate roles (REQUIRED before the FDW pull)

The migrate set contains **no** `GRANT` / `ALTER DEFAULT PRIVILEGES` — DB role
grants are external (the `init-grants` Job in the `trakrf-db` chart). `migrate`
creates objects owned by `trakrf-migrate`; without this step `trakrf-app` has
no privileges and the backend fails at **runtime**, not at migrate (easy to
misdiagnose — `/readyz` is shallow and still returns `ok`). The init-grants SQL
is idempotent and does retroactive `GRANT ON ALL` + `ALTER DEFAULT PRIVILEGES`.

It also grants `trakrf-app` **read-only** on `trakrf.schema_migrations`, which
the backend's `/health` schema-drift check reads. `GRANT ON ALL TABLES` covers
the ledger only if it already exists when the Job runs, and this chart is not
ordered against the migrate Job that creates it — so check the ledger
separately below, not just a business table. It is the one that goes missing
(TRA-1218), and an unreadable ledger costs a 503 that should have fired, while
`/health` goes on returning 200.

Re-run it by forcing a sync on the `trakrf-db-<env>` Application (it's a Helm
`post-upgrade` hook):

```bash
kubectl -n argocd patch application trakrf-db-<env> --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
# confirm:
kubectl -n trakrf-<env> exec <cluster>-1 -c postgres -- psql -U postgres -d trakrf \
  -At -c "SELECT has_table_privilege('trakrf-app','trakrf.organizations','SELECT')"
# expect: t
# the ledger too — read yes, write no:
kubectl -n trakrf-<env> exec <cluster>-1 -c postgres -- psql -U postgres -d trakrf \
  -At -c "SELECT has_table_privilege('trakrf-app','trakrf.schema_migrations','SELECT'),
                 has_table_privilege('trakrf-app','trakrf.schema_migrations','INSERT')"
# expect: t|f
```

**Gate the FDW pull on real backend health** — bounce the backend and confirm
it serves (not just that grants ran) before step 3, or the pull can hit
partial-permission errors mid-flight:

```bash
kubectl -n trakrf-<env> rollout restart deploy/trakrf-backend
kubectl -n trakrf-<env> rollout status deploy/trakrf-backend
```

### 3. Enable FDW

The FDW pull needs superuser. Pull the CNPG-managed superuser secret for
the target Cluster:

```bash
SUPER_PW=$(kubectl -n trakrf-<env> get secret trakrf-db-<env>-superuser \
  -o jsonpath='{.data.password}' | base64 -d)
```

Run the FDW setup SQL against the new Cluster's external LB endpoint
(`db.preview.gke.trakrf.id` for preview; equivalent host for prod):

```bash
PGPASSWORD="$SUPER_PW" psql \
  "host=db.<env>.gke.trakrf.id user=postgres dbname=trakrf \
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
  psql -U postgres -d trakrf -c "
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
  "host=db.<env>.gke.trakrf.id user=postgres dbname=trakrf \
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
kubectl -n trakrf-<env> get pods -w
```

Expected: backend Ready, `/healthz` returns 200 via port-forward.

### 7. Negative-auth test

Confirm the env's app role cannot reach the other env's Cluster:

```bash
PW=$(kubectl -n trakrf-<env> get secret trakrf-app-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
# For preview: target Cluster = shared trakrf-db in trakrf-system.
# For prod: target Cluster = the new trakrf-db-preview in trakrf-preview
#           (or, post-TRA-850, the other dedicated env Cluster).
kubectl run --rm -it psql-neg -n trakrf-<env> --restart=Never --image=postgres:17 \
  --env=PGPASSWORD="$PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app -d trakrf -c "SELECT 1;"
```

Expected: authentication failure (role + password don't match across
Clusters — each Cluster has its own role passwords).

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
one-line edit in `argocd/root/templates/trakrf-backend.yaml`).
