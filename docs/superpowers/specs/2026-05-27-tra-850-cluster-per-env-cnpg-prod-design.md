# Cluster-per-env CNPG — prod half (design)

**Status:** Design
**Date:** 2026-05-27
**Ticket:** TRA-850 (prod half; TRA-849 shipped the preview half)
**Blocked by:** TRA-849 (merged)
**Related (carries forward unchanged):** TRA-810 logical migration method, TRA-798 Phase-1 dumps, TRA-842 Phase-2 PITR
**Out of scope (Saturday cutover):** `app.trakrf.id` DNS flip + Railway prod retire (TRA-375)

## Why

The preview half (TRA-849) proved the per-env-Cluster tooling end-to-end. The prod half is the payoff: a dedicated `trakrf-db-prod` Cluster makes whole-cluster PITR equivalent to per-env PITR, makes a real end-to-end DR drill possible, and matches the uniform "Cluster per environment-or-tenant" pattern that the whitelabel direction will reuse.

The shared CNPG Cluster has already been retired by TRA-849 (prod data was empty pre-cutover, so preserving it was unnecessary cruft). `trakrf-backend-prod` and `trakrf-ingester-prod` are currently in CrashLoopBackOff because their DSN points at the deleted shared Cluster — they recover automatically once the new prod Cluster is up and `envs.prod.dbHost` is repointed.

## Scope split — today (dry-run) vs Saturday (TRA-375 DNS cutover)

This ticket is the **dry-run cutover**: stand up the new prod Cluster, migrate data off TimescaleDB Cloud (TSC) prod, wire up a smoke-test ingress hostname, validate end-to-end including DR drill. `app.trakrf.id` is not touched — real users continue hitting Railway prod (CNAME → `hlvn5pcb.up.railway.app`, grey-cloud) until Saturday 2026-05-30.

**Today (this PR):**

```
trakrf-system        Vestigial. Holds only trakrf-id-origin-tls (CF Origin Cert
                     source, still reflector-mirrored to env namespaces — that
                     reflector use is unrelated to db credentials and stays).
                     The shared CNPG Cluster is already gone (TRA-849 nuked it).
                     `just db-secrets` no longer touches this ns.

trakrf-preview       Unchanged from TRA-849. trakrf-db-preview Cluster + native
                     trakrf-{app,migrate}-credentials.

trakrf-prod          New dedicated `trakrf-db-prod` CNPG Cluster, co-located
                     with backend + ingester. No cross-namespace anything.
                       - trakrf DB + trakrf-app / trakrf-migrate roles + their
                         CNPG-referenced Secrets, ALL native in this ns
                       - phase-1 pg_dump CronJob + phase-2 ScheduledBackup
                         under gs://<bucket>/trakrf-db-prod/{dump,base,wals}/
                       - PVC on premium-rwo-retain (SC already created by
                         preview release; trakrf-db-prod consumes it)
                       - Application: automated.prune=false
                       - app.obfuscation_key set via ALTER DATABASE post-bootstrap
                     trakrf-backend-prod (DSN → trakrf-db-prod-rw.trakrf-prod)
                       + IngressRoute on `app.prod.gke.trakrf.id` (LE-cert,
                         breakglass IPAllowList)
                     trakrf-ingester-prod (same DSN)
```

**Saturday (TRA-375, out of scope here):**

