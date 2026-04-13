# TRA-361 — Schema migration Job for `helm/trakrf-backend`

**Status:** Design approved 2026-04-13
**Ticket:** [TRA-361](https://linear.app/trakrf/issue/TRA-361)
**Parent:** TRA-351 (M1 EKS)
**Related:** TRA-354 (chart scaffolding, closed), TRA-363 (platform-repo GHCR CI, in progress in parallel session), TRA-278 (schema naming refactor, future)

## Context

The `trakrf-ingester` chart is deployed to EKS and logging continuous errors:

```
level=error msg="Failed to send message to sql_raw: pq: relation \"trakrf.identifier_scans\" does not exist"
```

The CNPG cluster (`trakrf-db` in namespace `trakrf`) has never had schema bootstrapped. On Railway, migrations ran via app-process `golang-migrate` at startup. On EKS the desired pattern is a dedicated Job so API pods don't race and don't need DDL privileges.

## Goal

Add a Helm-managed migration Job to `helm/trakrf-backend` that runs `golang-migrate` against the CNPG cluster using the `trakrf-migrate` role, blocks chart rollout on failure, and is idempotent on re-run.

## Design decisions (from brainstorm)

| Decision | Choice | Rationale |
|---|---|---|
| Hook mechanism | Helm `pre-install,pre-upgrade` hook | Portable; ArgoCD respects Helm hooks. Works with direct `helm install` for debugging. |
| Chart location | Inside `helm/trakrf-backend/templates/migrate-job.yaml` | Migrations version with the app schema; splitting charts invites version-mismatch confusion. |
| Image source | Conditional: backend image if `migrate.image` set, else `migrate/migrate:v4.17.0` + ConfigMap | Ships today without waiting for TRA-363; swaps to backend image (single source of truth) once GHCR publishes. |
| Migration files | Copied into chart at `helm/trakrf-backend/migrations/` via `just sync-migrations` | Explicit. Drift window is short (until TRA-363 lands). Symlinks break across repo boundary and ArgoCD. |
| Namespace | `trakrf` | Co-located with CNPG cluster per project layout. |
| Credentials | `trakrf-migrate-credentials` secret, `username`/`password` keys | User-supplied secret per `project_cnpg_secrets` memory. |
| DSN composition | `$(VAR)` env interpolation into `PG_URL` | Per `feedback_k8s_dsn_composition` memory. |

## Architecture

A Job runs as a Helm `pre-install,pre-upgrade` hook at weight `-5`. If no pre-built image with migrations is available, a companion ConfigMap (hook weight `-10`) mounts the SQL files into a generic `migrate/migrate` image. Helm deletes both after successful execution per `hook-delete-policy: before-hook-creation,hook-succeeded`.

### Components

#### `templates/migrate-job.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "trakrf-backend.fullname" . }}-migrate
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: {{ .Values.migrate.image | default .Values.migrate.defaultImage }}
          env:
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.migrate.credentialsSecret }}
                  key: username
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.migrate.credentialsSecret }}
                  key: password
            - name: PG_URL
              value: "postgresql://$(PGUSER):$(PGPASSWORD)@trakrf-db-rw:5432/trakrf?sslmode=require"
          {{- if .Values.migrate.image }}
          # Backend image path: migrations baked into image at /app/db/migrations
          command: ["migrate", "-path", "/app/db/migrations", "-database", "$(PG_URL)", "up"]
          {{- else }}
          # Fallback path: migrate/migrate image + ConfigMap mount
          command: ["migrate", "-path", "/migrations", "-database", "$(PG_URL)", "up"]
          volumeMounts:
            - name: migrations
              mountPath: /migrations
          {{- end }}
      {{- if not .Values.migrate.image }}
      volumes:
        - name: migrations
          configMap:
            name: {{ include "trakrf-backend.fullname" . }}-migrations
      {{- end }}
```

#### `templates/migrate-configmap.yaml` (rendered only when `migrate.image` unset)

```yaml
{{- if not .Values.migrate.image }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "trakrf-backend.fullname" . }}-migrations
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-10"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
data:
{{ (.Files.Glob "migrations/*.sql").AsConfig | indent 2 }}
{{- end }}
```

#### `migrations/` (chart directory)

SQL files synced from `../platform/backend/db/migrations/` via `just sync-migrations`. Only populated while on the fallback path. Deleted once `migrate.image` is the default.

**Schema bootstrap:** if `000001_*.up.sql` does not include `CREATE SCHEMA IF NOT EXISTS trakrf`, add `000000_init_schema.up.sql` to the chart's `migrations/` dir containing:

```sql
CREATE SCHEMA IF NOT EXISTS trakrf;
```

This is a chart-local safeguard; it does not modify the platform repo.

#### `values.yaml` additions

```yaml
migrate:
  enabled: true
  image: ""                           # set to ghcr.io/trakrf/backend:sha-xxx once TRA-363 publishes
  defaultImage: migrate/migrate:v4.17.0
  credentialsSecret: trakrf-migrate-credentials
```

#### `justfile` target

```
sync-migrations:
    rsync -av --delete ../platform/backend/db/migrations/ helm/trakrf-backend/migrations/
```

## Data flow

1. `helm upgrade --install trakrf-backend ...` → Helm renders hook resources.
2. ConfigMap (weight -10) applied — only on fallback path.
3. Job (weight -5) applied.
4. Pod starts, env vars resolve `PG_URL` via `$(PGUSER)`/`$(PGPASSWORD)` interpolation.
5. `golang-migrate` connects to `trakrf-db-rw:5432/trakrf`, acquires its advisory lock, applies pending migrations idempotently.
6. On success: Helm deletes hook resources; main chart rollout (backend Deployment) proceeds.
7. On failure: Job retries up to `backoffLimit: 2`; persistent failure → Helm release fails → backend rollout blocked.

## Error handling

- **DB unreachable:** Job pod crashes, backoff retries, Helm release eventually fails. Fix service/DNS/secret; re-run `helm upgrade`.
- **Bad migration SQL:** `golang-migrate` marks version dirty. Operator manually clears via `migrate force <version>` or fixes SQL and re-applies. Documented in chart README.
- **Schema missing:** `000000_init_schema.up.sql` safeguard creates it.

## Testing / verification

1. `helm template helm/trakrf-backend` renders cleanly with both `migrate.image` set and unset.
2. `helm install --dry-run --server-side` validates against live API.
3. `helm upgrade --install` in `trakrf` namespace.
4. `kubectl -n trakrf logs -l job-name=<release>-migrate -f` shows applied migrations.
5. **Acceptance:** ingester `pq: relation "trakrf.identifier_scans" does not exist` errors stop; `SELECT count(*) FROM trakrf.identifier_scans;` succeeds.
6. Re-run `helm upgrade` — Job runs again and migrations are no-ops (idempotency).

## TRA-363 coordination

TRA-363 (platform-repo GHCR publish) is in progress in a parallel session. Coordination plan:

- If TRA-363 lands **before** this PR is merged: skip `migrations/` dir and ConfigMap; ship with `migrate.image: ghcr.io/trakrf/backend:sha-xxx` as the default in `values.yaml`.
- If this PR merges **first**: ship fallback path; cut a follow-up PR to set `migrate.image`, delete `migrations/` dir and `migrate-configmap.yaml`, remove `just sync-migrations`.

Decision deferred to implementation time based on merge order.

## Out of scope

- Refactoring migrations themselves (TRA-278).
- Rollback tooling.
- Automated chart image-tag bump post-TRA-363 publish (manual follow-up).
- Any change to the platform repo or its migrations.
