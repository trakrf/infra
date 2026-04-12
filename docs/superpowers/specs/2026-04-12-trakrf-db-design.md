# TRA-353: trakrf-db — TimescaleDB on EKS via CloudNativePG

## What's deployed

- **Operator:** CloudNativePG 0.28.x in `cnpg-system` namespace (installed via Helm, not ArgoCD — the operator's own Application will self-manage on next bump)
- **Cluster:** `trakrf-db` in `trakrf-db` namespace, 1 instance
- **Image:** `ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18` (Postgres 17.2 + TimescaleDB 2.18.1 with TSL license)
- **Storage:** 10Gi gp3 EBS
- **Users:** `trakrf-migrate` (DDL/owner), `trakrf-app` (DML only) — passwords in pre-created Secrets, managed via CNPG `managed.roles`
- **Database:** `trakrf` with `timescaledb` extension enabled, `timescaledb.license = 'timescale'`

Manifests are the source of truth:
- `argocd/applications/trakrf-db.yaml`
- `argocd/clusters/trakrf-db/cluster.yaml`

## Why CNPG + clevyr image

We evaluated three operators before landing here. Each had a dealbreaker with stock TimescaleDB:

| Operator | Blocker |
|----------|---------|
| CrunchyData PGO | No `securityContext` field in `PostgresCluster` CRD; can't adapt to `timescaledb-ha` image's non-numeric user |
| StackGres | Extension catalog ships Apache-only build (no `timescaledb-tsl-*.so` — breaks `add_retention_policy` etc.) |
| CloudNativePG + `timescaledb-ha` | Hardcoded PGDATA path conflicts with the image's `/home/postgres/pgdata` |

The `clevyr/cloudnativepg-timescale` community image solves the last one by building TimescaleDB on top of CNPG's own postgres base (correct PGDATA path, UID 26), installed from Timescale's official Debian apt repo (includes TSL).

## Known issues

- **Image pin is behind** — `17.5-ts2.19` and newer clevyr tags have a loader/extension version mismatch bug (see TRA-360). Staying on `17.2-ts2.18` until upstream is fixed.
- **Operator bootstrapped via Helm, not ArgoCD** — CNPG's pre-install hooks depend on CRDs the same chart installs, creating a chicken-and-egg problem with ArgoCD. See also: StackGres attempt hit the identical pattern. The operator runs self-managed via `helm` for now.

## Deferred work (separate tickets)

- S3 backups via `barmanObjectStore` + IRSA
- Multi-instance HA (currently 1 replica for demo)
- Ingress + ArgoCD GitHub webhook (to eliminate 3-minute sync polling)
- Upstream clevyr fix (TRA-360)
