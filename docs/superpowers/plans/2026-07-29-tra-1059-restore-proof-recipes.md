# TRA-1059 Restore-Proof Recipes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `just db-restore-test` and `just db-restore-pitr-test` work against the live cluster-per-env CNPG topology, and prove it by executing a real restore for both preview and prod.

**Architecture:** All three restore-family recipes become `ENV`-parameterized (`preview` | `prod`), resolving namespace `trakrf-<env>` and cluster `trakrf-db-<env>`. The backup bucket and backup GSA are read from the live cluster spec and ServiceAccount annotation via `kubectl`, replacing the `tofu output` calls that required an initialized R2 backend. Primary-pod lookup moves into a shared `cnpg_primary_pod` helper in `scripts/ops-lib.sh` keyed on `cnpg.io/instanceRole=primary`, which survives failover.

**Tech Stack:** just (justfile recipes), bash, kubectl, CloudNativePG, TimescaleDB, gcloud storage, GKE Workload Identity.

## Global Constraints

- Environment names are exactly `preview` and `prod`. Validate with `require_env` from `scripts/ops-lib.sh` — never reimplement.
- Namespace is always `trakrf-<env>`; CNPG cluster is always `trakrf-db-<env>`.
- Primary pods are selected by `-l cnpg.io/instanceRole=primary` only. Never `cnpg.io/cluster=<name>,role=primary`.
- No recipe in this plan may call `tofu`. No recipe may call `require_tf_env`.
- The `timescaledb_pre_restore()` / `timescaledb_post_restore()` bracketing around `pg_restore` is load-bearing and must be preserved verbatim — without it `pg_restore` fails on hypertable foreign-key constraints.
- GCS dump path layout is `gs://<bucket>/<cluster-name>/dump/YYYY/MM/DD/HHMM.pgdump`.
- The PITR scratch cluster is always named `trakrf-restore-test` in namespace `trakrf-system` — the workload-identity binding in `terraform/gcp/cnpg_backups.tf` is static and must not be invalidated. No terraform changes in this plan.
- Every recipe body is a `#!/usr/bin/env bash` shebang recipe with `set -euo pipefail` and `source scripts/ops-lib.sh`.
- Conventional commits, `fix(tra-1059):` or `docs(tra-1059):` prefix.

## Known-Good Live Values (verified 2026-07-29)

Use these to confirm your resolution logic returns the right thing. Do not hardcode them into recipes.

| Thing | Value |
| --- | --- |
| Bucket (both envs) | `trakrf-demo-usc1-cnpg-backups-ok97` |
| Backup GSA | `cnpg-backups-demo@trakrf-494211.iam.gserviceaccount.com` |
| preview primary | `trakrf-db-preview-1` |
| prod primary | `trakrf-db-prod-1` |

## File Structure

- `scripts/ops-lib.sh` — **modify.** Add `cnpg_primary_pod`. This file is the single home for shared recipe helpers; it is sourced, never executed.
- `scripts/test-ops-lib.sh` — **modify.** Add a `cnpg_primary_pod` test group using a stubbed `kubectl` shell function.
- `justfile` — **modify.** Four recipes: `db-restore-test` (415), `db-pitr-trigger-base` (485), `db-restore-pitr-test` (513), plus `psql` (598) / `db-status` (615) refactored onto the new helper.
- `docs/ops.md` — **modify.** §9 caveat removal.
- `docs/backups.md` — **modify.** Path layout, `trakrf-system` references, PITR sanity-check DB names.

---

### Task 1: `cnpg_primary_pod` helper

**Files:**
- Modify: `scripts/ops-lib.sh`
- Test: `scripts/test-ops-lib.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `cnpg_primary_pod <namespace>` — echoes the primary pod name on stdout, returns 0. On no match, prints `ERROR: no CNPG primary found in <ns>` to stderr and returns 1. Tasks 2–4 call this.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-ops-lib.sh`, immediately before the final `echo` / `echo "passed: ..."` block:

```bash
echo "cnpg_primary_pod:"

# Stub kubectl: a shell function shadows the real binary for the callee.
kubectl() { echo "trakrf-db-preview-1"; }
out=$(cnpg_primary_pod trakrf-preview 2>/dev/null); rc=$?
check "returns rc=0 when a primary exists" $rc 0
if [ "$out" = "trakrf-db-preview-1" ]; then
  ok "echoes the pod name"
else
  bad "echoes the pod name (got '$out')"
fi

# Empty stdout is how kubectl reports "no pods matched" for this jsonpath.
kubectl() { echo -n ""; }
cnpg_primary_pod trakrf-preview >/dev/null 2>&1
check "rejects an empty result" $? 1

# A hard kubectl failure (bad ns, auth expired) must not be swallowed.
kubectl() { return 1; }
cnpg_primary_pod trakrf-preview >/dev/null 2>&1
check "rejects a kubectl failure" $? 1

cnpg_primary_pod >/dev/null 2>&1
check "rejects a missing namespace arg" $? 1

unset -f kubectl
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-ops-lib.sh`
Expected: FAIL — `cnpg_primary_pod: command not found`, and the final line reports a non-zero `failed:` count with exit status 1.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/ops-lib.sh`:

```bash
# cnpg_primary_pod <namespace>
# Echo the name of the CNPG primary pod in <namespace>.
#
# Selects on cnpg.io/instanceRole=primary rather than the older
# cnpg.io/cluster=<name>,role=primary pair: instanceRole is maintained by the
# operator across a failover, so this keeps resolving after the primary moves,
# and it does not need the cluster name threaded in.
cnpg_primary_pod() {
    local ns="${1:-}" pod
    if [ -z "$ns" ]; then
        echo "ERROR: cnpg_primary_pod requires a namespace" >&2
        return 1
    fi
    pod=$(kubectl -n "$ns" get pod -l cnpg.io/instanceRole=primary \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$pod" ]; then
        echo "ERROR: no CNPG primary found in $ns" >&2
        return 1
    fi
    echo "$pod"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-ops-lib.sh`
Expected: PASS — `failed: 0`, exit status 0.

- [ ] **Step 5: Verify against the live cluster**

Run: `bash -c 'source scripts/ops-lib.sh; cnpg_primary_pod trakrf-preview; cnpg_primary_pod trakrf-prod'`
Expected: `trakrf-db-preview-1` then `trakrf-db-prod-1`.

Run: `bash -c 'source scripts/ops-lib.sh; cnpg_primary_pod trakrf-nope'; echo "rc=$?"`
Expected: `ERROR: no CNPG primary found in trakrf-nope` and `rc=1`.

- [ ] **Step 6: Commit**

```bash
git add scripts/ops-lib.sh scripts/test-ops-lib.sh
git commit -m "feat(tra-1059): add cnpg_primary_pod helper to ops-lib

Selects on cnpg.io/instanceRole=primary so it survives a failover, unlike
the cnpg.io/cluster=<name>,role=primary pair the restore recipes use today."
```

---

### Task 2: Refactor `psql` and `db-status` onto the helper

**Files:**
- Modify: `justfile` (recipe `psql`, line 598; recipe `db-status`, line 615)

**Interfaces:**
- Consumes: `cnpg_primary_pod <ns>` from Task 1.
- Produces: nothing new.

This task exists so the helper has proven callers before the restore recipes depend on it, and so the primary lookup lives in exactly one place.

- [ ] **Step 1: Replace the inline lookup in `psql`**

In the `psql ENV:` recipe, replace these lines:

```bash
    pod=$(kubectl -n "$ns" get pod -l cnpg.io/instanceRole=primary \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$pod" ]; then
        echo "ERROR: no CNPG primary found in $ns" >&2
        exit 1
    fi
```

with:

```bash
    pod=$(cnpg_primary_pod "$ns")
```

Leave the surrounding `require_env`, `ns=`, `echo "→ $ns/$pod (database: trakrf)"`, and the `kubectl exec` line untouched. `set -e` plus the helper's `return 1` produces the same exit-on-failure behavior, and the helper prints the same message.

- [ ] **Step 2: Verify `psql` still resolves**

Run: `just --evaluate >/dev/null && echo "justfile parses"`
Expected: `justfile parses`

Run: `just psql preview` and confirm the banner reads `→ trakrf-preview/trakrf-db-preview-1 (database: trakrf)` and you get a `trakrf=#` prompt. Type `\q` to exit.

- [ ] **Step 3: Confirm `db-status` needs no change**

Run: `just db-status preview`
Expected: the Cluster row plus its instance pods. `db-status` uses `kubectl get cluster` and a `cnpg.io/cluster` label selector for *listing all* instances, not for finding the primary — that is a correct use of the cluster label. Leave it as is.

- [ ] **Step 4: Commit**

```bash
git add justfile
git commit -m "refactor(tra-1059): use cnpg_primary_pod in the psql recipe"
```

---

### Task 3: `db-restore-test ENV`

**Files:**
- Modify: `justfile` lines 405-477 (comment block + `db-restore-test` recipe)

**Interfaces:**
- Consumes: `require_env`, `confirm_prod`, `cnpg_primary_pod` from `scripts/ops-lib.sh`.
- Produces: nothing.

Three defects are fixed here, and all three are required — none is sufficient alone. (1) namespace/cluster/primary resolution, (2) the GCS prefix, which is now `<cluster>/dump/` and whose old `<env>/` form has aged out of the bucket entirely, (3) the tofu backend dependency.

- [ ] **Step 1: Replace the comment block and recipe signature**

Replace lines 405-415 (from `# Restore proof:` through `db-restore-test ENV="preview":`) with:

```
# Restore proof: pull the latest pg_dump for ENV from GCS, restore it
# into a scratch database on that env's live CNPG cluster, run a sanity
# query, drop the scratch database. Requires:
#   - `just gcp-auth` (logs in and refreshes ADC in one step — `gcloud storage`
#     needs ADC, which `gcloud auth login --update-adc` already provides)
#   - kubectl context pointed at the GKE cluster
#
# The bucket is read from the live Cluster spec rather than a tofu output,
# so this needs no .env.local and no initialized R2 backend — and it reports
# where the cluster actually writes, catching drift instead of masking it.
#
# ENV is required: this recipe can mutate prod, so it must not default.
#
# Usage:
#   just db-restore-test preview
#   just db-restore-test prod
db-restore-test ENV:
```

- [ ] **Step 2: Replace the resolution preamble**

Replace the recipe body from `source scripts/ops-lib.sh` through the `test -n "$pg_pod" ...` line (old lines 418-436) with:

```bash
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    cluster="trakrf-db-{{ ENV }}"

    confirm_prod "{{ ENV }}" "restore proof — creates and drops a scratch DB on the live ${cluster} primary"

    # Bucket comes from the live Cluster's barman config, not tofu: no
    # backend init, no .env.local, and it is authoritative for this cluster.
    bucket=$(kubectl -n "$ns" get cluster "$cluster" \
      -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
    bucket=${bucket#gs://}
    test -n "$bucket" || { echo "could not resolve backup bucket from cluster ${cluster} in ${ns}"; exit 1; }

    # Path layout is set by helm/trakrf-db/templates/backup-cronjob.yaml:
    #   gs://<bucket>/<cluster>/dump/YYYY/MM/DD/HHMM.pgdump
    # Zero-padded, so lexical sort puts the newest last.
    echo "Looking for latest dump in gs://${bucket}/${cluster}/dump/..."
    latest=$(gcloud storage ls "gs://${bucket}/${cluster}/dump/**/*.pgdump" | sort | tail -1)
    test -n "$latest" || { echo "no dumps found in gs://${bucket}/${cluster}/dump/"; exit 1; }
    echo "Latest dump: $latest"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    gcloud storage cp "$latest" "$tmp/dump.pgdump"
    ls -la "$tmp/dump.pgdump"

    # `kubectl exec ... psql -U postgres` on the CNPG primary uses peer
    # auth via the unix socket — no password needed.
    pg_pod=$(cnpg_primary_pod "$ns")
```

- [ ] **Step 3: Repoint the remaining `kubectl` calls at `$ns`**

In the rest of the recipe body (old lines 437-477), replace every occurrence of `kubectl -n trakrf-system` with `kubectl -n "$ns"`. There are six: the `CREATE DATABASE`, the `CREATE EXTENSION` + `timescaledb_pre_restore()`, the `pg_restore`, the `timescaledb_post_restore()`, the sanity check, and the `DROP DATABASE`.

Leave everything else byte-identical — in particular the whole `timescaledb_pre_restore` / `_post_restore` bracketing and its explanatory comment.

Change the final line from:

```bash
    echo "Restore proof complete for ENV={{ ENV }}."
```

to:

```bash
    echo "Restore proof complete for {{ ENV }} (${cluster} in ${ns})."
```

- [ ] **Step 4: Verify no stale references remain**

Run: `sed -n '/^db-restore-test/,/^# Manually trigger/p' justfile | grep -n "trakrf-system\|tofu\|require_tf_env\|role=primary"`
Expected: no output (grep exits 1).

Run: `just --evaluate >/dev/null && echo "justfile parses"`
Expected: `justfile parses`

- [ ] **Step 5: Verify the argument guard**

Run: `just db-restore-test staging`
Expected: `ERROR: ENV must be 'preview' or 'prod', got 'staging'`, non-zero exit, nothing touched.

Run: `just db-restore-test`
Expected: just's own error that the recipe got 0 arguments but takes 1.

- [ ] **Step 6: Commit**

```bash
git add justfile
git commit -m "fix(tra-1059): retarget db-restore-test at cluster-per-env CNPG

Resolves ns trakrf-<env> / cluster trakrf-db-<env>, reads the bucket from
the live Cluster spec instead of an uninitialized tofu backend, and fixes
the GCS prefix to <cluster>/dump/ — the old <env>/ prefix has aged out of
the bucket, so the path was broken independently of the topology. ENV is
now required and prod is gated behind confirm_prod."
```

---

### Task 4: `db-restore-pitr-test ENV [TARGET_TIME]`

**Files:**
- Modify: `justfile` lines 503-596 (comment block + `db-restore-pitr-test` recipe)

**Interfaces:**
- Consumes: `require_env`, `cnpg_primary_pod`.
- Produces: nothing.

The scratch Cluster keeps the fixed name `trakrf-restore-test` in `trakrf-system` because the workload-identity binding in `terraform/gcp/cnpg_backups.tf` is static — moving it would require a tofu apply this plan deliberately avoids. Only the *recovery source* becomes per-env. No `confirm_prod`: this never writes to the live prod cluster, it reads prod's object store into a throwaway cluster.

- [ ] **Step 1: Replace the comment block and signature**

Replace lines 503-513 with:

```
# Proves CNPG PITR by spinning up a scratch Cluster that recovers ENV's
# barman object store, optionally to a specific point in time. The scratch
# cluster always uses the fixed name `trakrf-restore-test` in trakrf-system
# so the static WI binding in terraform/gcp/cnpg_backups.tf fits — only the
# recovery source (serverName) is per-env.
#
# Does NOT touch the live cluster: it reads the object store only. Safe to
# run against prod without a confirmation gate.
#
# Idempotent: pre-deletes any leftover scratch cluster before applying.
#
# Usage:
#   just db-restore-pitr-test preview
#   just db-restore-pitr-test prod
#   just db-restore-pitr-test prod "2026-05-27T10:30:00Z"
db-restore-pitr-test ENV TARGET_TIME="":
```

- [ ] **Step 2: Replace the resolution preamble**

Replace the body lines from `source scripts/ops-lib.sh` through `ns=trakrf-system` (old lines 516-521) with:

```bash
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    src_ns="trakrf-{{ ENV }}"
    src_cluster="trakrf-db-{{ ENV }}"
    scratch=trakrf-restore-test
    ns=trakrf-system

    # Bucket and backup GSA come from the live env cluster + its backup KSA,
    # not tofu — no backend init required.
    bucket=$(kubectl -n "$src_ns" get cluster "$src_cluster" \
      -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
    bucket=${bucket#gs://}
    test -n "$bucket" || { echo "could not resolve backup bucket from cluster ${src_cluster} in ${src_ns}"; exit 1; }

    gsa=$(kubectl -n "$src_ns" get sa cnpg-backups \
      -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}')
    test -n "$gsa" || { echo "could not resolve backup GSA from sa/cnpg-backups in ${src_ns}"; exit 1; }
    echo "Recovering ${src_cluster} from gs://${bucket}/${src_cluster} as ${gsa}"
```

- [ ] **Step 3: Point the recovery source at the env's serverName**

In the heredoc, change:

```yaml
      externalClusters:
        - name: trakrf-db-source
          barmanObjectStore:
            destinationPath: gs://${bucket}
            serverName: trakrf-db
```

to:

```yaml
      externalClusters:
        - name: trakrf-db-source
          barmanObjectStore:
            destinationPath: gs://${bucket}
            serverName: ${src_cluster}
```

Also update the echo above the heredoc from `gs://${bucket}/trakrf-db` to `gs://${bucket}/${src_cluster}`. Leave `bootstrap.recovery.source: trakrf-db-source` alone — that is an internal reference to the `externalClusters` entry name, not a cluster in the object store.

- [ ] **Step 4: Fix the primary lookup and the sanity loop**

Replace:

```bash
    pg_pod=$(kubectl -n "$ns" get pod -l cnpg.io/cluster=${scratch},role=primary \
              -o jsonpath='{.items[0].metadata.name}')
    test -n "$pg_pod" || { echo "no scratch primary pod found"; exit 1; }
```

with:

```bash
    pg_pod=$(cnpg_primary_pod "$ns")
```

Then replace the two-database loop:

```bash
    for db in trakrf_preview trakrf_prod; do
      echo
      echo "==== ${db}: trakrf schema rowcounts ===="
      kubectl -n "$ns" exec "$pg_pod" -- \
        psql -U postgres -d "$db" -c "\dn" \
        -c "SELECT schemaname, relname, n_live_tup
            FROM pg_stat_user_tables
            WHERE schemaname='trakrf'
            ORDER BY relname;" || echo "(${db} not present at target time)"
    done
```

with a single-database check — each per-env cluster holds one database named `trakrf`, so the old `trakrf_preview` / `trakrf_prod` pair no longer exists anywhere:

```bash
    echo
    echo "==== trakrf: schema rowcounts ===="
    kubectl -n "$ns" exec "$pg_pod" -- \
      psql -U postgres -d trakrf -c "\dn" \
      -c "SELECT schemaname, relname, n_live_tup
          FROM pg_stat_user_tables
          WHERE schemaname='trakrf'
          ORDER BY relname;"
```

Change the closing line from `echo "PITR restore proof complete."` to:

```bash
    echo "PITR restore proof complete for {{ ENV }} (source ${src_cluster})."
```

- [ ] **Step 5: Verify no stale references remain**

Run: `sed -n '/^db-restore-pitr-test/,/^# Interactive psql/p' justfile | grep -n "tofu\|require_tf_env\|role=primary\|trakrf_preview\|trakrf_prod\|serverName: trakrf-db$"`
Expected: no output.

Run: `just --evaluate >/dev/null && echo "justfile parses"`
Expected: `justfile parses`

Run: `just db-restore-pitr-test staging`
Expected: the `require_env` rejection, non-zero exit, no cluster applied.

- [ ] **Step 6: Commit**

```bash
git add justfile
git commit -m "fix(tra-1059): retarget db-restore-pitr-test at per-env object stores

Scratch cluster stays trakrf-restore-test in trakrf-system to keep the
static WI binding valid; only serverName, bucket and GSA become per-env.
Sanity check now targets the single trakrf DB each per-env cluster holds."
```

---

### Task 5: `db-pitr-trigger-base ENV`

**Files:**
- Modify: `justfile` lines 479-501 (comment block + `db-pitr-trigger-base` recipe)

**Interfaces:**
- Consumes: `require_env`, `confirm_prod`.
- Produces: nothing.

Same hardcoded-topology defect as the other two. Gated with `confirm_prod` because it schedules real backup work on the live prod primary.

- [ ] **Step 1: Replace the whole block**

Replace lines 479-501 with:

```
# Manually trigger an ad-hoc CNPG Backup CR against ENV's cluster.
# Useful for first-install verification (don't wait for the scheduled
# run) or for taking a guaranteed-fresh base backup before a risky
# operation.
#
# Usage:
#   just db-pitr-trigger-base preview
#   just db-pitr-trigger-base prod
db-pitr-trigger-base ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    cluster="trakrf-db-{{ ENV }}"

    confirm_prod "{{ ENV }}" "trigger an ad-hoc base backup on the live ${cluster}"

    # kubectl apply requires a fixed name; embed a timestamp for uniqueness.
    name="${cluster}-manual-$(date -u +%Y%m%d%H%M%S)"
    kubectl -n "$ns" apply -f - <<EOF
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: ${name}
      namespace: ${ns}
    spec:
      cluster:
        name: ${cluster}
      method: barmanObjectStore
    EOF
    echo "Backup CR ${name} submitted. Watch with: kubectl -n ${ns} get backup -w"
```

- [ ] **Step 2: Verify**

Run: `just --evaluate >/dev/null && echo "justfile parses"`
Expected: `justfile parses`

Run: `just db-pitr-trigger-base staging`
Expected: the `require_env` rejection, nothing applied.

- [ ] **Step 3: Live-test against preview**

Run: `just db-pitr-trigger-base preview`
Expected: `backup.postgresql.cnpg.io/trakrf-db-preview-manual-<ts> created`.

Then: `kubectl -n trakrf-preview get backup --sort-by=.status.startedAt | tail -3`
Expected: the new Backup reaches `completed` within a couple of minutes. If it reports `failed`, capture the error and stop — that is a real backup-path problem, not a recipe problem.

- [ ] **Step 4: Commit**

```bash
git add justfile
git commit -m "fix(tra-1059): parameterize db-pitr-trigger-base on ENV

Same superseded-topology defect as the restore recipes; prod is gated
behind confirm_prod since it schedules work on the live primary."
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/ops.md` (§9, the `db-restore-test` bullet around line 439)
- Modify: `docs/backups.md` (path layout ~line 26, restore usage ~55-79, `trakrf-system` refs ~103-197)

**Interfaces:**
- Consumes: the final recipe signatures from Tasks 3-5.
- Produces: nothing.

- [ ] **Step 1: Remove the ops.md caveat**

Replace the `just db-restore-test [env]` bullet in §9 — currently carrying the four-line **Currently broken:** caveat — with:

```markdown
- `just db-restore-test <env>` — restore proof from the latest logical dump.
  `<env>` is required. Against prod it creates and drops a scratch database
  on the live primary, so it prompts for confirmation. See [backups.md](backups.md).
- `just db-restore-pitr-test <env> [target-time]` — PITR proof via a scratch
  cluster recovered from the object store. Does not touch the live cluster.
```

- [ ] **Step 2: Fix the backups.md path layout**

Change the layout line (~26) from:

```
gs://<bucket>/<env>/YYYY/MM/DD/HHMM.pgdump
```

to:

```
gs://<bucket>/<cluster-name>/dump/YYYY/MM/DD/HHMM.pgdump
```

and the two listing examples (~48-49) from:

```sh
gcloud storage ls "gs://${bucket}/preview/"
gcloud storage ls "gs://${bucket}/prod/"
```

to:

```sh
gcloud storage ls "gs://${bucket}/trakrf-db-preview/dump/"
gcloud storage ls "gs://${bucket}/trakrf-db-prod/dump/"
```

- [ ] **Step 3: Fix the restore usage and manual-restore procedure**

Change the usage block (~55-56) from `just db-restore-test           # preview by default` / `just db-restore-test prod` to:

```sh
just db-restore-test preview
just db-restore-test prod
```

In the manual-restore steps, change the "download the dump you want from `gs://<bucket>/<env>/`" reference to `gs://<bucket>/trakrf-db-<env>/dump/`.

- [ ] **Step 4: Fix the stale trakrf-system references**

- The "`trakrf-system` namespace" reference (~103) describing where the CronJob runs → the CronJob now runs in `trakrf-preview` / `trakrf-prod`.
- The WI paragraph (~155-157) → the Cluster pod SAs are `trakrf-preview/trakrf-db-preview` and `trakrf-prod/trakrf-db-prod`; the scratch restore SA `trakrf-system/trakrf-restore-test` is still accurate, keep it.
- The inspection commands (~167-183) → `kubectl -n trakrf-<env> describe cluster trakrf-db-<env>`, `kubectl -n trakrf-<env> get scheduledbackup`, `kubectl -n trakrf-<env> get backup --sort-by=.status.startedAt`. Note beside them that `just db-status <env>` covers the common case.
- The base/WAL listing examples (~175-176) → `gs://<bucket>/trakrf-db-<env>/base/` and `.../wals/`.
- The PITR description (~197) → it recovers one env's object store into a scratch cluster in `trakrf-system` and checks the single `trakrf` database.

- [ ] **Step 5: Verify no stale paths survive**

Run: `grep -n 'gs://\${bucket}/\(preview\|prod\)/\|<bucket>/<env>/\|trakrf_preview\|trakrf_prod' docs/backups.md docs/ops.md`
Expected: no output.

Run: `grep -rn "Currently broken" docs/`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add docs/ops.md docs/backups.md
git commit -m "docs(tra-1059): correct restore docs for cluster-per-env topology

Removes the ops.md §9 broken-recipe caveat and fixes backups.md's GCS
path layout, trakrf-system references, and the two-database PITR check."
```

---

### Task 7: Execute the restore proofs

**Files:** none — this is the acceptance criterion. The point of these recipes is that they have been *run*, not that they parse.

**Interfaces:**
- Consumes: every prior task.
- Produces: the evidence recorded in the PR body.

- [ ] **Step 1: Preview logical restore**

Run: `just db-restore-test preview`

Expected, in order: latest dump path under `trakrf-db-preview/dump/2026/07/…`; a downloaded file of non-trivial size; `CREATE DATABASE`; the pre-restore call; `pg_restore` completing; the post-restore call; a `\dn` listing that includes the `trakrf` schema; a rowcount table with **non-zero** `n_live_tup` on the main tables; `DROP DATABASE`; the completion line.

Record the rowcount table — it goes in the PR body. A restore that completes with every count at zero is a failed proof, not a passed one.

- [ ] **Step 2: Preview PITR restore**

Run: `just db-restore-pitr-test preview`

Expected: leftover-cluster pre-delete; the scratch Cluster applied; `cluster.postgresql.cnpg.io/trakrf-restore-test condition met` within the 10-minute wait; `\l` listing a `trakrf` database; non-zero rowcounts; teardown; the completion line.

If the wait times out, run `kubectl -n trakrf-system describe cluster trakrf-restore-test` and check the recovery job logs before assuming a recipe bug — a bad `serverName` shows up as barman failing to find the backup catalog.

- [ ] **Step 3: Check prod headroom before touching prod**

Run:

```bash
kubectl -n trakrf-prod exec trakrf-db-prod-1 -c postgres -- df -h /var/lib/postgresql/data
gcloud storage ls -l "gs://trakrf-demo-usc1-cnpg-backups-ok97/trakrf-db-prod/dump/**/*.pgdump" | sort -k2 | tail -1
```

Report both numbers before proceeding. The restore lands a full copy of prod's data on the single-instance live prod primary's PVC. If free space is not comfortably greater than several times the compressed dump size, stop and raise it rather than proceeding.

- [ ] **Step 4: Prod logical restore**

Run: `just db-restore-test prod`

You will be prompted to type `prod` to continue — that is `confirm_prod` working. Same expectations as Step 1, against `trakrf-db-prod`. Confirm the scratch database is actually gone afterward:

```bash
just psql prod
```

then `\l` and check no `trakrf_restore_test_*` database remains. `\q` to exit.

- [ ] **Step 5: Prod PITR restore**

Run: `just db-restore-pitr-test prod`

Same expectations as Step 2, recovering from `trakrf-db-prod`. No live-prod blast radius. Confirm the scratch cluster is torn down: `kubectl -n trakrf-system get cluster` should show none.

- [ ] **Step 6: Record the evidence**

Collect the four run transcripts (trimmed to the meaningful lines) for the PR body. The PR must show that all four ran, not that the code looks right.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| §1 live-cluster resolution, no tofu | 3, 4 |
| §2 `cnpg_primary_pod` helper + ops-lib test | 1, 2 |
| §3 `db-restore-test ENV` + confirm_prod + path fix | 3 |
| §4 `db-restore-pitr-test ENV` + per-env serverName + single-DB check | 4 |
| §5 `db-pitr-trigger-base ENV` | 5 |
| §6 docs (ops.md §9, backups.md) | 6 |
| Testing §1-5 (parse, ops-lib, 4 live runs) | 1, 3, 4, 5, 7 |
| Risk: prod disk headroom | 7 Step 3 |

No gaps.

**Placeholder scan:** No TBD/TODO, no "similar to Task N", no "add error handling". Every code step carries the literal text to write.

**Type consistency:** `cnpg_primary_pod <ns>` is defined in Task 1 and called with exactly one namespace argument in Tasks 2, 3, and 4. `require_env` / `confirm_prod` signatures match `scripts/ops-lib.sh` as it exists today. Variable names are consistent within each recipe (`ns`/`cluster` in Task 3 and 5; `src_ns`/`src_cluster`/`ns`/`scratch` in Task 4, where the scratch cluster's namespace and the source env's namespace are deliberately different variables).
