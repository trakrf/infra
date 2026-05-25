# TRA-823 — GKE multi-env DB tenancy on shared CNPG

**Status:** Design
**Date:** 2026-05-24
**Blocks:** TRA-375 (M3 production cutover), TRA-825 (preview cutover to GKE)
**Related:** TRA-365 (postInitApplicationSQL grants), TRA-362 (External Secrets/Infisical), TRA-278 (configurable schema — canceled), TRA-810 (data cutover), TRA-544 (DB HA), TRA-798 (backups)

## Context

Consolidating both `preview` and `prod` onto the shared GKE CNPG cluster using namespace-per-env apps and DB-per-env on a single Cluster. The `trakrf-backend` and `trakrf-ingester` charts already parameterize `database.name`, `database.host`, and `database.credentialsSecret`, so per-env app releases are largely a values overlay plus a namespace. Three pieces of the DB layer are missing before the cluster can host more than one env cleanly:

1. **Declarative additional databases.** CNPG runs `initdb` exactly once and bootstraps only the single `trakrf` database; schema/grants/default-privileges from `postInitApplicationSQL` do not apply to subsequently created databases.
2. **Per-env role split.** `trakrf-app` and `trakrf-migrate` are shared managed roles, so they are the same identity in every database — a compromised preview app could authenticate against prod.
3. **Cross-namespace credential availability.** The CNPG `managed.roles[].passwordSecret` reads from the Cluster's own namespace; app pods in `trakrf-preview` / `trakrf-prod` cannot mount a Secret in `trakrf-system`.

Schema-per-env is explicitly rejected — DB-per-env is the stronger isolation boundary and layering both buys nothing. The `trakrf` schema is retained as-is; dropping it would be the ~113-site change of the (canceled) TRA-278 for zero operational gain once DB-level isolation exists.

## Out of scope

- Schema-per-env. Dropping the `trakrf` schema.
- DB HA / replicas (TRA-544, TRA-375 intent item 1).
- Backups (TRA-798).
- The data cutover itself (TRA-810).
- Whitelabel dedicated Cluster.
- External Secrets / Infisical end-state (TRA-362) — TRA-823 ships reflector as a transitional mirror; ESO can later take over without changing app charts since the consumed Secret name stays the same.
- HTTPS reachability of soak hostnames. Cert issuance against `trakrf.id` from GKE cert-manager (Cloudflare zone, Cloud DNS solver mismatch), Cloudflare-vs-`.app` strategic decision, ACME CNAME delegation pattern for canonical hosts at cutover, DNS records for any temp hosts. All deferred to a paired/follow-up ticket ahead of TRA-825. Backend/ingester env overlays set `ingress.enabled: false`; verification is via `kubectl exec` + port-forward.

## Approach — full clean cutover

Tear down `trakrf` namespace, rebuild with separated DB-infra and app-env namespaces. Data loss is acceptable (current GKE preview data is reload-OK). This is preferred over additive carry-on of the existing `trakrf` ns because the per-env role split is cleanest when shared roles never coexist with per-env roles, and reload-OK removes the in-place migration constraint that would otherwise force an additive path.

### End-state namespace layout

```
trakrf-system     CNPG Cluster `trakrf-db` (1 instance)
                  Database CRDs: trakrf_preview, trakrf_prod
                  Managed roles (passwordSecrets in this ns):
                    trakrf-app-preview, trakrf-app-prod,
                    trakrf-migrate-preview, trakrf-migrate-prod
                  4 credential Secrets, each annotated for reflector
                  Init Jobs (Helm post-install hook), one per DB

trakrf-preview    trakrf-backend (DSN → trakrf_preview, user trakrf-app-preview)
                  trakrf-ingester (same DSN)
                  Mirrored Secrets:
                    trakrf-app-preview-credentials
                    trakrf-migrate-preview-credentials

trakrf-prod       trakrf-backend (DSN → trakrf_prod, user trakrf-app-prod)
                  trakrf-ingester (same DSN)
                  Mirrored Secrets:
                    trakrf-app-prod-credentials
                    trakrf-migrate-prod-credentials

reflector         emberstack/reflector (cluster-scoped, installed via
                  Helm Application at sync wave -1)
```

