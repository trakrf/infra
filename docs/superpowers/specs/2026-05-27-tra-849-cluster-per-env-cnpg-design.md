# Cluster-per-env CNPG — preview half (design)

**Status:** Design
**Date:** 2026-05-27
**Ticket:** TRA-849 (preview half; TRA-850 owns the prod half)
**Supersedes (topology only):** TRA-823 shared-Cluster DB-per-env
**Carries forward unchanged:** TRA-810 logical migration method, TRA-798 Phase-1 dumps, TRA-842 Phase-2 PITR
**Blocks:** TRA-838 (TSC preview decommission 2026-05-31), TRA-850

## Why

The DB-per-env-on-shared-Cluster topology TRA-823 shipped was the right size to prove the tenancy plumbing, but cluster-per-env is the better end state:

- Per-env PITR (the whole-cluster entanglement TRA-798 Phase-1 worked around dissolves).
- Per-env blast radius for provisioning, decommission, and DR drills.
- One uniform "Cluster per environment-or-tenant" pattern that matches the whitelabel direction.

This ticket proves the per-env-Cluster tooling end-to-end on preview before the TRA-375 prod cutover (Saturday 2026-05-30) and before TRA-838 decommissions the TSC preview source (2026-05-31). Preview data has been frozen since 2026-05-26, so a clean rebuild from the live TSC instance via the TRA-810 logical path is the right *dress rehearsal* for the prod cutover — not a CNPG→CNPG copy of the current preview DB.

## End-state topology (post-TRA-849)

```
trakrf-system        Shared `trakrf-db` Cluster — now hosts a single DB
                     called `trakrf` (renamed from trakrf_prod by pre-merge SQL).
                       - Application uses the refactored single-env chart with
                         only fullnameOverride + bucket/gsa overrides (flat names
                         match defaults)
                       - existing PV patched to reclaimPolicy=Retain
                       - reflector continues mirroring trakrf-{app,migrate}-credentials
                         from trakrf-system → trakrf-prod ns (cross-ns unavoidable
                         until prod-half rebuilds prod onto its own Cluster)
                       - Application: automated.prune=false (stateful guardrail)
                       - phase-1 dumps under gs://<bucket>/trakrf-db/dump/
                       - phase-2 base + WAL under gs://<bucket>/trakrf-db/{base,wals}/

trakrf-preview       New dedicated `trakrf-db-preview` Cluster (CNPG), co-located
                       with backend + ingester. No cross-namespace anything.
                       - trakrf DB + trakrf-app / trakrf-migrate roles + their
                         CNPG-referenced Secrets, ALL native in this ns
                       - phase-1 pg_dump CronJob + phase-2 ScheduledBackup
                         under gs://<bucket>/trakrf-db-preview/{dump,base,wals}/
                       - external LoadBalancer Service for FDW dev moves here
                         from trakrf-system; static IP and DNS A record unchanged
                       - PVC on premium-rwo-retain StorageClass
                       - Application: automated.prune=false
                     trakrf-backend-preview (DSN → trakrf-db-preview-rw.trakrf-preview)
                     trakrf-ingester-preview (same DSN)

trakrf-prod          Unchanged in the preview half: backend + ingester read
                       trakrf-{app,migrate}-credentials reflected from
                       trakrf-system; DSN host stays trakrf-db-rw.trakrf-system.
                       Prod-half ticket stands up trakrf-db-prod here and
                       retires the shared Cluster.
```

