# TRA-1059 — Fix the restore-proof recipes for cluster-per-env CNPG

**Date:** 2026-07-29
**Ticket:** TRA-1059
**Related:** TRA-1037 (ops runbook, where this was discovered), TRA-849 (cluster-per-env split)

## Problem

`db-restore-test` and `db-restore-pitr-test` in the root `justfile` still target the
shared-cluster CNPG topology that TRA-849 superseded. The restore-proof path — the
thing that proves the backups are worth having — does not run.

Three independent defects, each sufficient to break the recipes on its own:

1. **Topology.** Both recipes resolve the primary via namespace `trakrf-system`,
   cluster `trakrf-db`, selector `cnpg.io/cluster=trakrf-db,role=primary`. The live
   topology is cluster-per-env, co-located in the env namespace.
2. **GCS path.** `db-restore-test` looks for dumps under `gs://<bucket>/<env>/`. The
   CronJob writes to `gs://<bucket>/<cluster-name>/dump/YYYY/MM/DD/HHMM.pgdump`. The
   old `preview/` and `prod/` prefixes have since aged out under the bucket lifecycle
   rule, so that path resolves to nothing. Fixing the namespace alone is not enough.
3. **Backend init.** Both call `tofu -chdir=terraform/gcp output -raw
   cnpg_backup_bucket`, which fails with "Backend initialization required" unless the
   working directory was initialized against the R2 backend first.

`db-pitr-trigger-base` carries defect 1 as well — same recipe family, same fix.

### Live topology (verified 2026-07-29)

| Env | Namespace | CNPG cluster | Primary pod |
| --- | --- | --- | --- |
| preview | `trakrf-preview` | `trakrf-db-preview` | `trakrf-db-preview-1` |
| prod | `trakrf-prod` | `trakrf-db-prod` | `trakrf-db-prod-1` |

`trakrf-system` still exists, holding the reflector-source Secrets (`trakrf-id-origin-tls`,
`trakrf-mosquitto-auth`, the `*-credentials` pairs) plus three orphans from the
shared-cluster era: a `trakrf-db-base` ScheduledBackup pointing at the deleted cluster,
a failed `trakrf-db-init-grants` Job, and a stale `gs://<bucket>/trakrf-db/` prefix.
Those orphans are out of scope here — follow-up ticket.

## Design

### 1. Resolve everything from the live cluster, not terraform

Both recipes drop the `tofu output` dependency entirely. The bucket is read from the
CNPG Cluster spec and the backup GSA from the `cnpg-backups` KSA annotation:

```sh
bucket=$(kubectl -n "$ns" get cluster "$cluster" \
  -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
bucket=${bucket#gs://}

gsa=$(kubectl -n "$ns" get sa cnpg-backups \
  -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}')
```

This is the reasoning that removed tofu from `gke-creds` in TRA-1037. It is also more
correct than the tofu output: it reports where the cluster *actually writes*, so a
drifted or hand-patched cluster is caught rather than masked. Side benefit — the
recipes need no `.env.local`, no R2 reachability, and no `tofu init`, so they run from
a git worktree.

Verified live: both envs resolve to bucket `trakrf-demo-usc1-cnpg-backups-ok97` and GSA
`cnpg-backups-demo@trakrf-494211.iam.gserviceaccount.com`.

### 2. Shared helper in `scripts/ops-lib.sh`

Three recipes need "find the primary pod in this namespace", and `just psql` already
open-codes it. One helper instead of a fourth copy:

```sh
# cnpg_primary_pod <namespace> — echoes the primary pod name, fails loudly.
cnpg_primary_pod() {
    local ns="${1:?namespace required}" pod
    pod=$(kubectl -n "$ns" get pod -l cnpg.io/instanceRole=primary \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "$pod" ] || { echo "ERROR: no CNPG primary found in $ns" >&2; return 1; }
    echo "$pod"
}
```

`cnpg.io/instanceRole=primary` survives a failover; the old
`cnpg.io/cluster=<name>,role=primary` pair does not. `just psql` and `just db-status`
are refactored onto the helper. `scripts/test-ops-lib.sh` gains a case for it using a
stubbed `kubectl`, per that file's existing pattern.

No new validation logic: `require_env` and `confirm_prod` are reused as-is.

### 3. `db-restore-test ENV`

`ENV` becomes **required**, matching `psql` / `db-status` / `pods` / `logs`. The current
`ENV="preview"` default is the outlier, and a defaulted env on a recipe that can touch
prod is the wrong ergonomic.

