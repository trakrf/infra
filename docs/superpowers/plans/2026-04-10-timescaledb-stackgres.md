# TRA-353: StackGres + TimescaleDB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace CrunchyData PGO with StackGres operator and deploy a TimescaleDB instance with full TSL features on EKS.

**Architecture:** StackGres operator installed via Helm (ArgoCD Application), cluster resources as raw YAML synced by a second ArgoCD Application. TimescaleDB enabled as a dynamic extension with TSL license via config parameter.

**Tech Stack:** StackGres 1.18.6, PostgreSQL 17, TimescaleDB (TSL), ArgoCD GitOps, gp3 EBS storage

**Spec:** `docs/superpowers/specs/2026-04-10-timescaledb-stackgres-design.md`

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Remove | `argocd/applications/crunchy-postgres.yaml` | PGO operator Application (replaced) |
| Remove | `argocd/applications/timescaledb-cluster.yaml` | PGO cluster Application (replaced) |
| Remove | `argocd/clusters/timescaledb/postgrescluster.yaml` | PGO PostgresCluster CRD (replaced) |
| Modify | `argocd/projects/trakrf.yaml` | Update sourceRepos and destinations |
| Modify | `terraform/aws/iam.tf` | Remove crunchy_irsa module |
| Create | `argocd/applications/stackgres-operator.yaml` | StackGres operator Helm Application |
| Create | `argocd/applications/trakrf-db.yaml` | ArgoCD Application for cluster manifests |
| Create | `argocd/clusters/trakrf-db/sgpostgresconfig.yaml` | PG config with TimescaleDB |
| Create | `argocd/clusters/trakrf-db/sginstanceprofile.yaml` | Resource limits |
| Create | `argocd/clusters/trakrf-db/sgscript.yaml` | Init script: users, DB, extension |
| Create | `argocd/clusters/trakrf-db/sgcluster.yaml` | The database cluster |

---

### Task 1: Remove PGO resources and update AppProject

**Files:**
- Remove: `argocd/applications/crunchy-postgres.yaml`
- Remove: `argocd/applications/timescaledb-cluster.yaml`
- Remove: `argocd/clusters/timescaledb/postgrescluster.yaml`
- Modify: `argocd/projects/trakrf.yaml`

- [ ] **Step 1: Delete PGO Application files**

```bash
rm argocd/applications/crunchy-postgres.yaml
rm argocd/applications/timescaledb-cluster.yaml
rm -r argocd/clusters/timescaledb/
```

- [ ] **Step 2: Update AppProject sourceRepos and destinations**

In `argocd/projects/trakrf.yaml`, replace the CrunchyData sourceRepos with StackGres and update namespace destinations:

**sourceRepos** — remove:
```yaml
    - "registry.developers.crunchydata.com/crunchydata/*"
    - "registry.developers.crunchydata.com/crunchydata"
```

**sourceRepos** — add:
```yaml
    - "https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/"
```

**destinations** — remove:
```yaml
    - server: https://kubernetes.default.svc
      namespace: crunchy-postgres
```

**destinations** — add:
```yaml
    - server: https://kubernetes.default.svc
      namespace: stackgres
    - server: https://kubernetes.default.svc
      namespace: trakrf-db
```

- [ ] **Step 3: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/projects/trakrf.yaml'))" && echo "YAML valid"
```

- [ ] **Step 4: Commit**

```bash
git add -A argocd/
git commit -m "chore: remove PGO resources, update AppProject for StackGres"
```

---

### Task 2: Remove CrunchyData IRSA stub from Terraform

**Files:**
- Modify: `terraform/aws/iam.tf`

- [ ] **Step 1: Remove the crunchy_irsa module**

Remove the entire `module "crunchy_irsa"` block (lines 19-33) from `terraform/aws/iam.tf`.

- [ ] **Step 2: Run tofu plan to verify**

```bash
tofu -chdir=terraform/aws plan
```

Expected: Plan shows removal of the `crunchy_irsa` IAM role resources. No other changes.

- [ ] **Step 3: Commit** (do NOT apply yet — apply after PR merge)

```bash
git add terraform/aws/iam.tf
git commit -m "chore(aws): remove CrunchyData IRSA stub, no longer needed"
```

---

### Task 3: Create StackGres operator ArgoCD Application

**Files:**
- Create: `argocd/applications/stackgres-operator.yaml`

- [ ] **Step 1: Create the Application manifest**

Create `argocd/applications/stackgres-operator.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: stackgres-operator
  namespace: argocd