The new lifecycle invariant the ticket spells out: each per-env Cluster is **its own ArgoCD Application** with `automated.prune: false` and PV `reclaimPolicy: Retain`, so neither an app-release prune nor a namespace teardown can delete the DB or its volumes. Backend + ingester remain on the existing app Applications (`automated.prune: true` is fine — they're stateless).

## Chart approach — fully flat, no `envs:` loop, no env suffix in names

`helm/trakrf-db` is refactored to single-env shape. Every template that today ranges over `.Values.envs` (`cluster.yaml` managed roles, `databases.yaml`, `init-grants-job.yaml`, `backup-cronjob.yaml`) becomes singular. Top-level values are flat AND env-unsuffixed — with cluster-per-env, the namespace and `fullnameOverride` discriminate environments; the DB, role, and Secret names don't need their own env suffix:

```yaml
# values.yaml — single-env defaults
fullnameOverride: trakrf-db        # release overrides per cluster

cluster:
  instances: 1
  imageName: ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18

postgresql:
  sharedPreloadLibraries: [timescaledb]
  parameters:
    timescaledb.license: timescale
    password_encryption: scram-sha-256

# The Postgres database + roles + secrets the chart manages. Names are
# env-unsuffixed because each Cluster only hosts one env — the K8s
# namespace is the env discriminator.
database:
  name: trakrf                      # Postgres DB name
  cnpgName: trakrf                  # CNPG Database CRD k8s name (DNS-1123)

roles:
  app: trakrf-app
  migrate: trakrf-migrate

secrets:
  app: trakrf-app-credentials
  migrate: trakrf-migrate-credentials

storage:
  size: 10Gi
  class: ""                         # required; values-gke.yaml sets premium-rwo-retain

affinity:
  nodeSelector: {}
  tolerations: []

# Phase 1 logical dumps
backups:
  enabled: false
  bucket: ""
  gcpServiceAccountEmail: ""
  schedule: "0 9 * * *"
  retentionDays: 14
  pgDumpImage: ghcr.io/cloudnative-pg/postgresql:17.2
  uploadImage: curlimages/curl:8.10.1
  serviceAccountName: cnpg-backups
  # GCS path layout: gs://<bucket>/<fullnameOverride>/dump/YYYY/MM/DD/HHMM.pgdump
  # Phase 2 physical / PITR paths live alongside under
  # gs://<bucket>/<fullnameOverride>/{base,wals}/...
  cluster:
    enabled: false
    serverName: ""                   # defaults to fullnameOverride in templates
    baseBackupSchedule: "30 9 * * *"
    retentionPolicy: "14d"

initGrantsJob:
  image: ghcr.io/cloudnative-pg/postgresql:17.2
  # PGHOST is derived in-template from {{ .Values.fullnameOverride }}-rw so
  # callers never have to keep cluster name + host in sync.

externalPreview:
  enabled: false
  loadBalancerIP: ""
  sourceRanges: []
```

Template touchpoints:
- `cluster.yaml` — one `managed.roles` block built from `.Values.roles.{app,migrate}` + `.Values.secrets.{app,migrate}`. `bootstrap.initdb.{database,owner}` reads from `.Values.database.name` / `.Values.roles.migrate`.
- `databases.yaml` — one `Database` CR (`metadata.name = .Values.database.cnpgName`, `spec.name = .Values.database.name`, `spec.owner = .Values.roles.migrate`).
- `init-grants-job.yaml` — one Job, parameterized off the flat values; PGHOST defaults to `{{ .Values.fullnameOverride }}-rw`.
- `backup-cronjob.yaml` — one CronJob named simply `pg-dump`. Uploads to `gs://<bucket>/<fullnameOverride>/dump/<ts>.pgdump`. The GCS lifecycle rule's `matches_prefix` is broadened to cover the per-cluster paths (`trakrf-db/dump/`, `trakrf-db-preview/dump/`) plus the legacy `preview/` and `prod/` for transition cleanup.
- `scheduled-backup.yaml` — one ScheduledBackup; `backup.barmanObjectStore.serverName = .Values.backups.cluster.serverName`.
- `external-service-preview.yaml` — selector becomes `cnpg.io/cluster: {{ .Values.fullnameOverride }}`.
- `backup-serviceaccount.yaml` — unchanged shape; lives in the release ns.

Per-release values overlay (passed as `inlineValues` by the root chart):

```yaml
# trakrf-db (shared Cluster, prod-only)
fullnameOverride: trakrf-db
backups: { bucket: <tofu>, gcpServiceAccountEmail: <tofu> }
# serverName defaults to fullnameOverride → trakrf-db
```

```yaml
# trakrf-db-preview (new dedicated preview Cluster)
fullnameOverride: trakrf-db-preview
storage: { createRetainClass: true }
backups: { bucket: <tofu>, gcpServiceAccountEmail: <tofu> }
# serverName defaults to fullnameOverride → trakrf-db-preview
# GKE-only externalPreview block adds enabled/loadBalancerIP/sourceRanges
```

Same chart, both releases. No `envs:` list. No env suffix in DB / role / Secret names. No reflector logic in the chart.

## Stateful guardrails

### Argo Application — `automated.prune: false` for CNPG Clusters

The `trakrf.application` helper currently hardcodes `prune: true`. Parameterize it with an optional `automatedPrune` field (default `true` to preserve current behavior for every other Application). Both `trakrf-db` and `trakrf-db-preview` Applications set it to `false`.

### PV reclaimPolicy: Retain

New StorageClass `premium-rwo-retain` (clone of `premium-rwo` with `reclaimPolicy: Retain`). Lives in `helm/trakrf-db/templates/storageclass-retain.yaml`, gated on `.Values.storage.createRetainClass` (default false; only the new preview release flips it true since the SC is cluster-scoped — adding it from one Application is enough).

> **AppProject permit:** `storage.k8s.io/StorageClass` is cluster-scoped and not currently in `argocd/projects/trakrf.yaml` `clusterResourceWhitelist`. Add it.

For the existing shared Cluster's already-bound PV (provisioned with `reclaimPolicy: Delete`), a one-time `kubectl patch pv <name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'` flips it to Retain without rebinding. Included as a step in the runbook.

### Database CRD reclaim

CNPG 1.29 default `databaseReclaimPolicy: retain` means deleting a `Database` CR leaves the underlying Postgres DB intact. Verified — explicit `spec.databaseReclaimPolicy: retain` in the template anyway, since it's load-bearing for "don't drop on prune."

## Out of scope (deferred to TRA-850)

- Prod onto its own dedicated Cluster (still on shared, env=prod overlay).
- Retiring the shared `trakrf-db` Cluster + its `trakrf-system` namespace footprint.
- Reflector going away entirely (still needed for the prod-on-shared cross-ns case).
- Per-Cluster PITR runbook / DR drill (TRA-842 PITR is whole-Cluster on shared; works for preview-on-dedicated too, just via the new server path).
- Whitelabel dedicated Clusters.
- Renaming the Postgres DB to plain `trakrf` (would force a coordinated platform-repo change; deferred).

## Components

### 1. `helm/trakrf-db/` — chart refactor

| File | Change |
|---|---|
| `values.yaml` | Replace `envs:` list with flat `database` / `roles` / `secrets`; drop `reflectTo`. Add `storage.createRetainClass: false`. |
| `values-gke.yaml` | Set `storage.class: premium-rwo-retain` (instead of `premium-rwo`); leave `backups.enabled: true` + `backups.cluster.enabled: true`. |
| `templates/cluster.yaml` | Range loop removed; single `managed.roles` block keyed off `.Values.roles` + `.Values.secrets`. Bootstrap initdb keyed off `.Values.database.name` + `.Values.roles.migrate`. |
| `templates/databases.yaml` | Single CR. |
| `templates/init-grants-job.yaml` | Single Job. PGHOST derived from `fullnameOverride`. |
| `templates/backup-cronjob.yaml` | Single CronJob. |
| `templates/scheduled-backup.yaml` | `serverName` from flat value. |
| `templates/backup-serviceaccount.yaml` | No structural change. |
| `templates/external-service-preview.yaml` | Selector uses `.Values.fullnameOverride`. |
| `templates/storageclass-retain.yaml` (new) | Cluster-scoped SC, gated on `storage.createRetainClass`. |

### 2. `argocd/root/templates/_helpers.tpl`

Add optional `automatedPrune` parameter to the `trakrf.application` helper (default `true`). Pass through to `syncPolicy.automated.prune`.

### 3. `argocd/root/templates/trakrf-db.yaml` — repurposed for shared = prod-only

Same Application name (`trakrf-db`), same namespace (`trakrf-system`). The `inlineValues` is rebuilt as the flat env=prod overlay (see table above). Pass `automatedPrune: false` into the helper. Keep the existing `ignoreDifferences` block for CNPG operator-managed fields.

The `externalPreview` block currently lives inside this template's GKE-only inline values — that moves to the new `trakrf-db-preview.yaml` (preview is the only consumer).

### 4. `argocd/root/templates/trakrf-db-preview.yaml` — new

New Application `trakrf-db-preview`, namespace `trakrf-preview`, sync wave `0`. Same chart path, env=preview overlay, `automatedPrune: false`. Pulls `dbPreviewIp` + `breakglassSourceCidr` for the external LB.

Wire `storage.createRetainClass: true` here so the SC is created exactly once.

### 5. `argocd/root/templates/trakrf-backend.yaml` + `trakrf-ingester.yaml`

The `range $env := list "preview" "prod"` loop stays. The preview branch's `$base` block changes the `database.host` and `migrate.host` to `trakrf-db-preview-rw.trakrf-preview`. Prod's host is unchanged. Apps still mount Secrets by the same name — for preview the Secret is now natively in-ns (CNPG-managed); for prod still reflector-mirrored from trakrf-system.

### 6. `terraform/gcp/cnpg_backups.tf` — new WI bindings

Two new WI bindings on the existing `cnpg-backups-demo` GSA (preserves the single-GSA, single-bucket, single-IAM-grant pattern from TRA-798 + TRA-842):

```hcl
# CNPG preview Cluster pods (phase-2 WAL archiving + base backups)
resource "google_service_account_iam_member" "cnpg_backups_wi_cluster_preview" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-preview/trakrf-db-preview]"
}

