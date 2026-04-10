# TRA-353: CrunchyData PGO + TimescaleDB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a TimescaleDB instance on EKS via CrunchyData PGO operator with three managed users (postgres, trakrf-app, trakrf-migrate).

**Architecture:** Two new ArgoCD-managed manifests: an Application resource that points to a directory of raw YAML, and a PostgresCluster CRD in that directory. The existing app-of-apps root Application auto-discovers new Applications from `argocd/applications/`. The existing PGO operator reconciles the PostgresCluster CRD.

**Tech Stack:** CrunchyData PGO v5, TimescaleDB HA image (pg17), ArgoCD GitOps, gp3 EBS storage

**Spec:** `docs/superpowers/specs/2026-04-10-timescaledb-pgo-design.md`

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `argocd/clusters/timescaledb/postgrescluster.yaml` | PostgresCluster CRD — defines the TimescaleDB instance, storage, users |
| Create | `argocd/applications/timescaledb-cluster.yaml` | ArgoCD Application — points to the clusters/timescaledb directory |

No modifications to existing files. The root Application (`argocd/root.yaml`) auto-discovers new files in `argocd/applications/`.

---

### Task 1: Create the PostgresCluster CRD manifest

**Files:**
- Create: `argocd/clusters/timescaledb/postgrescluster.yaml`

- [ ] **Step 1: Create the directory and PostgresCluster manifest**

Create `argocd/clusters/timescaledb/postgrescluster.yaml` with the following content:

```yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: trakrf-db
  namespace: crunchy-postgres
spec:
  image: timescale/timescaledb-ha:pg17
  postgresVersion: 17

  patroni:
    dynamicConfiguration:
      postgresql:
        parameters:
          shared_preload_libraries: timescaledb

  instances:
    - name: instance1
      replicas: 1
      dataVolumeClaimSpec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources:
          requests:
            storage: 10Gi

  backups:
    pgbackrest:
      repos:
        - name: repo1
          volume:
            volumeClaimSpec:
              accessModes: [ReadWriteOnce]
              storageClassName: gp3
              resources:
                requests:
                  storage: 5Gi

  users:
    - name: postgres
      databases: [trakrf]
    - name: trakrf-app
      databases: [trakrf]
      options: "NOSUPERUSER NOCREATEDB NOCREATEROLE"
    - name: trakrf-migrate
      databases: [trakrf]
      options: "NOSUPERUSER CREATEDB NOCREATEROLE"
```

- [ ] **Step 2: Validate the YAML syntax**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/clusters/timescaledb/postgrescluster.yaml'))" && echo "YAML valid"
```
Expected: `YAML valid`

- [ ] **Step 3: Commit**

```bash
git add argocd/clusters/timescaledb/postgrescluster.yaml
git commit -m "feat(pgo): add PostgresCluster CRD for TimescaleDB instance"
```

---

### Task 2: Create the ArgoCD Application manifest

**Files:**
- Create: `argocd/applications/timescaledb-cluster.yaml`

- [ ] **Step 1: Create the ArgoCD Application**

Create `argocd/applications/timescaledb-cluster.yaml` with the following content:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: timescaledb-cluster
  namespace: argocd
spec:
  project: trakrf
  source:
    repoURL: https://github.com/trakrf/infra.git
    path: argocd/clusters/timescaledb
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: crunchy-postgres
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

- [ ] **Step 2: Validate the YAML syntax**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/applications/timescaledb-cluster.yaml'))" && echo "YAML valid"
```
Expected: `YAML valid`

- [ ] **Step 3: Verify the Application will be discovered by the root app-of-apps**

The root Application (`argocd/root.yaml`) watches `argocd/applications/` with `directory.recurse: false`. Confirm the new file is at the correct depth:

```bash
ls argocd/applications/
```
Expected output includes: `argocd.yaml  crunchy-postgres.yaml  timescaledb-cluster.yaml  trakrf-backend.yaml`

- [ ] **Step 4: Verify AppProject allows the source and destination**

The `trakrf` AppProject (`argocd/projects/trakrf.yaml`) must allow:
- Source: `https://github.com/trakrf/infra.git` — check sourceRepos list
- Destination: `crunchy-postgres` namespace — check destinations list

Run:
```bash
grep -A2 "sourceRepos" argocd/projects/trakrf.yaml | grep "trakrf/infra"
grep "crunchy-postgres" argocd/projects/trakrf.yaml
```
Expected: both greps return matches (already confirmed in spec, this is a sanity check).

- [ ] **Step 5: Commit**

```bash
git add argocd/applications/timescaledb-cluster.yaml
git commit -m "feat(argocd): add timescaledb-cluster Application for app-of-apps"
```

---

### Task 3: Push branch and create PR

- [ ] **Step 1: Push the feature branch**

```bash
git push -u origin feat/tra-353-timescaledb-pgo
```

- [ ] **Step 2: Create the pull request**

