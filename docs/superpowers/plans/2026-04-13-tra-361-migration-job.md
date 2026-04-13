# TRA-361 Migration Job Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Helm pre-install/pre-upgrade Job to `helm/trakrf-backend` that runs `golang-migrate` against the CNPG `trakrf-db` cluster, bootstrapping schema so the ingester stops erroring on `pq: relation "trakrf.identifier_scans" does not exist`.

**Architecture:** Helm hook Job in the existing `trakrf-backend` chart. Conditional image: use `.Values.migrate.image` if set (backend image, migrations baked in), else `migrate/migrate:v4.17.0` with migrations mounted from a ConfigMap. ConfigMap rendered from `helm/trakrf-backend/migrations/*.sql`, synced from `../platform/backend/migrations/` via a `just` target. DSN built via `$(VAR)` env interpolation from `trakrf-migrate-credentials`.

**Tech Stack:** Helm 3, `golang-migrate` v4, CNPG, bash/just, kubectl.

**Spec:** `docs/superpowers/specs/2026-04-13-tra-361-migration-job-design.md`

**Branch:** `feature/tra-361-migration-job`

---

## File Structure

**Create:**
- `helm/trakrf-backend/templates/migrate-job.yaml` — the Job (Helm hook)
- `helm/trakrf-backend/templates/migrate-configmap.yaml` — ConfigMap with SQL files (rendered only on fallback path)
- `helm/trakrf-backend/migrations/` — directory; populated by `just sync-migrations` (gitignored? no — committed for ArgoCD to see)
- `helm/trakrf-backend/.helmignore` additions if needed (none expected)

**Modify:**
- `helm/trakrf-backend/values.yaml` — add `migrate:` block
- `justfile` — add `sync-migrations` recipe
- `helm/trakrf-backend/Chart.yaml` — bump `version` to `0.2.0`

---

### Task 1: Branch + scaffolding

**Files:** none yet — setup only.

- [ ] **Step 1: Create branch from up-to-date main**

```bash
cd /home/mike/trakrf-infra
git checkout main && git pull --ff-only
git checkout -b feature/tra-361-migration-job
```

- [ ] **Step 2: Confirm prerequisites exist**

```bash
kubectl -n trakrf get secret trakrf-migrate-credentials -o jsonpath='{.data.username}' | base64 -d && echo
kubectl -n trakrf get svc trakrf-db-rw
helm lint helm/trakrf-backend
```

Expected: username prints (e.g., `trakrf-migrate`), service exists, lint passes with 0 errors.

If `trakrf-migrate-credentials` is missing, stop and create per `project_cnpg_secrets.md` memory — it's user-supplied post-cluster.

---

### Task 2: Add `sync-migrations` just recipe

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Append recipe to justfile**

Add at the end of `/home/mike/trakrf-infra/justfile`:

```
# Sync platform backend migrations into the trakrf-backend chart (TRA-361 temporary path).
# Remove once migrate.image points at the backend image published by TRA-363.
sync-migrations:
    @echo "Syncing migrations from ../platform/backend/migrations/ → helm/trakrf-backend/migrations/"
    @mkdir -p helm/trakrf-backend/migrations
    @rsync -av --delete --include='*.up.sql' --exclude='*' ../platform/backend/migrations/ helm/trakrf-backend/migrations/
    @ls helm/trakrf-backend/migrations/ | wc -l | xargs -I{} echo "Synced {} migration files"
```

Note: only `*.up.sql` is synced — `golang-migrate up` only uses up files, and excluding `.down.sql` keeps the ConfigMap smaller.

- [ ] **Step 2: Run it and verify**

```bash
just sync-migrations
ls helm/trakrf-backend/migrations/ | head
ls helm/trakrf-backend/migrations/ | wc -l
du -sh helm/trakrf-backend/migrations/
```

Expected: ~24 files, numbered `000001_*.up.sql` through `0000NN_*.up.sql`, size well under 1 MiB (ConfigMap hard limit).

- [ ] **Step 3: Commit**