# Per-env pg_dump CronJob KSA (phase-1)
resource "google_service_account_iam_member" "cnpg_backups_wi_pgdump_preview" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-preview/cnpg-backups]"
}
```

`google_storage_bucket.cnpg_backups.lifecycle_rule.matches_prefix` is broadened to cover the new per-cluster paths `trakrf-db/dump/` and `trakrf-db-preview/dump/` plus the legacy `preview/` / `prod/` prefixes so any straggler dumps still age out during transition.

No new tofu outputs; the existing `cnpg_backup_bucket` + `cnpg_backups_service_account_email` already cover both Clusters.

### 7. `justfile` — `db-secrets` reshape

Today's `db-secrets` creates 4 reflector-annotated env-suffixed Secrets in `trakrf-system`. After this PR:

- `trakrf-app-credentials` + `trakrf-migrate-credentials` in `trakrf-preview` (native, no reflector annotations).
- `trakrf-app-credentials` + `trakrf-migrate-credentials` in `trakrf-system` (reflector-annotated to mirror to `trakrf-prod` — cross-ns dissolves when the prod-half ticket co-locates the prod Cluster).

Same K8s Secret names in both env namespaces — disambiguation is by namespace. The `_db-secret ROLE NS REFLECT PW` helper signature drops the old `ENV` parameter; the role's username matches its name exactly (`trakrf-app`, `trakrf-migrate`).

Passwords continue to come from `.env.local` (`TRAKRF_{APP,MIGRATE}_DB_PASSWORD_{PREVIEW,PROD}`) and use `openssl rand -hex` (per `feedback_db_password_alphabet`).

### 8. `argocd/projects/trakrf.yaml`

Add `storage.k8s.io/StorageClass` to `clusterResourceWhitelist`. Without this, the new SC will sync-fail.

## Bootstrap & cutover order (operational)

The chart refactor + new Application + root template changes ship in one PR.
**Nothing on the shared Cluster is sacred pre-merge.** `trakrf_preview` is
throwaway (we re-pull from TSC), `trakrf_prod` is empty until the prod
cutover, and the auto-prune-off + Retain-PV guardrails only become
load-bearing AFTER real data lands on Saturday. So the operational sequence
is the bare minimum: bring up the new preview Cluster cleanly, let Argo
reconcile the shared Cluster to the new chart shape, blow away anything
that refuses to settle.

```
PRE-MERGE
  1. just db-secrets (new shape) creates the flat-named Secrets:
       - trakrf-preview ns: trakrf-{app,migrate}-credentials (native)
       - trakrf-system ns:  trakrf-{app,migrate}-credentials (reflector-annotated)
  2. Snapshot TSC preview row counts for the post-migration diff.