```sh
require_env "{{ ENV }}"
ns="trakrf-{{ ENV }}"; cluster="trakrf-db-{{ ENV }}"
confirm_prod "{{ ENV }}" "restore proof into a scratch DB on the live ${cluster} primary"
bucket=$(...)                                    # §1
latest=$(gcloud storage ls "gs://${bucket}/${cluster}/dump/**/*.pgdump" | sort | tail -1)
pg_pod=$(cnpg_primary_pod "$ns")                 # §2
```

Everything downstream is already correct and only needs the new `$ns` / `$pg_pod`: the
`trakrf_restore_test_<epoch>` scratch DB, the
`timescaledb_pre_restore()` / `timescaledb_post_restore()` bracketing, the
`pg_stat_user_tables` sanity query, and the drop. **The Timescale bracketing is
load-bearing and stays verbatim** — without it `pg_restore` fails on hypertable
foreign-key constraints.

`confirm_prod` is new here: the recipe creates and drops a database on the live,
single-instance prod primary. That is a prod-mutating operation and belongs behind the
same typed confirmation as the other ones.

### 4. `db-restore-pitr-test ENV [TARGET_TIME]`

The scratch Cluster stays named `trakrf-restore-test` in `trakrf-system`. The existing
workload-identity binding (`trakrf-system/trakrf-restore-test` in
`terraform/gcp/cnpg_backups.tf`) already covers it, so **this design requires no
terraform change and no apply**. Only the recovery source becomes per-env:

- `externalClusters[0].barmanObjectStore.serverName: trakrf-db-<env>` (was `trakrf-db`)
- `bucket` and `gsa` read from the *env's* cluster and KSA in `trakrf-<env>` (§1)
- primary lookup via `cnpg_primary_pod trakrf-system` (§2)
- the sanity loop drops `for db in trakrf_preview trakrf_prod` and checks the single
  `trakrf` database that each per-env cluster actually holds

Pre-delete and teardown of the scratch cluster are unchanged. `confirm_prod` is
deliberately **not** applied: this recipe never writes to the live prod cluster, it only
reads prod's object store into a throwaway cluster.

PITR artifacts confirmed present for both envs (base backups through 2026-07-29 plus
populated `wals/` prefixes), so the recovery source is real.

### 5. `db-pitr-trigger-base ENV`

Takes `ENV`, targets `trakrf-<env>` / `trakrf-db-<env>`, gains `confirm_prod` — it
schedules real backup work on the live prod primary.

### 6. Documentation

- `docs/ops.md` §9 — remove the "Currently broken" caveat.
- `docs/backups.md` — correct the `gs://<bucket>/<env>/` path layout to
  `<cluster>/dump/`, the `trakrf-system` references, and the PITR sanity check that
  still expects `trakrf_preview` + `trakrf_prod` databases.

## Testing

Parsing is not the bar; these recipes exist to have been *executed*.

1. `bash -n` / `just --evaluate` sanity, then `scripts/test-ops-lib.sh` for the new helper.
2. `just db-restore-test preview` — full run: pulls today's dump, restores into a
   scratch DB, sanity query returns non-zero rowcounts for the `trakrf` schema, scratch
   DB dropped.
3. `just db-restore-pitr-test preview` — scratch cluster recovers to Ready, `\l` shows
   `trakrf`, rowcounts non-empty, cluster torn down.
4. `just db-restore-test prod` — **check free space on the prod PVC first** and report
   the numbers before running. This restores a full prod dump onto the single-instance
   live prod primary.
5. `just db-restore-pitr-test prod` — no live-prod blast radius, object store only.

Acceptance is met when steps 2 and 4 both complete end to end.

## Risks

- **Prod restore proof consumes disk and CPU on the live prod primary.** Single
  instance, no replica to absorb it. Mitigation: verify free space before running,
  run outside any change window, drop the scratch DB promptly.
- **`gcloud storage ls "**/*.pgdump"` + `sort | tail -1`** relies on the
  zero-padded `YYYY/MM/DD/HHMM` layout sorting lexicographically to newest. True for
  the current CronJob format; noted here because it is an implicit contract with
  `helm/trakrf-db/templates/backup-cronjob.yaml`.
- **`ENV` becoming required breaks muscle memory** for anyone typing bare
  `just db-restore-test`. It fails loudly with the `require_env` message rather than
  silently doing something to the wrong env, which is the point.

## Out of scope

- The three `trakrf-system` orphans (dead ScheduledBackup, failed init-grants Job,
  stale `trakrf-db/` GCS prefix) — follow-up ticket.
- The dead `trakrf-system/*` workload-identity bindings in `cnpg_backups.tf`. Harmless,
  and removing them means a tofu apply this PR otherwise does not need.
- Any change to the backup CronJob, retention, or the bucket lifecycle rule.