```bash
git add justfile helm/trakrf-backend/migrations/
git commit -m "chore(tra-361): add sync-migrations recipe and snapshot migrations

Syncs platform/backend/migrations/*.up.sql into the chart. Temporary
path until TRA-363 publishes the backend image to GHCR."
```

---

### Task 3: Add `migrate` values

**Files:**
- Modify: `helm/trakrf-backend/values.yaml`

- [ ] **Step 1: Append migrate block to values.yaml**

Add after the existing `database:` block in `helm/trakrf-backend/values.yaml`:

```yaml
# Schema migration Job (TRA-361).
# When `image` is unset, a ConfigMap is rendered from helm/trakrf-backend/migrations/
# and mounted into a generic migrate/migrate image.
# When `image` is set (e.g., once TRA-363 publishes the backend image with migrations baked
# in at /app/db/migrations), the ConfigMap is skipped and that image is used directly.
migrate:
  enabled: true
  image: ""                            # e.g., ghcr.io/trakrf/backend:sha-abc123
  defaultImage: migrate/migrate:v4.17.0
  credentialsSecret: trakrf-migrate-credentials
  # Connection target — separate from `database:` because `database:` is the app role (trakrf-app),
  # while migrations run as trakrf-migrate.
  user: trakrf-migrate
  host: trakrf-db-rw
  port: 5432
  database: trakrf
  sslmode: require
```

- [ ] **Step 2: Render the chart and confirm no errors**

```bash
helm template trakrf-backend helm/trakrf-backend > /tmp/render-task3.yaml
echo "Exit: $?"
grep -c '^---' /tmp/render-task3.yaml
```

Expected: exit 0; same resource count as before (we haven't added templates yet).

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-backend/values.yaml
git commit -m "feat(tra-361): add migrate values block"
```

---

### Task 4: Add migrations ConfigMap template (fallback path)

**Files:**
- Create: `helm/trakrf-backend/templates/migrate-configmap.yaml`

- [ ] **Step 1: Write template**

Create `helm/trakrf-backend/templates/migrate-configmap.yaml`:

```yaml
{{- if and .Values.migrate.enabled (not .Values.migrate.image) }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "trakrf-backend.fullname" . }}-migrations
  labels:
    {{- include "trakrf-backend.labels" . | nindent 4 }}
    app.kubernetes.io/component: migrate
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-10"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
data:
{{ (.Files.Glob "migrations/*.up.sql").AsConfig | indent 2 }}
{{- end }}
```

- [ ] **Step 2: Render and assert the ConfigMap appears when image unset**

```bash
helm template trakrf-backend helm/trakrf-backend > /tmp/render-task4a.yaml
grep -A2 'kind: ConfigMap' /tmp/render-task4a.yaml | head -20
grep -c 'kind: ConfigMap' /tmp/render-task4a.yaml
```

Expected: at least 2 ConfigMaps (the pre-existing app config + the new migrations one). The migrations one has name `trakrf-backend-migrations` and `hook: pre-install,pre-upgrade`.

- [ ] **Step 3: Render with image set and assert the ConfigMap is gone**

```bash
helm template trakrf-backend helm/trakrf-backend --set migrate.image=ghcr.io/trakrf/backend:test > /tmp/render-task4b.yaml
grep 'trakrf-backend-migrations' /tmp/render-task4b.yaml || echo "ConfigMap correctly absent"
```

Expected: `ConfigMap correctly absent`.

- [ ] **Step 4: Spot-check one SQL payload is present in the ConfigMap data**

```bash
grep -A1 '000001_prereqs.up.sql:' /tmp/render-task4a.yaml | head -3
```

Expected: the file key appears, followed by SQL content (`CREATE EXTENSION IF NOT EXISTS timescaledb;` or similar).

- [ ] **Step 5: Commit**

```bash
git add helm/trakrf-backend/templates/migrate-configmap.yaml
git commit -m "feat(tra-361): add migrations ConfigMap (fallback path)"
```

---

### Task 5: Add migration Job template

**Files:**
- Create: `helm/trakrf-backend/templates/migrate-job.yaml`

- [ ] **Step 1: Write template**

Create `helm/trakrf-backend/templates/migrate-job.yaml`:

```yaml
{{- if .Values.migrate.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "trakrf-backend.fullname" . }}-migrate
  labels:
    {{- include "trakrf-backend.labels" . | nindent 4 }}
    app.kubernetes.io/component: migrate
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        {{- include "trakrf-backend.labels" . | nindent 8 }}
        app.kubernetes.io/component: migrate
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: {{ .Values.migrate.image | default .Values.migrate.defaultImage | quote }}
          imagePullPolicy: IfNotPresent
          env:
            - name: PGUSER
              value: {{ .Values.migrate.user | quote }}
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.migrate.credentialsSecret }}
                  key: password
            - name: PG_URL
              value: "postgresql://$(PGUSER):$(PGPASSWORD)@{{ .Values.migrate.host }}:{{ .Values.migrate.port }}/{{ .Values.migrate.database }}?sslmode={{ .Values.migrate.sslmode }}"
          {{- if .Values.migrate.image }}
          # Backend image path: migrations baked into image at /app/db/migrations (TRA-363).
          command: ["migrate"]
          args: ["-path", "/app/db/migrations", "-database", "$(PG_URL)", "up"]
          {{- else }}
          # Fallback path: migrate/migrate image + ConfigMap mount.
          command: ["migrate"]
          args: ["-path", "/migrations", "-database", "$(PG_URL)", "up"]
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
{{- end }}
```

Notes for reviewer:
- `PGUSER` is passed as a plain env value, not from the secret's `username` key — the CNPG-managed secret stores `username` and `password`, but we control the user via values so we don't depend on the secret's key layout for the username. `password` is pulled from the secret by key `password`.
- `$(VAR)` interpolation requires the referenced vars to be declared *earlier* in the `env` list. Order matters: PGUSER, PGPASSWORD, then PG_URL.

- [ ] **Step 2: Lint the chart**

```bash
helm lint helm/trakrf-backend
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 3: Render fallback path and verify Job structure**