MERGE

POST-MERGE
  3. kubectl apply -f argocd/projects/trakrf.yaml          # StorageClass permit
  4. just gcp                                              # WI bindings + lifecycle prefix
  5. scripts/apply-root-app.sh gke                         # re-render root chart
  6. Watch Argo reconcile. The new trakrf-db-preview Application comes up
     clean. The shared trakrf-db Application reconciles to the new chart
     shape — CNPG manages the role/Database rename in-place IF it can; if
     it gets stuck on role-removal (old role still owns objects), nuke and
     rebuild:
       kubectl -n trakrf-system delete cluster trakrf-db
       kubectl -n trakrf-system delete pvc -l cnpg.io/cluster=trakrf-db
       # Argo recreates a fresh Cluster on next reconcile.
  7. Run docs/db-migration.md end-to-end for <env>=preview.
  8. Verify (Application Synced+Healthy, negative-auth fails, row-count diff
     empty).
```

The PG rename / Secret content surgery I considered for "preserve everything"
is unnecessary while the shared Cluster has no real data. After the Saturday
prod cutover the guardrails on the chart (auto-prune off, PV Retain) come
into play; until then, just rebuild whatever doesn't settle.

### Decision: who owns the credential Secret

Two options for the new preview Cluster's credential Secrets:

- **Option A — `just db-secrets` creates them, CNPG references them.** Mirrors TRA-823 pattern. Predictable, idempotent, password rotation is `just db-secrets` again.
- **Option B — CNPG generates them.** Set `managed.roles[].passwordSecret` to a name and let CNPG create it on first reconcile if missing. Less hand-rolled.

**Recommendation: Option A.** Same pattern as today, keeps the rotation story identical between preview and prod, and means the Secrets exist *before* the Cluster reconciles (CNPG's create-if-missing path has historically been a source of role-stuck-PendingReconciliation surprises — see TRA-823 design notes). The cost is one extra recipe invocation pre-cutover.

## Migration runbook (`docs/db-migration.md`, new)

The AC requires "Migration runbook captured so the prod cutover reuses it verbatim". The doc is the operator-facing companion to this design. It covers:

1. Preconditions checklist (kubectl context, gcloud auth, TSC psql connect, FDW SQL script available).
2. Schema bootstrap: run the trakrf-backend migrate Job against the new Cluster — already wired in the existing chart, just kicked manually.
3. Set up FDW from new Cluster → TSC preview as superuser (`postgres_fdw`, server, user mapping, foreign schema).
4. Pull data (table-by-table COPY through the foreign schema, ordered to respect FKs; for hypertables use the bracketing pattern from `feedback_timescale_logical_restore_bracket` — `timescaledb_pre_restore()` / `_post_restore()`).
5. Row-count + spot-check sanity.
6. Tear down FDW state (drop server + user mapping; superuser secret only needed during the pull window).
7. Negative-auth test SQL (preview role → prod DB on shared Cluster should return error).
8. Drop preview state from shared cluster (the SQL in step 9 above).

For prod cutover (TRA-850), the runbook is re-applied: substitute `prod` everywhere, source = TSC prod instance, target = new `trakrf-db-prod` Cluster in `trakrf-prod` ns.

## Verification (acceptance criteria mapped to checks)

### AC: dedicated trakrf-db-preview Cluster live; per-env Helm release pattern in place
```bash
kubectl -n trakrf-preview get cluster trakrf-db-preview \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# expect: True
argocd app get trakrf-db-preview -o json | jq '.status.sync.status,.status.health.status,.spec.syncPolicy.automated.prune'
# expect: Synced, Healthy, false
```

### AC: backend + ingester co-located in env ns; no cross-namespace mirror
```bash
kubectl -n trakrf-preview get secret trakrf-app-credentials \
  -o jsonpath='{.metadata.annotations}'