The old `trakrf` namespace and Cluster PVCs are destroyed during cutover. Service DNS for backend/ingester → Postgres becomes `trakrf-db-rw.trakrf-system.svc.cluster.local`.

## Components

### `helm/trakrf-db/` (largest delta)

**`values.yaml`** — restructured around an `envs:` list. The legacy `managedRoles:` block is removed; roles are derived from `envs:`. `bootstrap.initdb.database` becomes `trakrf_preview` and `bootstrap.initdb.owner` becomes `trakrf-migrate-preview`. The `bootstrap.initdb.postInitApplicationSQL` block is dropped from the Cluster — schema/grants now run via the per-DB init Jobs so the bootstrap path and the second-DB path use one source of truth.

```yaml
envs:
  - name: preview
    database: trakrf_preview
    appRole: trakrf-app-preview
    migrateRole: trakrf-migrate-preview
    appSecret: trakrf-app-preview-credentials
    migrateSecret: trakrf-migrate-preview-credentials
    reflectTo: trakrf-preview
  - name: prod
    database: trakrf_prod
    appRole: trakrf-app-prod
    migrateRole: trakrf-migrate-prod
    appSecret: trakrf-app-prod-credentials
    migrateSecret: trakrf-migrate-prod-credentials
    reflectTo: trakrf-prod
```

**`templates/cluster.yaml`** — `managed.roles:` ranges over `.Values.envs` to emit four roles (one app + one migrate per env). Each role's `passwordSecret.name` references the role-name-matching Secret (`{appRole}` → `{appSecret}`, `{migrateRole}` → `{migrateSecret}`). Existing `ignoreDifferences` on `managedFieldsManagers: ["manager"]` (in `argocd/root/templates/trakrf-db.yaml`) continues to mask CNPG-operator-filled defaults on the new roles.

**`templates/databases.yaml`** (new) — one `postgresql.cnpg.io/v1` `Database` per entry in `.Values.envs`. Naming distinction (matters for kubectl vs psql):

- K8s `metadata.name` uses hyphen form: `trakrf-preview`, `trakrf-prod` (DNS-1123 compliant).
- `spec.name` is the Postgres DB name with underscore: `trakrf_preview`, `trakrf_prod`.

The `initdb`-bootstrapped `trakrf_preview` is declared with `ensure: present` so it reconciles into the model without recreation. `spec.owner` is the env's migrate role.

**`templates/init-grants-job.yaml`** (new) — one Helm `post-install,post-upgrade` hook Job per env (`hook-weight: 5`, `hook-delete-policy: before-hook-creation,hook-succeeded`). Image: `ghcr.io/cloudnative-pg/postgresql:17.2` (ships psql). Runs in `trakrf-system` namespace. Mounts the env's migrate `passwordSecret` from the same namespace and connects to `trakrf-db-rw` as the migrate role against the env's Postgres database, then runs idempotent SQL:

```sql
CREATE SCHEMA IF NOT EXISTS trakrf AUTHORIZATION "{{ .migrateRole }}";
GRANT CONNECT ON DATABASE {{ .database }} TO "{{ .appRole }}";
GRANT USAGE ON SCHEMA trakrf TO "{{ .appRole }}";
ALTER DEFAULT PRIVILEGES FOR ROLE "{{ .migrateRole }}" IN SCHEMA trakrf
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{{ .appRole }}";
ALTER DEFAULT PRIVILEGES FOR ROLE "{{ .migrateRole }}" IN SCHEMA trakrf
  GRANT USAGE, SELECT ON SEQUENCES TO "{{ .appRole }}";
ALTER ROLE "{{ .appRole }}" SET app.current_org_id = '0';
```

All statements are idempotent and safe to re-run on every chart upgrade. The grants match the corrected TRA-365 pattern (`trakrf` schema, not `public`).

### `helm/reflector/` (new)