```bash
helm template trakrf-backend helm/trakrf-backend > /tmp/render-task5a.yaml
awk '/kind: Job/,/^---/' /tmp/render-task5a.yaml | head -60
```

Expected: one Job named `trakrf-backend-migrate`, image `migrate/migrate:v4.17.0`, has `volumeMounts: /migrations`, `args` contains `-path /migrations`, hook annotations present.

- [ ] **Step 4: Render backend-image path and verify Job swaps correctly**

```bash
helm template trakrf-backend helm/trakrf-backend --set migrate.image=ghcr.io/trakrf/backend:sha-abc > /tmp/render-task5b.yaml
awk '/kind: Job/,/^---/' /tmp/render-task5b.yaml | head -60
```

Expected: image is `ghcr.io/trakrf/backend:sha-abc`, no `volumeMounts`, no `volumes`, `args` contains `-path /app/db/migrations`.

- [ ] **Step 5: Render with migrate disabled**

```bash
helm template trakrf-backend helm/trakrf-backend --set migrate.enabled=false > /tmp/render-task5c.yaml
grep -E 'trakrf-backend-migrate|trakrf-backend-migrations' /tmp/render-task5c.yaml || echo "Both resources correctly absent"
```

Expected: `Both resources correctly absent`.

- [ ] **Step 6: Commit**

```bash
git add helm/trakrf-backend/templates/migrate-job.yaml
git commit -m "feat(tra-361): add pre-install/pre-upgrade migration Job"
```

---

### Task 6: Bump chart version

**Files:**
- Modify: `helm/trakrf-backend/Chart.yaml`

- [ ] **Step 1: Bump version**

Edit `helm/trakrf-backend/Chart.yaml`: change `version: 0.1.0` to `version: 0.2.0`.

- [ ] **Step 2: Commit**

