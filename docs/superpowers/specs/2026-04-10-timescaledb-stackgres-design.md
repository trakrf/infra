# TRA-353: StackGres + TimescaleDB on EKS

## Overview

Deploy a TimescaleDB instance on EKS using the StackGres operator. Replaces the initial CrunchyData PGO approach after discovering PGO cannot use the `timescaledb-ha` image without a custom build (no `securityContext` field in the PostgresCluster CRD).

StackGres manages TimescaleDB as a dynamic extension with TSL license enabled via config parameter — no custom images needed.

**Blocked by:** TRA-355 (ArgoCD install + GitOps manifests)
**Blocks:** TRA-354 (TrakRF application Helm charts — needs database connection secrets)

## Why StackGres over PGO / CloudNativePG

| Criterion | PGO | CloudNativePG | StackGres |
|-----------|-----|---------------|-----------|
| TimescaleDB TSL | Custom image required | UID workarounds + backup concerns | Config parameter. Done. |
| Extension management | Manual / baked in image | Manual / baked in image | Dynamic, 200+ extensions |
| Security context | Not exposed in CRD | Full control | Managed internally |
| Built-in PgBouncer | Add-on | No | Sidecar by default |
| License | Apache 2.0 | Apache 2.0 | AGPL-3.0 (fine for running, not forking) |

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Operator | StackGres 1.18.6 | Dynamic extension loading, TSL license via config, no custom image |
| TimescaleDB license | TSL (`timescaledb.license = 'timescale'`) | Continuous aggregates and compression in use |
| Postgres version | 17 | Latest stable |
| Manifest approach | Raw YAML in `argocd/clusters/trakrf-db/` | Same pattern as before, just different CRDs |
| Instance topology | Single instance | Demo scope |
| Backup | Deferred | Same as before — no S3 config yet |
| User passwords | Kubernetes Secrets created via kubectl, referenced by SGScript | Not in git, created as one-time setup step |

## Architecture

```
ArgoCD (app-of-apps)
  ├── stackgres-operator       (new) → StackGres Helm chart in stackgres namespace
  └── trakrf-db                (new) → argocd/clusters/trakrf-db/
                                         ├── sgpostgresconfig.yaml
                                         ├── sginstanceprofile.yaml
                                         ├── sgscript.yaml
                                         └── sgcluster.yaml
```

Operator runs in `stackgres` namespace. Cluster resources deploy to `trakrf-db` namespace.

## Files to Create

### `argocd/applications/stackgres-operator.yaml`

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

### `argocd/applications/trakrf-db.yaml`

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

### `argocd/clusters/trakrf-db/sgpostgresconfig.yaml`

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

### `argocd/clusters/trakrf-db/sginstanceprofile.yaml`

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

### `argocd/clusters/trakrf-db/sgscript.yaml`

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

### `argocd/clusters/trakrf-db/sgcluster.yaml`

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

## Files to Remove

- `argocd/applications/crunchy-postgres.yaml`
- `argocd/applications/timescaledb-cluster.yaml`
- `argocd/clusters/timescaledb/postgrescluster.yaml`

## Files to Modify

### `argocd/projects/trakrf.yaml`

- Add `https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/` to sourceRepos
- Remove `registry.developers.crunchydata.com/crunchydata/*` and `registry.developers.crunchydata.com/crunchydata` from sourceRepos
- Add `stackgres` and `trakrf-db` to destinations
- Remove `crunchy-postgres` from destinations

### `terraform/aws/iam.tf`

- Remove or comment out the `crunchy_irsa` module (no longer needed)

## One-Time Setup (not in git)

Create the password secret before or after the cluster deploys. The SGScript will retry until the secret exists.

```bash
kubectl create namespace trakrf-db  # if not yet created by ArgoCD

kubectl create secret generic trakrf-db-passwords -n trakrf-db \
  --from-literal=set-app-password.sql="ALTER ROLE \"trakrf-app\" PASSWORD '$(openssl rand -base64 24)';" \
  --from-literal=set-migrate-password.sql="ALTER ROLE \"trakrf-migrate\" PASSWORD '$(openssl rand -base64 24)';"
```

## Auto-Created Secrets

StackGres creates a secret named after the cluster (`trakrf-cluster`) with keys:

| Key | Description |
|-----|-------------|
| `superuser-username` | `postgres` |
| `superuser-password` | Auto-generated |
| `replication-username` | Replication user |
| `replication-password` | Auto-generated |
| `authenticator-username` | PgBouncer authenticator |
| `authenticator-password` | Auto-generated |

## Out of Scope

- S3 backups (deferred — needs SGObjectStorage CRD + IRSA policy)
- HA / multi-instance (single instance for demo)
- Monitoring / Grafana integration (deferred)
- Web console ingress (use port-forward for now)

## Acceptance Criteria

1. StackGres operator running in `stackgres` namespace
2. `trakrf-db` ArgoCD Application syncs successfully
3. `trakrf-cluster` SGCluster reaches Ready state
4. TimescaleDB extension loaded: `SELECT extname FROM pg_extension WHERE extname = 'timescaledb'` returns a row
5. `trakrf` database exists
6. `trakrf-app` user can connect and run DML
7. `trakrf-migrate` user can connect and create schemas/tables
8. `trakrf-cluster` secret exists with superuser credentials