Thin Application wrapper pointing at the upstream `emberstack/helm-charts` reflector chart, `targetRevision` pinned. The Application itself is templated from `argocd/root/templates/reflector.yaml` at sync wave `-1`.

### `argocd/root/`

**`values.yaml`** — drops `namespaces.trakrf`. Adds:
```yaml
namespaces:
  trakrfSystem: trakrf-system
  trakrfPreview: trakrf-preview
  trakrfProd: trakrf-prod
```

**`templates/reflector.yaml`** (new) — Application for the reflector chart, sync wave `-1`.

**`templates/trakrf-db.yaml`** — namespace switches to `.Values.namespaces.trakrfSystem`. Sync wave stays `0`. Existing `ignoreDifferences` block carries forward unchanged.

**`templates/trakrf-backend.yaml`, `templates/trakrf-ingester.yaml`** — each wraps the existing helper call in a `range $env := list "preview" "prod"`. Application name becomes `trakrf-backend-{{ $env }}` / `trakrf-ingester-{{ $env }}`. `namespace` is `trakrf-{{ $env }}`. `inlineValues` injects:
- `database.name`
- `database.credentialsSecret`
- `migrate.database`
- `migrate.credentialsSecret`
- `config.appEnv` (`preview` or `prod`)
- `ingress.enabled: false`

### `helm/trakrf-backend/`, `helm/trakrf-ingester/`

No template changes. Existing values keys already parameterize the right knobs. Per-env injection happens at the Application level via `inlineValues`.

### `justfile`

**`db-secrets`** extends to:
1. Create `trakrf-system`, `trakrf-preview`, `trakrf-prod` namespaces (idempotent).
2. Read four passwords from `.env.local`: `TRAKRF_APP_DB_PASSWORD_PREVIEW`, `TRAKRF_APP_DB_PASSWORD_PROD`, `TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW`, `TRAKRF_MIGRATE_DB_PASSWORD_PROD`.
3. Apply four Secrets in `trakrf-system`, each annotated:
   ```
   reflector.v1.k8s.emberstack.com/reflection-allowed=true
   reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true
   reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-<env>
   ```

Passwords use `openssl rand -hex` per `feedback_db_password_alphabet` to avoid `/+` breaking URL-composed DSNs.

## Bootstrap order (ArgoCD sync waves)

```
wave -1   reflector              cluster-wide operator
wave  0   trakrf-db              CNPG Cluster `trakrf-db` in trakrf-system ns
                                   → initdb creates `trakrf_preview` DB
                                   → CNPG reconciles 4 managed roles
                                     (reads passwordSecrets in trakrf-system)
                                   → CNPG Database CRDs reconcile:
                                     trakrf_preview ensure=present (no-op),
                                     trakrf_prod created
                                   → Helm post-install Jobs run per env:
                                     psql Job applies schema + grants
                                   → reflector mirrors annotated secrets
                                     into trakrf-preview + trakrf-prod
wave  1   trakrf-backend-preview backend in trakrf-preview ns
                                   → migrate Job as trakrf-migrate-preview
                                   → Deployment mounts trakrf-app-preview-credentials
wave  1   trakrf-backend-prod    backend in trakrf-prod ns (analogous)
wave  1   trakrf-ingester-*      same fan-out
```

**User-supplied prerequisites** before sync:
1. `just db-secrets` creates the four annotated Secrets in `trakrf-system`.
2. `.env.local` carries the four passwords.

## Failure and recovery

| Failure | Symptom | Recovery |
|---|---|---|
| `just db-secrets` skipped | Managed roles stuck PendingReconciliation; apps fail to authenticate | Run `db-secrets`; CNPG reconciles within ~60s |
| reflector not installed before wave 0 | Backend pods CrashLoopBackOff on Secret mount | Reflector at wave -1 makes this rare; once reflector watches catch up, next pod restart succeeds |
| Init Job SQL failure | Chart upgrade Degraded in ArgoCD | SQL is idempotent and re-runs on retry; worst case `kubectl delete job` and re-sync |
| Password rotation | Mounted Secret stale until pod restart | Re-run `just db-secrets`; manual `kubectl rollout restart deploy` per env. Automating this is TRA-362 |
| Reflector uninstalled mid-flight | Env-namespace mirrors stop updating | Reinstall via Application |