```bash
git add helm/trakrf-backend/Chart.yaml
git commit -m "chore(tra-361): bump trakrf-backend chart to 0.2.0"
```

---

### Task 7: Deploy and verify live

**Files:** none — operational.

- [ ] **Step 1: Dry-run server-side against the live cluster**

```bash
helm upgrade --install trakrf-backend helm/trakrf-backend \
  --namespace trakrf \
  --dry-run --debug \
  2>&1 | tee /tmp/tra-361-dryrun.log | tail -80
```

Expected: exit 0, no validation errors. Hook resources shown in output.

If you have a `values.secret.yaml` from previous work, pass it: `-f values.secret.yaml`.

- [ ] **Step 2: Apply for real**

```bash
helm upgrade --install trakrf-backend helm/trakrf-backend \
  --namespace trakrf \
  --wait --timeout 5m
```

Expected: Helm waits for the Job to complete before rolling out the Deployment. Exit 0 on success.

- [ ] **Step 3: Inspect Job logs**

```bash
kubectl -n trakrf get jobs
kubectl -n trakrf logs -l app.kubernetes.io/component=migrate --tail=200
```

Expected: logs show `golang-migrate` applying migrations sequentially (or "no change" on re-runs). No connection errors.

If the Job was already deleted by the hook-delete-policy, capture logs next run by passing `--set migrate.debugKeep=true` — but that's not implemented; just re-run if needed.

- [ ] **Step 4: Verify schema exists**

```bash
kubectl -n trakrf exec trakrf-db-1 -c postgres -- psql -U postgres -d trakrf -c "\dt trakrf.*" | head -20
kubectl -n trakrf exec trakrf-db-1 -c postgres -- psql -U postgres -d trakrf -c "SELECT count(*) FROM trakrf.identifier_scans;"
```

Expected: table list shows `trakrf.identifier_scans` (and others); count query returns a number without error.

- [ ] **Step 5: Confirm ingester recovers**

```bash
kubectl -n trakrf logs -l app.kubernetes.io/name=trakrf-ingester --tail=100 | grep -iE 'error|identifier_scans' | tail -20
```

Expected: the `pq: relation "trakrf.identifier_scans" does not exist` errors have stopped appearing in recent logs (may need to wait a few seconds).

- [ ] **Step 6: Idempotency check — re-run**

```bash
helm upgrade trakrf-backend helm/trakrf-backend --namespace trakrf --wait --timeout 5m
kubectl -n trakrf logs -l app.kubernetes.io/component=migrate --tail=50
```

Expected: Job succeeds, logs show `no change` (or equivalent golang-migrate "already up to date" output).

---

### Task 8: Document, PR, close

**Files:**
- Modify: `helm/trakrf-backend/README.md` (create if absent)

- [ ] **Step 1: Add/update README with migration notes**

Create or append `helm/trakrf-backend/README.md`:

```markdown
## Migrations (TRA-361)

This chart runs database migrations as a Helm `pre-install,pre-upgrade` hook Job.

### Fallback path (current default)

- SQL files live in `helm/trakrf-backend/migrations/*.up.sql`.
- Sync from platform: `just sync-migrations` (run in repo root).
- Uses image `migrate/migrate:v4.17.0`.
- Files are rendered into a ConfigMap and mounted into the Job.

### Backend-image path (target after TRA-363)

Set `migrate.image` to the backend image tag:

    helm upgrade ... --set migrate.image=ghcr.io/trakrf/backend:sha-<x>

The Job will use the backend image directly and read migrations from `/app/db/migrations`. The fallback ConfigMap is skipped.

### Recovering from a dirty migration

If `golang-migrate` marks a version dirty, connect as `trakrf-migrate` and run:

    migrate -path <dir> -database "$PG_URL" force <version>

then re-run `helm upgrade`.
```

- [ ] **Step 2: Commit and push**

```bash
git add helm/trakrf-backend/README.md
git commit -m "docs(tra-361): chart README migration notes"
git push -u origin feature/tra-361-migration-job
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --title "feat(tra-361): schema migration Job for trakrf-backend" --body "$(cat <<'EOF'
## Summary
- Adds Helm pre-install/pre-upgrade Job that runs `golang-migrate` as `trakrf-migrate` role.
- Fallback path: `migrate/migrate:v4.17.0` + ConfigMap built from `helm/trakrf-backend/migrations/`.
- Switch path: set `migrate.image=ghcr.io/trakrf/backend:sha-<x>` once TRA-363 publishes.
- Unblocks ingester: stops `pq: relation "trakrf.identifier_scans" does not exist` errors.

Design spec: `docs/superpowers/specs/2026-04-13-tra-361-migration-job-design.md`
Plan: `docs/superpowers/plans/2026-04-13-tra-361-migration-job.md`
Closes TRA-361.

## Test plan
- [x] `helm lint` passes
- [x] `helm template` renders cleanly on fallback and backend-image paths
- [x] `helm upgrade --install` completes, Job succeeds in `trakrf` ns
- [x] `trakrf.identifier_scans` exists and is queryable
- [x] Ingester recovers (no more missing-relation errors)
- [x] Re-running `helm upgrade` is a no-op for migrations (idempotent)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Merge with `--merge` style after review**

```bash
gh pr merge --merge
```

Per CLAUDE.md: never `--squash` or `--rebase`.

- [ ] **Step 5: Mark TRA-361 done in Linear**

Update status via MCP or UI. Add a comment linking the merged PR.

---

## Risk notes

- **timescaledb extension:** `000001_prereqs.up.sql` runs `CREATE EXTENSION IF NOT EXISTS timescaledb`. If the CNPG image does not ship this, Task 7 Step 3 will fail with `ERROR: extension "timescaledb" is not available`. Mitigation if encountered: confirm CNPG image is `ghcr.io/cloudnative-pg/postgresql` with the timescaledb variant (e.g., `cloudnative-pg/postgis` has it, stock `cnpg-pg16` does not). If missing, either (a) swap CNPG imageName in the Cluster resource to a timescaledb-enabled variant and re-bootstrap, or (b) patch `000001` to make the extension optional — but (b) is a platform-repo change, out of scope. Flag and stop if you hit this.
- **Large ConfigMap:** current migrations total ~50 KiB, well under the 1 MiB etcd object limit. If platform adds seed data that pushes past ~900 KiB, this fallback stops being viable and we must rely on TRA-363's image instead.
- **Secret key naming:** uses `password` as the secret key. Verify with `kubectl -n trakrf get secret trakrf-migrate-credentials -o jsonpath='{.data}' | jq 'keys'` before Task 7. If it's `pgpassword` or something else, fix the `secretKeyRef.key` in Task 5.

## Coordination with TRA-363

If TRA-363 merges in the parallel session before this PR merges:

- Skip Task 2 (no `sync-migrations` needed).
- Skip Task 4 (no ConfigMap needed) — delete the file from the plan deliverables.
- In Task 3, set `migrate.image: ghcr.io/trakrf/backend:<tag>` as the default in `values.yaml`.
- In Task 5, simplify the template by removing the fallback branch.

If this PR merges first, a follow-up ticket flips the default per the spec's "Coordination" section.

## Self-Review

- Spec §Architecture → Task 5 (Job template)
- Spec §Components (Job) → Task 5
- Spec §Components (ConfigMap) → Task 4
- Spec §Components (migrations dir) → Task 2
- Spec §Components (values.yaml) → Task 3
- Spec §Components (justfile target) → Task 2
- Spec §Schema bootstrap safeguard → **not required**: verified `000001_prereqs.up.sql` already contains `CREATE SCHEMA IF NOT EXISTS trakrf`. No `000000` file needed.
- Spec §Data flow → Task 7 (verify)
- Spec §Error handling → Task 8 README, Risk notes above
- Spec §Testing/verification → Task 7
- Spec §TRA-363 coordination → "Coordination with TRA-363" section above
- Spec §Out of scope → respected