spec:
  project: trakrf
  source:
    repoURL: https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/
    chart: stackgres-operator
    targetRevision: "1.18.6"
    helm:
      releaseName: stackgres-operator
      valuesObject:
        grafana:
          autoEmbed: false
  destination:
    server: https://kubernetes.default.svc
    namespace: stackgres
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/applications/stackgres-operator.yaml'))" && echo "YAML valid"
```

- [ ] **Step 3: Commit**

```bash
git add argocd/applications/stackgres-operator.yaml
git commit -m "feat(stackgres): add StackGres operator ArgoCD Application"
```

---

### Task 4: Create StackGres cluster manifests

**Files:**
- Create: `argocd/clusters/trakrf-db/sgpostgresconfig.yaml`
- Create: `argocd/clusters/trakrf-db/sginstanceprofile.yaml`
- Create: `argocd/clusters/trakrf-db/sgscript.yaml`
- Create: `argocd/clusters/trakrf-db/sgcluster.yaml`

- [ ] **Step 1: Create SGPostgresConfig**

Create `argocd/clusters/trakrf-db/sgpostgresconfig.yaml`:

```yaml
apiVersion: stackgres.io/v1
kind: SGPostgresConfig
metadata:
  name: trakrf-pgconfig
  namespace: trakrf-db
spec:
  postgresVersion: "17"
  postgresql.conf:
    shared_preload_libraries: 'pg_stat_statements,auto_explain,timescaledb'
    timescaledb.license: 'timescale'
    shared_buffers: '256MB'
    work_mem: '16MB'
    password_encryption: 'scram-sha-256'
```

- [ ] **Step 2: Create SGInstanceProfile**

Create `argocd/clusters/trakrf-db/sginstanceprofile.yaml`:

```yaml
apiVersion: stackgres.io/v1
kind: SGInstanceProfile
metadata:
  name: trakrf-profile
  namespace: trakrf-db
spec:
  cpu: "2"
  memory: "4Gi"
  requests:
    cpu: "500m"
    memory: "1Gi"
```

- [ ] **Step 3: Create SGScript**

Create `argocd/clusters/trakrf-db/sgscript.yaml`:

```yaml
apiVersion: stackgres.io/v1beta1
kind: SGScript
metadata:
  name: trakrf-init
  namespace: trakrf-db
spec:
  managedVersions: true
  continueOnError: false
  scripts:
    - name: create-app-user
      script: |
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'trakrf-app') THEN
            CREATE ROLE "trakrf-app" LOGIN;
          END IF;
        END $$;
    - name: set-app-password
      scriptFrom:
        secretKeyRef:
          name: trakrf-db-passwords
          key: set-app-password.sql
    - name: create-migrate-user
      script: |
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'trakrf-migrate') THEN
            CREATE ROLE "trakrf-migrate" LOGIN CREATEDB;
          END IF;
        END $$;
    - name: set-migrate-password
      scriptFrom:
        secretKeyRef:
          name: trakrf-db-passwords
          key: set-migrate-password.sql
    - name: create-database
      script: |
        SELECT 'CREATE DATABASE trakrf OWNER "trakrf-migrate"'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'trakrf')
        \gexec
    - name: enable-timescaledb
      database: trakrf
      script: |
        CREATE EXTENSION IF NOT EXISTS timescaledb;
    - name: grant-app-access
      database: trakrf
      script: |
        GRANT CONNECT ON DATABASE trakrf TO "trakrf-app";
        GRANT USAGE ON SCHEMA public TO "trakrf-app";
        ALTER DEFAULT PRIVILEGES FOR ROLE "trakrf-migrate"
          IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "trakrf-app";