# expect: no reflector.* annotations
kubectl -n trakrf-preview get secret trakrf-app-credentials \
  -o jsonpath='{.metadata.ownerReferences}'
# expect: no reflector owner; Secret is just-db-secrets-created (no ownerRef)
```

### AC: Cluster Application has auto-prune off; PVC reclaim Retain
```bash
argocd app get trakrf-db-preview -o jsonpath='{.spec.syncPolicy.automated.prune}'
# expect: false
kubectl get pvc -n trakrf-preview \
  -l cnpg.io/cluster=trakrf-db-preview \
  -o jsonpath='{.items[0].spec.storageClassName}'
# expect: premium-rwo-retain
kubectl get pv $(kubectl get pvc -n trakrf-preview \
  -l cnpg.io/cluster=trakrf-db-preview \
  -o jsonpath='{.items[0].spec.volumeName}') \
  -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# expect: Retain
```

Same checks against the shared Cluster (`trakrf-db`, `trakrf-system`) confirm the prune=false flip and PV patch.

### AC: preview data migrated via the TRA-810 logical path
Compare pre-migration TSC row counts against post-migration new-Cluster row counts per table.

### AC: backend + ingester serve from the dedicated Cluster; negative-auth passes
```bash
kubectl -n trakrf-preview exec deploy/trakrf-backend -- printenv PG_URL
# expect: host=trakrf-db-preview-rw.trakrf-preview ... dbname=trakrf
# Negative-auth (preview app role → shared prod Cluster):
PW=$(kubectl -n trakrf-preview get secret trakrf-app-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl run --rm -it psql-neg -n trakrf-preview --restart=Never --image=postgres:17 \
  --env=PGPASSWORD="$PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app -d trakrf -c "SELECT 1;"
# expect: auth failure (each Cluster has its own role passwords; preview's
#         trakrf-app password does NOT match prod's trakrf-app password)
```

### AC: legacy preview state dropped from old shared Cluster
```bash
kubectl -n trakrf-system exec trakrf-db-1 -- \
  psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='trakrf_preview'"
# expect: 0 rows
kubectl -n trakrf-system exec trakrf-db-1 -- \
  psql -U postgres -c "SELECT 1 FROM pg_roles WHERE rolname IN ('trakrf-app-preview','trakrf-migrate-preview')"
# expect: 0 rows
```

### AC: runbook captured
`docs/db-migration.md` exists and is referenced from the PR description.

## Risks + mitigations

- **Reconcile churn drops something important.** Pre-merge PV reclaim patch is the belt; `automated.prune: false` post-merge is the suspenders. Worst case is a sync error, not data loss.
- **CNPG role-removal pause.** Removing a managed role that owns objects (preview role owns preview tables) → CNPG may flag the role-removal step. We're dropping the DB the role owns in step 9, so the dependency dissolves. If the operator complains *before* step 9, the Application will sit Degraded but neither the DB nor the role is gone.
- **External LB IP migration.** `db.preview.gke.trakrf.id` static IP moves from a Service in trakrf-system to a Service in trakrf-preview. GKE re-attaches the IP on the new Service. Brief downtime on the FDW endpoint; FDW pull runs inside the cluster anyway, so the external endpoint is only needed during dev iteration — not for the actual migration.
- **GCS path stability.** Phase-1 dumps now land under per-cluster paths: `gs://<bucket>/trakrf-db/dump/` (shared) and `gs://<bucket>/trakrf-db-preview/dump/` (new). Lifecycle rule's `matches_prefix` is broadened to cover both, plus the legacy `preview/` and `prod/` prefixes so any straggler dumps still age out within 14 days. Phase-2 base + WAL live alongside under `gs://<bucket>/<cluster>/{base,wals}/` — untouched by the lifecycle rule; CNPG owns retention there.
- **Day-of-disruption budget.** User confirmed up to a day. Preview app outage spans the migration window (likely <1h); FDW pull endpoint blip is seconds.

## Workflow

- Worktree: `.claude/worktrees/miks2u+tra-849-cluster-per-env-cnpg` (created).
- Branch: `miks2u/tra-849-cluster-per-env-cnpg`.
- Memory: `feedback_use_worktrees_for_long_branches`, `feedback_never_merge_to_main`, `feedback_no_ticket_refs_in_public_docs`, `feedback_root_chart_needs_manual_bump` (post-merge re-run `scripts/apply-root-app.sh gke`).
- Commit groups (rough): (1) tofu WI bindings, (2) chart refactor + new SC template, (3) AppProject + root helper, (4) root templates trakrf-db + trakrf-db-preview, (5) trakrf-backend + ingester DSN change, (6) justfile db-secrets reshape, (7) docs (this spec + runbook).