**Rebuild story** (data-loss-OK): blowing away `trakrf-system`, `trakrf-preview`, `trakrf-prod` and re-syncing reaches the same end state. PVCs in `trakrf-system` are deleted, DBs come back empty, migrations re-run.

## Drift suppression

The Cluster spec has fields filled by the CNPG operator after admission (`connectionLimit`, `inRoles`, `inherit`, `podAntiAffinityType`). The existing `argocd/root/templates/trakrf-db.yaml` `ignoreDifferences` on `managedFieldsManagers: ["manager"]` continues to filter these for the new managed roles. No new ignore rules needed.

## Testing & verification

Acceptance criteria mapped to concrete checks:

### AC: each env DB created declaratively

```bash
kubectl get database -n trakrf-system
# expect: trakrf-preview, trakrf-prod (k8s names, hyphens) both Ready
kubectl get database trakrf-preview -n trakrf-system -o jsonpath='{.status.ready}'
# expect: true
```

### AC: schema and grants correct

Exec into the CNPG primary:
```bash
kubectl exec -n trakrf-system trakrf-db-1 -- psql -d trakrf_preview -c "\dn"
# expect: trakrf schema present, owner trakrf-migrate-preview
kubectl exec -n trakrf-system trakrf-db-1 -- psql -d trakrf_preview -c "\du"
# expect: trakrf-app-preview, trakrf-migrate-preview present with LOGIN
```

Connect as the app role through the mirrored Secret:
```bash
PW=$(kubectl get secret -n trakrf-preview trakrf-app-preview-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl run --rm -it --restart=Never psql-preview --image=postgres:17 -n trakrf-preview \
  --env=PGPASSWORD="$PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app-preview -d trakrf_preview \
  -c "SELECT has_schema_privilege('trakrf-app-preview', 'trakrf', 'USAGE');"
# expect: t
```

End-to-end: backend migrate Job per env Succeeded; backend `/healthz` returns 200 via port-forward.

### AC: per-env isolation (negative test)

Preview credential against prod DB:
```bash
PREV_PW=$(kubectl get secret -n trakrf-preview trakrf-app-preview-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl run --rm -it --restart=Never psql-neg --image=postgres:17 -n trakrf-prod \
  --env=PGPASSWORD="$PREV_PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app-preview -d trakrf_prod -c "SELECT 1;"
# expect: connection refused
```

The failure manifests at the `CONNECT` privilege layer (the role has CONNECT on `trakrf_preview` only) rather than auth. Either failure mode satisfies the AC; the test author should expect a privilege error, not a password error.

Symmetric test with the prod role against preview DB.

### AC: backend in each namespace mounts its own credential

```bash
kubectl logs -n trakrf-preview deploy/trakrf-backend | grep -E 'DB|connected'
kubectl logs -n trakrf-preview job/trakrf-backend-migrate
kubectl exec -n trakrf-preview deploy/trakrf-backend -- printenv | grep '^PG_URL'
# expect: PG_URL=postgres://trakrf-app-preview:...@trakrf-db-rw.trakrf-system:5432/trakrf_preview?...
```
Repeat against `-prod`.

### AC: ArgoCD diff additive and Healthy

```bash
argocd app list | grep -E 'trakrf|reflector'
# expect: reflector, trakrf-db, trakrf-backend-preview, trakrf-backend-prod,
#         trakrf-ingester-preview, trakrf-ingester-prod — all Synced+Healthy
```

The self-managed `argocd` Application stays cosmetic-OOS per `feedback_argocd_self_app_outofsync`.

### Pre-merge dry-run

```bash
helm template helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml
helm template helm/reflector -f helm/reflector/values.yaml
# Smoke-test inlineValues injection by rendering trakrf-backend with sample values
```

## Open questions

None at design time. The cert/DNS punt is intentional; a paired ticket will own the temp soak hostnames and cert issuance before TRA-825 cutover requires HTTPS-reachable env URLs.