```bash
gh pr create \
  --title "feat(pgo): CrunchyData PGO TimescaleDB cluster on EKS" \
  --body "$(cat <<'EOF'
## Summary
- Add PostgresCluster CRD for TimescaleDB instance (`trakrf-db`) using `timescale/timescaledb-ha:pg17` image
- Add ArgoCD Application to sync the cluster manifests via app-of-apps
- Three PGO-managed users: `postgres` (superuser), `trakrf-app` (DML only), `trakrf-migrate` (DDL capable)
- 10Gi gp3 data volume + 5Gi gp3 pgBackRest local backup volume

Closes TRA-353
Folds in TRA-85 (separate migration user from app user)

## Test plan
- [ ] PGO operator running in `crunchy-postgres` namespace (prerequisite TRA-355)
- [ ] `timescaledb-cluster` ArgoCD Application syncs successfully
- [ ] `trakrf-db` PostgresCluster reaches Ready state
- [ ] TimescaleDB extension available: `CREATE EXTENSION IF NOT EXISTS timescaledb` succeeds
- [ ] Three user secrets exist: `trakrf-db-pguser-postgres`, `trakrf-db-pguser-trakrf-app`, `trakrf-db-pguser-trakrf-migrate`
- [ ] `trakrf-app` user can connect and run DML
- [ ] `trakrf-migrate` user can connect and create schemas/tables
- [ ] pgBackRest local backup completes without error

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

### Task 4: Post-merge verification (run after PR merges and ArgoCD syncs)

These steps verify the acceptance criteria on the live cluster. They require `kubectl` access to the EKS cluster and depend on TRA-355 (ArgoCD + PGO operator) being deployed first.

- [ ] **Step 1: Verify the ArgoCD Application is synced and healthy**

```bash
kubectl get application timescaledb-cluster -n argocd -o jsonpath='{.status.sync.status}'
```
Expected: `Synced`

```bash
kubectl get application timescaledb-cluster -n argocd -o jsonpath='{.status.health.status}'
```
Expected: `Healthy`

- [ ] **Step 2: Verify the PostgresCluster is ready**

```bash
kubectl get postgrescluster trakrf-db -n crunchy-postgres -o jsonpath='{.status.conditions[?(@.type=="PGBackRestReplicaRepoReady")].status}'
```
Expected: `True` (indicates cluster is fully initialized including backup repo)

```bash
kubectl get pods -n crunchy-postgres -l postgres-operator.crunchydata.com/cluster=trakrf-db
```
Expected: Pod(s) in `Running` state with `Ready` condition.

- [ ] **Step 3: Verify user secrets were created**

```bash
kubectl get secrets -n crunchy-postgres -l postgres-operator.crunchydata.com/cluster=trakrf-db | grep pguser
```
Expected output includes:
```
trakrf-db-pguser-postgres         Opaque   ...
trakrf-db-pguser-trakrf-app       Opaque   ...
trakrf-db-pguser-trakrf-migrate   Opaque   ...
```

- [ ] **Step 4: Verify TimescaleDB extension works**

Port-forward to the database and test with psql:

```bash
kubectl port-forward -n crunchy-postgres svc/trakrf-db-primary 5432:5432 &
PF_PID=$!

# Get the postgres superuser password
PGPASSWORD=$(kubectl get secret trakrf-db-pguser-postgres -n crunchy-postgres -o jsonpath='{.data.password}' | base64 -d)

# Connect and create the extension
PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -U postgres -d trakrf -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"

# Verify it's loaded
PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -U postgres -d trakrf -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';"

kill $PF_PID
```
Expected: Extension created successfully, version shows TimescaleDB 2.x.

- [ ] **Step 5: Verify trakrf-app user connectivity**

```bash
kubectl port-forward -n crunchy-postgres svc/trakrf-db-primary 5432:5432 &
PF_PID=$!

PGPASSWORD=$(kubectl get secret trakrf-db-pguser-trakrf-app -n crunchy-postgres -o jsonpath='{.data.password}' | base64 -d)

# Should succeed — basic connectivity
PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -U trakrf-app -d trakrf -c "SELECT 1;"

kill $PF_PID
```
Expected: Query returns `1`.

- [ ] **Step 6: Verify trakrf-migrate user can create tables**

```bash
kubectl port-forward -n crunchy-postgres svc/trakrf-db-primary 5432:5432 &
PF_PID=$!

PGPASSWORD=$(kubectl get secret trakrf-db-pguser-trakrf-migrate -n crunchy-postgres -o jsonpath='{.data.password}' | base64 -d)

# Should succeed — DDL capability
PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -U trakrf-migrate -d trakrf -c "CREATE TABLE _verify_migrate_test (id serial PRIMARY KEY); DROP TABLE _verify_migrate_test;"

kill $PF_PID
```
Expected: Table created and dropped successfully.

- [ ] **Step 7: Verify pgBackRest backup**

```bash
kubectl exec -n crunchy-postgres -it $(kubectl get pods -n crunchy-postgres -l postgres-operator.crunchydata.com/cluster=trakrf-db,postgres-operator.crunchydata.com/role=master -o jsonpath='{.items[0].metadata.name}') -- pgbackrest info
```
Expected: Shows backup repo with at least one successful backup (PGO triggers an initial backup automatically).