```

- [ ] **Step 4: Create SGCluster**

Create `argocd/clusters/trakrf-db/sgcluster.yaml`:

```yaml
apiVersion: stackgres.io/v1
kind: SGCluster
metadata:
  name: trakrf-cluster
  namespace: trakrf-db
spec:
  postgres:
    version: '17'
    extensions:
      - name: timescaledb
  instances: 1
  sgInstanceProfile: trakrf-profile
  pods:
    persistentVolume:
      size: '10Gi'
      storageClass: gp3
  configurations:
    sgPostgresConfig: trakrf-pgconfig
  managedSql:
    scripts:
      - id: 1
        sgScript: trakrf-init
  postgresServices:
    primary:
      type: ClusterIP
    replicas:
      type: ClusterIP
```

- [ ] **Step 5: Validate all YAML files**

```bash
for f in argocd/clusters/trakrf-db/*.yaml; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "$f: valid" || echo "$f: INVALID"
done
```

- [ ] **Step 6: Commit**

```bash
git add argocd/clusters/trakrf-db/
git commit -m "feat(stackgres): add SGCluster manifests for TimescaleDB instance"
```

---

### Task 5: Create ArgoCD Application for the cluster

**Files:**
- Create: `argocd/applications/trakrf-db.yaml`

- [ ] **Step 1: Create the Application manifest**

Create `argocd/applications/trakrf-db.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trakrf-db
  namespace: argocd
spec:
  project: trakrf
  source:
    repoURL: https://github.com/trakrf/infra.git
    path: argocd/clusters/trakrf-db
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: trakrf-db
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('argocd/applications/trakrf-db.yaml'))" && echo "YAML valid"
```

- [ ] **Step 3: Verify app-of-apps discovery**

```bash
ls argocd/applications/
```

Expected: `argocd.yaml  stackgres-operator.yaml  trakrf-backend.yaml  trakrf-db.yaml`

- [ ] **Step 4: Commit**

```bash
git add argocd/applications/trakrf-db.yaml
git commit -m "feat(argocd): add trakrf-db Application for StackGres cluster"
```

---

### Task 6: Push branch and create PR

- [ ] **Step 1: Push**

```bash
git push -u origin feat/tra-353-stackgres-timescaledb
```

- [ ] **Step 2: Create PR**

```bash
gh pr create \
  --title "feat(stackgres): replace PGO with StackGres for TimescaleDB on EKS" \
  --body "$(cat <<'EOF'
## Summary
- Remove CrunchyData PGO operator and broken PostgresCluster manifests
- Add StackGres operator (v1.18.6) via ArgoCD Helm Application
- Add SGCluster with TimescaleDB extension (TSL licensed — continuous aggregates, compression)
- Three database users: `postgres` (superuser, auto), `trakrf-app` (DML), `trakrf-migrate` (DDL)
- Remove CrunchyData IRSA stub from Terraform

**Why the switch:** PGO's CRD does not expose securityContext, making it impossible to use
the `timescaledb-ha` image (non-numeric UID). StackGres handles TimescaleDB as a dynamic
extension with TSL license enabled via config parameter — no custom image needed.

Closes TRA-353
Folds in TRA-85 (separate migration user from app user)

## Pre-merge: create password secret
```bash
kubectl create namespace trakrf-db
kubectl create secret generic trakrf-db-passwords -n trakrf-db \
  --from-literal=set-app-password.sql="ALTER ROLE \"trakrf-app\" PASSWORD '$(openssl rand -base64 24)';" \
  --from-literal=set-migrate-password.sql="ALTER ROLE \"trakrf-migrate\" PASSWORD '$(openssl rand -base64 24)';"
```

## Post-merge: apply Terraform
```bash
just aws
```

## Test plan
- [ ] StackGres operator running in `stackgres` namespace
- [ ] `trakrf-db` ArgoCD Application syncs successfully
- [ ] `trakrf-cluster` SGCluster reaches Ready state
- [ ] TimescaleDB extension loaded with TSL license
- [ ] `trakrf` database exists
- [ ] `trakrf-app` user can connect and run DML
- [ ] `trakrf-migrate` user can connect and create schemas/tables
- [ ] `trakrf-cluster` secret exists with superuser credentials

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

### Task 7: Post-merge deployment and verification

These steps run after the PR merges and ArgoCD syncs.

- [ ] **Step 1: Create the password secret**

```bash
kubectl create namespace trakrf-db 2>/dev/null || true

kubectl create secret generic trakrf-db-passwords -n trakrf-db \
  --from-literal=set-app-password.sql="ALTER ROLE \"trakrf-app\" PASSWORD '$(openssl rand -base64 24)';" \
  --from-literal=set-migrate-password.sql="ALTER ROLE \"trakrf-migrate\" PASSWORD '$(openssl rand -base64 24)';"
```

- [ ] **Step 2: Apply Terraform to remove IRSA stub**

```bash
just aws
```

Expected: Removes the `crunchy_irsa` IAM role. No other changes.

- [ ] **Step 3: Wait for StackGres operator to be ready**

```bash
kubectl wait -n stackgres deployment -l group=stackgres.io --for=condition=Available --timeout=300s
```

- [ ] **Step 4: Verify SGCluster is running**

```bash
kubectl get sgcluster trakrf-cluster -n trakrf-db
kubectl get pods -n trakrf-db -l app=StackGresCluster,stackgres.io/cluster-name=trakrf-cluster
```

Expected: Cluster listed, pod(s) Running.

- [ ] **Step 5: Verify TimescaleDB extension with TSL license**

```bash
PGPASSWORD=$(kubectl get secret trakrf-cluster -n trakrf-db -o jsonpath='{.data.superuser-password}' | base64 -d)

kubectl run -n trakrf-db psql-test --rm -it --restart=Never \
  --image=postgres:17 -- \
  psql "host=trakrf-cluster port=5432 dbname=trakrf user=postgres password=$PGPASSWORD" \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';" \
  -c "SHOW timescaledb.license;"
```

Expected: Extension exists, license shows `timescale`.

- [ ] **Step 6: Verify trakrf-app user connectivity**

```bash
APP_PASS=$(kubectl get secret trakrf-db-passwords -n trakrf-db -o jsonpath='{.data.set-app-password\.sql}' | base64 -d | grep -oP "PASSWORD '\K[^']+")

kubectl run -n trakrf-db psql-app-test --rm -it --restart=Never \
  --image=postgres:17 -- \
  psql "host=trakrf-cluster port=5432 dbname=trakrf user=trakrf-app password=$APP_PASS" \
  -c "SELECT 1;"
```

Expected: Returns `1`.

- [ ] **Step 7: Verify trakrf-migrate user can create tables**

```bash
MIG_PASS=$(kubectl get secret trakrf-db-passwords -n trakrf-db -o jsonpath='{.data.set-migrate-password\.sql}' | base64 -d | grep -oP "PASSWORD '\K[^']+")

kubectl run -n trakrf-db psql-mig-test --rm -it --restart=Never \
  --image=postgres:17 -- \
  psql "host=trakrf-cluster port=5432 dbname=trakrf user=trakrf-migrate password=$MIG_PASS" \
  -c "CREATE TABLE _verify_test (id serial PRIMARY KEY, ts timestamptz NOT NULL); DROP TABLE _verify_test;"
```

Expected: Table created and dropped successfully.
