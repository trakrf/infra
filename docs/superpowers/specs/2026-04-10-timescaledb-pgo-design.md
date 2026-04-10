# TRA-353: CrunchyData Postgres Operator + TimescaleDB on EKS

## Overview

Deploy a TimescaleDB instance on EKS using the CrunchyData Postgres Operator (PGO). This replaces TimescaleDB Cloud for cost optimization (TRA-269) and sets up proper user separation from the start (TRA-85).

**Blocked by:** TRA-355 (ArgoCD install + GitOps manifests) — PGO operator must be running first.
**Blocks:** TRA-354 (TrakRF application Helm charts) — backend needs database connection secrets.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Operator | CrunchyData PGO | Already selected in TRA-144 context, operator Application already exists |
| Container image | `timescale/timescaledb-ha:pg17` | Full TSL-licensed TimescaleDB (continuous aggregates, compression). CrunchyData's own images only ship the Apache 2.0 community edition which lacks these features. Floating tag tracks latest PG17 + TimescaleDB — acceptable for demo. Pin to a specific tag (e.g., `pg17.9-ts2.26.1`) for production. |
| Postgres version | 17 | Latest stable, matches timescaledb-ha image |
| Manifest approach | Raw YAML in `argocd/clusters/timescaledb/` | Simplest for single demo cluster, no premature Helm/Kustomize abstraction |
| Instance topology | Single replica | Demo scope. Patroni HA activates when replicas > 1 |
| Backup | Local pgBackRest volume only | S3 backup deferred. Local repo keeps the cluster healthy without AWS policy wiring |
| User separation | Three users: postgres, trakrf-app, trakrf-migrate | Folds in TRA-85. PGO manages credentials as K8s Secrets |

## Architecture

```
ArgoCD (app-of-apps)
  ├── crunchy-postgres        (existing) → PGO operator Helm chart
  └── timescaledb-cluster     (new)      → argocd/clusters/timescaledb/
                                              └── postgrescluster.yaml
```

Both Applications deploy to the `crunchy-postgres` namespace. The operator Application installs the PGO controller; the cluster Application creates the PostgresCluster CRD instance that the controller reconciles.

## New Files

### `argocd/applications/timescaledb-cluster.yaml`

ArgoCD Application that syncs the PostgresCluster manifests from this repo.

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

- No `CreateNamespace=true` — PGO operator Application already creates `crunchy-postgres`.
- ServerSideApply for CRD-based resources (matches existing PGO Application pattern).
- Targets `main` branch — changes land via PR, ArgoCD auto-syncs.

### `argocd/clusters/timescaledb/postgrescluster.yaml`

The PostgresCluster CRD defining the TimescaleDB instance.

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

## Users & Secrets

PGO auto-generates a Kubernetes Secret per user in `crunchy-postgres` namespace:

| Secret name | Contents | Consumer |
|-------------|----------|----------|
| `trakrf-db-pguser-postgres` | superuser credentials | Emergency admin access |
| `trakrf-db-pguser-trakrf-app` | host, port, dbname, user, password, URI | TrakRF backend (TRA-354) |
| `trakrf-db-pguser-trakrf-migrate` | host, port, dbname, user, password, URI | Migration jobs |

The backend Application (TRA-354) will mount `trakrf-db-pguser-trakrf-app` as environment variables. Migrations use `trakrf-db-pguser-trakrf-migrate`.

`trakrf-migrate` has `CREATEDB` which is broader than strict DDL-only. For demo this is acceptable. Production would use a post-init SQL script to grant specific schema ownership instead.

## Storage

| Volume | Size | StorageClass | Purpose |
|--------|------|-------------|---------|
| pgdata (instance1) | 10Gi | gp3 (encrypted EBS) | Database data + WAL |
| pgbackrest repo1 | 5Gi | gp3 (encrypted EBS) | Local backup repository |

WAL is co-located with data (no separate volume). Separate WAL volume is a production optimization.

## Existing Infrastructure (no changes needed)

- **PGO operator Application** (`argocd/applications/crunchy-postgres.yaml`) — already deploys PGO v5.* from CrunchyData Helm registry.
- **AppProject** (`argocd/projects/trakrf.yaml`) — `crunchy-postgres` namespace already in destinations, this repo already in sourceRepos.
- **IRSA stub** (`terraform/aws/iam.tf`) — `trakrf-demo-crunchy-operator` role exists with empty policy. No changes needed until S3 backups are added.
- **StorageClass** — `gp3` is the default, encrypted, with `WaitForFirstConsumer` binding.
- **EBS CSI driver** — installed as EKS addon with functional IRSA role.

## Out of Scope

- **S3 backups** — local pgBackRest only. S3 requires IRSA policy + second pgBackRest repo entry.
- **HA / multi-replica** — single instance for demo. Bump `replicas: 2+` for Patroni failover.
- **PgBouncer connection pooling** — PGO supports it natively. Not needed until backend is under load.
- **Prometheus metrics** — PGO can export metrics. Deferred since kube-prometheus was removed from app-of-apps.
- **Fine-grained SQL RBAC** — `CREATEDB` is sufficient for demo. Production would use post-init SQL.
- **Terraform changes** — IRSA stub and gp3 StorageClass already exist.

## Acceptance Criteria

1. PGO operator is running in `crunchy-postgres` namespace (prerequisite from TRA-355)
2. `timescaledb-cluster` ArgoCD Application syncs successfully
3. `trakrf-db` PostgresCluster reaches `Ready` state
4. TimescaleDB extension is available: `CREATE EXTENSION IF NOT EXISTS timescaledb` succeeds
5. Three user secrets exist in `crunchy-postgres` namespace
6. `trakrf-app` user can connect and run DML but not DDL
7. `trakrf-migrate` user can connect and create schemas/tables
8. pgBackRest local backup completes without error