- `cloudflare_record.app` flips CNAME → A, content = traefik LB IP, `proxied = false` (grey-cloud, mirroring Railway's current shape so no new TLS-termination model is introduced).
- `trakrf-backend-prod` ingress gains a second route: `app.trakrf.id` with LE cert. Same chart, same shape — values addition only.
- Drop `var.railway_app_prod_endpoint` from `terraform/cloudflare`; archive Railway prod.

The Railway-grey-cloud shape is the reason no orange-cloud (CF-proxied + Origin Cert) dress rehearsal is needed today: `app.prod.gke.trakrf.id` IS the Saturday TLS shape under a smoke-test hostname.

## Code changes

### `argocd/root/values.yaml` — prod overlay flip

```yaml
envs:
  preview: { ...unchanged... }
  prod:
    dbHost: trakrf-db-prod-rw.trakrf-prod   # was: trakrf-db-rw.trakrf-system
    ingressEnabled: true                     # was: false (dry-run smoke route)
    mqttIp: ""
    dbCluster:
      enabled: true                          # was: false
      fullnameOverride: trakrf-db-prod       # was: trakrf-db
      namespace: trakrf-prod                 # was: trakrf-system
      createRetainClass: false               # preview already created the cluster-scoped SC
      externalIp: ""
```

### `argocd/root/templates/_helpers.tpl` — parameterize ingress helper

Rename `trakrf-backend.previewIngressValues` → `trakrf-backend.ingressValues`. Take env from caller context, render `app.<env>.gke.trakrf.id` (always emitted when ingress is on) and `app.<env>.trakrf.id` (CF grey-cloud, gated on a per-env flag so prod can opt out today). Default behavior preserves preview output bit-for-bit; prod renders only the `gke-direct` route under `app.prod.gke.trakrf.id`.

The helper still emits both `breakglass-allow` and `cloudflare-allow` Middleware definitions unconditionally — they're cheap, and the apex `app.trakrf.id` route added Saturday will want `cloudflare-allow` available if orange-cloud ever returns.

Call-site update in `trakrf-backend.yaml`: pass `env` + per-env config dict into the helper. The new prod branch goes through the same helper (was previously hardcoded `ingress.enabled: false`).

### `argocd/root/templates/trakrf-backend.yaml` + `trakrf-ingester.yaml` — DSN flip

The `range $env := $.Values.envs` loop already handles prod naturally; the `$base` block picks up `$cfg.dbHost` which is now `trakrf-db-prod-rw.trakrf-prod`. `trakrf-ingester.yaml` is purely a DSN-host flip via `$cfg.dbHost`; no ingress.

### `terraform/gcp/cnpg_backups.tf` — WI bindings + lifecycle prefix

Two new bindings mirroring the preview ones:

```hcl
resource "google_service_account_iam_member" "cnpg_backups_wi_cluster_prod" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-prod/trakrf-db-prod]"
}

resource "google_service_account_iam_member" "cnpg_backups_wi_pgdump_prod" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-prod/cnpg-backups]"
}
```

Broaden `google_storage_bucket.cnpg_backups.lifecycle_rule.matches_prefix` to include `trakrf-db-prod/dump/`.

### `justfile` — `db-secrets` drops reflector entirely

Today the recipe produces preview Secrets natively in `trakrf-preview` + prod Secrets reflector-mirrored from `trakrf-system` → `trakrf-prod`. After this PR:

- `trakrf-{app,migrate}-credentials` in `trakrf-preview` (native, unchanged)
- `trakrf-{app,migrate}-credentials` in `trakrf-prod` (native, no reflector annotations)

The `_db-secret` helper drops the REFLECT/source-ns parameters; namespaces are passed directly. Passwords still sourced from `.env.local` (`TRAKRF_{APP,MIGRATE}_DB_PASSWORD_{PREVIEW,PROD}`).

The CF Origin Cert recipe (`just origin-cert-secret`) is orthogonal — it uses reflector for genuinely-shared trust material and stays as-is.

**Vestigial cleanup:** after the prod-secrets-native step lands, the old `trakrf-system` reflector-source Secrets are orphans. The runbook (not the recipe — it's a one-time op) includes:

```bash
kubectl -n trakrf-system delete secret trakrf-app-credentials trakrf-migrate-credentials
```

### `argocd/projects/trakrf.yaml`

The new `trakrf-db-prod` Application targets namespace `trakrf-prod` with `path: helm/trakrf-db`. Pre-flight check that the existing `destinations` + `sourceRepos` entries cover this; expected no project edit needed.

### What's NOT changing

- `helm/trakrf-db/` chart — TRA-849 already refactored it to single-env shape with flat values. The prod release uses identical templates, just different `fullnameOverride` + namespace.
- `helm/trakrf-backend/` chart — IngressRoute + Certificate + Middleware templates already support arbitrary routes via values; the prod route is values-only.
- `argocd/root/templates/trakrf-db.yaml` — already iterates `envs` and emits a Cluster Application per enabled env. Flipping `envs.prod.dbCluster.enabled: true` is the entire activation.
- CF Origin Cert reflector use (`just origin-cert-secret`) — stays as-is.

## Operational sequence (dry-run cutover, today)

```
PRE-MERGE
  1. `just db-secrets` (new shape) creates the four native Secrets:
       - trakrf-preview ns: trakrf-{app,migrate}-credentials (idempotent, unchanged)
       - trakrf-prod    ns: trakrf-{app,migrate}-credentials (new, native; no reflector)
     Verify: both ns return Secrets with no `reflector.v1.k8s.emberstack.com/*` annotations.
  2. Generate the prod app.obfuscation_key:
       openssl rand -hex 32   # store output in 1Password as
                              # "trakrf-prod app.obfuscation_key" (vault: Infrastructure)
     Document the 1Password reference in docs/db-migration.md as a Cluster-rebuild prereq.
  3. Snapshot TSC prod row counts for the post-migration diff (per-table SELECT count(*)).
  4. (Operator action — already handled this session: Railway prod ingester deleted,
     not just stopped. Railway dashboard had no disable affordance.) TSC prod is now
     a frozen source; the migration captures everything up to the Railway-delete
     moment. Acceptable brief ingest gap until step 7 brings the GKE prod ingester
     online.

MERGE (reviewer-light PR; values-flip dominated diff)

POST-MERGE
  5. `just gcp`                                  # tofu apply: WI bindings + lifecycle prefix
  6. scripts/apply-root-app.sh gke               # re-render root chart (required after
                                                 # root-chart template/values edits per
                                                 # feedback_root_chart_needs_manual_bump)
  7. Watch Argo reconcile:
       - trakrf-db-prod Application: Synced + Healthy, prune=false on the spec.
       - trakrf-prod ns gets the Cluster + Database CR + ScheduledBackup + pg_dump CronJob.
       - trakrf-backend-prod recovers from CrashLoop once the Cluster reports Ready
         (DSN now resolves to trakrf-db-prod-rw.trakrf-prod).
       - trakrf-ingester-prod recovers same way; resumes MQTT consumption.
       - trakrf-backend-prod IngressRoute on app.prod.gke.trakrf.id; LE cert issued.
  8. Apply obfuscation_key BEFORE data cutover:
       kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
         psql -U postgres -d trakrf \
              -c "ALTER DATABASE trakrf SET app.obfuscation_key = '<64-hex from 1Password>'"
     Then bounce the backend pod so its open connections pick up the new GUC
     (a session that connected pre-ALTER continues with the old empty value):
       kubectl -n trakrf-prod rollout restart deploy/trakrf-backend
  9. Run docs/db-migration.md end-to-end for <env>=prod, source=TSC prod instance.
     Same runbook as preview, substitution table:
       env        : preview → prod
       ns         : trakrf-preview → trakrf-prod
       cluster    : trakrf-db-preview → trakrf-db-prod
       TSC source : preview instance → prod instance
     Step ordering: schema via migrate Job, FDW pull data per table (TimescaleDB
     hypertables bracketed by timescaledb_pre_restore() / _post_restore() per
     feedback_timescale_logical_restore_bracket), row-count + spot-check diff,
     tear down FDW state.
 10. Cleanup orphan reflector sources:
       kubectl -n trakrf-system delete secret trakrf-app-credentials trakrf-migrate-credentials
 11. Smoke tests against https://app.prod.gke.trakrf.id (breakglass-gated to operator IP):
       - login round-trip (validates app.obfuscation_key cipher path)
       - one read + one write of a Feistel-encoded ID-bearing resource
       - ingester MQTT ingest sanity (verify new messages land in trakrf-db-prod)
 12. DR drill (next section).
```

## DR drill choreography (today, post-smoke-tests)

Goal: prove restore + key re-apply works on the freshly-loaded prod data before Saturday.

```
A. Snapshot pre-drill state:
   - row counts per table (matches step 3 above + any inserts from smoke tests)
   - one sentinel row in a known table (timestamp + UUID) so we can verify the
     PITR landed at the right point
   - SELECT pg_switch_wal() (as superuser) immediately after writing the sentinel,
     to force a WAL segment flush so the targetTime is reachable

B. Take a fresh base backup off-schedule:
   kubectl -n trakrf-prod create -f - <<EOF
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: trakrf-db-prod-drill-base
     namespace: trakrf-prod
   spec:
     cluster: { name: trakrf-db-prod }
     method: barmanObjectStore
   EOF
   Wait for status.phase=completed; verify object lands at
   gs://<bucket>/trakrf-db-prod/base/<ts>/.

C. Pre-flight for restore: the DR Cluster's KSA needs a WI binding to the
   cnpg-backups GSA. The committed tofu binding is for
   `trakrf-prod/trakrf-db-prod` only. Add a one-off
   `google_service_account_iam_member` for `trakrf-prod/trakrf-db-prod-dr` to
   `terraform/gcp/cnpg_backups.tf`, run `just gcp`, do the drill, then revert
   the addition + re-run `just gcp` in step G. The runbook captures both
   apply + revert verbatim.

D. Restore into a SIDE cluster (so the live trakrf-db-prod stays serving smoke
   traffic + ingester). Apply a one-off manifest:

   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: trakrf-db-prod-dr
     namespace: trakrf-prod
   spec:
     instances: 1
     storage: { storageClass: premium-rwo-retain, size: 10Gi }
     bootstrap:
       recovery:
         source: trakrf-db-prod-source
         recoveryTarget:
           targetTime: "<pre-drill timestamp from A>"
     externalClusters:
       - name: trakrf-db-prod-source
         barmanObjectStore:
           destinationPath: gs://<bucket>/trakrf-db-prod
           googleCredentials: { gkeEnvironment: true }
           serverName: trakrf-db-prod

   The side cluster reads its own WAL stream + base from the same GCS path;
   CNPG resolves the right base + WAL replay range for the target time.

E. Verify the GUC carried through:
   kubectl -n trakrf-prod exec trakrf-db-prod-dr-1 -- \
     psql -U postgres -d trakrf -c "SHOW app.obfuscation_key"
   # If empty (unexpected — ALTER DATABASE persists in the catalog and IS in the
   # basebackup), re-apply with the 1Password value. Either way: confirm value
   # matches before declaring the drill green.

F. Verify:
   - sentinel row present
   - row counts match A
   - sample Feistel-encoded ID decode against the DR cluster returns the
     same plaintext sequence as the live cluster (confirms key carried through)

G. Tear down:
   kubectl -n trakrf-prod delete cluster trakrf-db-prod-dr
   # PVC honors Retain — manually delete PVC + PV to actually free storage:
   kubectl -n trakrf-prod delete pvc -l cnpg.io/cluster=trakrf-db-prod-dr
   kubectl get pv | grep trakrf-db-prod-dr | awk '{print $1}' | xargs -r kubectl delete pv
   # Revert the one-off WI binding added in step C.
   # Verify base+WAL in GCS unchanged (the drill only READ from GCS).

H. Capture in docs/db-migration.md as a "Restore drill" section, re-runnable
   (against a future timestamp) before any high-risk maintenance window.
```

## Risks + mitigations

- **app.obfuscation_key drift.** Backend pods that connected before the ALTER DATABASE have `app.obfuscation_key = ''` and Feistel decode fails silently. Mitigation: `kubectl rollout restart deploy/trakrf-backend` after the ALTER. Baked into op-sequence step 8.
- **TSC prod FDW connection load.** TSC prod is the live source until Railway-stop; a full table-scan COPY pull spikes connection count. The preview-half runbook orders by FK dependencies, serial — already mitigated. Pre-flight: confirm TSC prod's `max_connections` headroom in the TSC dashboard.
- **PITR target-time precision.** WAL archiving cadence in the TRA-842 stanza may flush less often than the sentinel-write rate. If the pre-drill sentinel commits *between* WAL segment flushes, `recoveryTarget.targetTime` lands BEFORE the sentinel. Mitigation: `SELECT pg_switch_wal()` (superuser) right after writing the sentinel — see DR drill step A.
- **DR cluster ServiceAccount needs WI binding.** CNPG creates a KSA matching the Cluster name. The tofu binding is for `trakrf-prod/trakrf-db-prod`, not `-dr`. Mitigation in op-sequence step C: temporary tofu patch adding `trakrf-prod/trakrf-db-prod-dr` binding, revert in step G.
- **Ingest gap during the migration window.** Railway prod ingester stopped pre-merge by operator; the GKE prod ingester comes up at step 7. Any MQTT messages in that window depend on broker queue/QoS semantics. Accepted: the platform side is idempotent (per TRA-810 design), so worst-case re-delivery on broker reconnect is benign.
- **Reconcile churn during the merge window.** `prune=false` on trakrf-db-prod means even if Argo gets confused, neither the Cluster CR nor the PVC gets deleted. Worst case: Application Degraded, no data loss.

## Verification (acceptance criteria mapped to checks)

```bash
# AC: dedicated trakrf-db-prod Cluster live; prod app + ingester serve from it
kubectl -n trakrf-prod get cluster trakrf-db-prod \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'   # → True
argocd app get trakrf-db-prod -o json \
  | jq '.status.sync.status,.status.health.status,.spec.syncPolicy.automated.prune'
# → "Synced", "Healthy", false

kubectl -n trakrf-prod exec deploy/trakrf-backend -- printenv PG_URL | grep -q \
  'host=trakrf-db-prod-rw.trakrf-prod.*dbname=trakrf'
kubectl -n trakrf-prod get pods -l app=trakrf-backend -o jsonpath='{.items[*].status.phase}'
# → Running Running ...  (no CrashLoopBackOff)

# AC: app.obfuscation_key set + documented
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -At -c "SHOW app.obfuscation_key" \
  | grep -qE '^[0-9a-f]{64}$'
# (Value also present in 1Password under "trakrf-prod app.obfuscation_key")

# AC: data cut over via logical migration; row counts match TSC prod
diff <(snapshot from op-sequence step 3) <(post-migration counts)   # → empty diff

# AC: per-Cluster PITR confirmed via DR drill
# (covered by DR drill steps A–F; drill passes when sentinel + counts match
# and Feistel decode is consistent between live and DR Clusters)

# AC: shared Cluster decommissioned, trakrf_prod removed beforehand
kubectl -n trakrf-system get cluster 2>&1                # → no resources found
kubectl -n trakrf-system get secrets trakrf-app-credentials trakrf-migrate-credentials 2>&1
# → NotFound (cleanup op-sequence step 10)

# AC: smoke tests pass on app.prod.gke.trakrf.id
curl -sf --resolve app.prod.gke.trakrf.id:443:<traefik-lb-ip> \
  https://app.prod.gke.trakrf.id/healthz   # → 200
# (or just hit it from a breakglass-allowed origin)
```

## Workflow

- **Worktree** (per memory `feedback_use_worktrees_for_long_branches`): `.claude/worktrees/miks2u+tra-850-cluster-per-env-cnpg-prod` (to create).
- **Branch**: `miks2u/tra-850-cluster-per-env-cnpg-prod-onto-dedicated-cluster-retire` (per Linear `gitBranchName`).
- **Commit groups (rough):**
  1. tofu WI bindings + GCS lifecycle prefix
  2. root values prod overlay flip
  3. parameterized ingress helper + trakrf-backend/ingester template touch-ups
  4. justfile db-secrets reshape
  5. docs (this spec + db-migration.md DR drill section)
- **Memory hits to be aware of**: `feedback_never_merge_to_main`, `feedback_no_ticket_refs_in_public_docs`, `feedback_root_chart_needs_manual_bump`, `feedback_db_password_alphabet`.
- **PR**: open against `main`. Per CLAUDE.md, never merge to main locally — finishing-a-development-branch will default to a PR.
