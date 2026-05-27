# Cluster-per-env CNPG (preview half) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **History note.** Tasks 1–16 below preserve the original plan with env-suffixed names (`trakrf_preview`/`trakrf_prod`, `trakrf-app-preview`, etc.). After those tasks executed, a follow-up flatten dropped the env suffix from all DB/role/Secret names — see the spec's end-state and the **Task 18 — Operational cutover** section below for the final shape. Git log on the branch is the canonical reference.

**Goal:** Refactor `helm/trakrf-db` to single-env flat values, stand up a dedicated `trakrf-db-preview` CNPG Cluster co-located with backend + ingester in `trakrf-preview`, and repurpose the existing shared `trakrf-db` Application as env=prod-only using the same chart. Add stateful guardrails (`automated.prune: false` + PV `Retain`) and capture a migration runbook the prod-half ticket can reuse verbatim.

**Architecture:** Same `helm/trakrf-db` chart, no `envs:` loop. Per-release values overlay sets `database` / `roles` / `secrets` flat at top level. Two Argo Applications (`trakrf-db` for prod-on-shared, `trakrf-db-preview` for new dedicated). Backend + ingester preview env DSN repoints to the new Cluster. Tofu adds two new WI bindings against the existing `cnpg-backups-demo` GSA (preview cluster pod KSA + preview pg_dump KSA). The preview rebuild itself happens by operational runbook around merge — chart code lands first, data migration follows.

**Tech Stack:** OpenTofu + GCP provider, Helm, ArgoCD, CNPG 1.29, CloudNativePG-Timescale image, postgres_fdw (for migration source).

**Reference spec:** `docs/superpowers/specs/2026-05-27-tra-849-cluster-per-env-cnpg-design.md`

---

## File Structure

**Modified — Terraform:**
- `terraform/gcp/cnpg_backups.tf` — two new `google_service_account_iam_member` resources binding `trakrf-preview/trakrf-db-preview` and `trakrf-preview/cnpg-backups` KSAs to the existing `cnpg-backups-demo` GSA.

**Modified — Helm chart (`helm/trakrf-db/`):**
- `values.yaml` — drop `envs:` list; add flat `database`, `roles`, `secrets`; add `backups.dumpPrefix`; add `storage.createRetainClass`.
- `values-gke.yaml` — switch `storage.class: premium-rwo` → `premium-rwo-retain`.
- `templates/cluster.yaml` — single managed roles block; bootstrap initdb pulled from flat values.
- `templates/databases.yaml` — single Database CR with explicit `databaseReclaimPolicy: retain`.
- `templates/init-grants-job.yaml` — single Job; PGHOST derived from `fullnameOverride`.
- `templates/backup-cronjob.yaml` — single CronJob named `pg-dump`; uploads to `gs://<bucket>/<dumpPrefix>/...`.
- `templates/scheduled-backup.yaml` — uses flat `backups.cluster.serverName`.
- `templates/backup-serviceaccount.yaml` — unchanged.
- `templates/external-service-preview.yaml` — selector uses `fullnameOverride`.

**New — Helm chart:**
- `helm/trakrf-db/templates/storageclass-retain.yaml` — `premium-rwo-retain` StorageClass, gated on `storage.createRetainClass`.

**Modified — Root chart:**
- `argocd/root/templates/_helpers.tpl` — add optional `automatedPrune` parameter to `trakrf.application` helper.
- `argocd/root/templates/trakrf-db.yaml` — rebuild `inlineValues` as env=prod flat overlay; pass `automatedPrune: false`; drop the GKE-only externalPreview block (moves to new template).
- `argocd/root/templates/trakrf-db-preview.yaml` (new) — Application for new dedicated preview Cluster in `trakrf-preview`, env=preview overlay, externalPreview block, `automatedPrune: false`, `storage.createRetainClass: true`.
- `argocd/root/templates/trakrf-backend.yaml` — `$base` block for preview env uses `host: trakrf-db-preview-rw.trakrf-preview`.
- `argocd/root/templates/trakrf-ingester.yaml` — same DSN flip for the preview env.

**Modified — ArgoCD project:**
- `argocd/projects/trakrf.yaml` — add `storage.k8s.io/StorageClass` to `clusterResourceWhitelist`.

**Modified — Justfile:**
- `justfile` — `db-secrets` recipe reshape: preview secrets land in `trakrf-preview` ns without reflector annotations; prod secrets stay in `trakrf-system` with reflector. `_db-secret` helper gains a namespace + reflect-toggle parameter.

**New — Docs:**
- `docs/db-migration.md` — operator-facing migration runbook.
- `docs/superpowers/specs/2026-05-27-tra-849-cluster-per-env-cnpg-design.md` — already committed.
- `docs/superpowers/plans/2026-05-27-tra-849-cluster-per-env-cnpg.md` — this file.

---

## Task 1 — Tofu: two new WI bindings on the existing GSA

**Files:**
- Modify: `terraform/gcp/cnpg_backups.tf`

- [ ] **Step 1: Append two new `google_service_account_iam_member` resources after the existing `cnpg_backups_wi_*` block**

```hcl
# CNPG preview Cluster pods (phase-2 WAL archiving + base backups).
# Cluster's pod SA is named after the Cluster (trakrf-db-preview).
resource "google_service_account_iam_member" "cnpg_backups_wi_cluster_preview" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-preview/trakrf-db-preview]"
}

# Preview pg_dump CronJob KSA (phase-1 logical backup).
resource "google_service_account_iam_member" "cnpg_backups_wi_pgdump_preview" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-preview/cnpg-backups]"
}
```

- [ ] **Step 2: Validate + plan**

Run:
```bash
tofu -chdir=terraform/gcp init -backend-config=backend.conf
tofu -chdir=terraform/gcp validate
tofu -chdir=terraform/gcp plan
```

Expected: `2 to add, 0 to change, 0 to destroy.` Only the two new IAM bindings.

- [ ] **Step 3: Commit**

```bash
git add terraform/gcp/cnpg_backups.tf
git commit -m "feat(gcp): WI bindings for preview CNPG cluster + pg_dump KSAs"
```

---

## Task 2 — Chart: flatten `values.yaml`

**Files:**
- Modify: `helm/trakrf-db/values.yaml`

- [ ] **Step 1: Replace the file content end-to-end** (the `envs:` list and per-role nesting are gone; bootstrap.initdb.database/owner are derived in templates from the flat values):

```yaml
# Common CNPG+Timescale defaults. Storage class + affinity per cluster overlay.
# Managed role passwordSecrets are created out-of-band by `just db-secrets` in
# the release namespace — do not template them here.

fullnameOverride: trakrf-db          # per-release override sets per-env name

cluster:
  instances: 1
  imageName: ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18

postgresql:
  sharedPreloadLibraries:
    - timescaledb
  parameters:
    timescaledb.license: timescale
    password_encryption: scram-sha-256

# The Postgres database + roles + secrets the chart manages, single-env.
# Per-release overlay sets these to env-specific names.
database:
  name: trakrf_preview               # Postgres DB name (underscore form)
  cnpgName: trakrf-preview           # CNPG Database CRD k8s name (hyphen, DNS-1123)

roles:
  app: trakrf-app-preview
  migrate: trakrf-migrate-preview

secrets:
  app: trakrf-app-preview-credentials
  migrate: trakrf-migrate-preview-credentials

storage:
  size: 10Gi
  class: ""                          # REQUIRED — set in values-<cluster>.yaml
  createRetainClass: false           # cluster-scoped SC; set true on exactly one release

affinity:
  nodeSelector: {}
  tolerations: []

# Phase 1 logical per-DB dumps to GCS. Off by default — only the GKE overlay
# turns it on. Bucket name + GSA email are injected by the root chart from
# tofu outputs (see argocd/root/templates/trakrf-db*.yaml).
backups:
  enabled: false
  bucket: ""
  gcpServiceAccountEmail: ""
  schedule: "0 9 * * *"              # daily @ 09:00 UTC
  # Retention is enforced by the GCS lifecycle rule on the bucket
  # (terraform/gcp/cnpg_backups.tf), scoped to matches_prefix=["preview/","prod/"].
  # retentionDays here is documentation only.
  retentionDays: 14
  pgDumpImage: ghcr.io/cloudnative-pg/postgresql:17.2
  uploadImage: curlimages/curl:8.10.1
  # K8s SA name in the release's namespace; must match the WI binding subject
  # in terraform/gcp/cnpg_backups.tf for that namespace.
  serviceAccountName: cnpg-backups
  # GCS path prefix; per-release overrides to "prod" for the shared release.
  # Kept as a short env name (not the cluster name) so the existing lifecycle
  # rule matches_prefix=["preview/","prod/"] keeps working unchanged.
  dumpPrefix: preview
  # Phase 2: CNPG-native continuous WAL archiving + scheduled base backups.
  # serverName must be unique per Cluster (it's the bucket subdirectory).
  cluster:
    enabled: false
    serverName: trakrf-db            # per-release overrides to trakrf-db-preview
    baseBackupSchedule: "30 9 * * *"
    retentionPolicy: "14d"

initGrantsJob:
  # CNPG ships psql in its postgresql image
  image: ghcr.io/cloudnative-pg/postgresql:17.2
  # The DB host the Job connects to — defaults to "<fullnameOverride>-rw"
  # in the same namespace as the release. Override if needed.
  host: ""

# External LoadBalancer Service for the preview CNPG primary so external
# psql clients can reach it (FDW pull-migration dev endpoint, db.preview.gke.trakrf.id).
# Disabled by default; the new trakrf-db-preview Application sets enabled=true
# and wires loadBalancerIP + sourceRanges from tofu outputs.
externalPreview:
  enabled: false
  loadBalancerIP: ""
  sourceRanges: []
```

- [ ] **Step 2: Render with default values to verify chart parses (will fail templates that still reference `.Values.envs`)**

Run:
```bash
helm template tdb helm/trakrf-db 2>&1 | head -40
```

Expected: parse errors mentioning `range .Values.envs` from `templates/cluster.yaml`, `databases.yaml`, etc. This confirms the templates still need to be flattened in subsequent tasks. Do NOT commit yet — the chart is intentionally broken until Task 3.

---

## Task 3 — Chart: flatten `templates/cluster.yaml`

**Files:**
- Modify: `helm/trakrf-db/templates/cluster.yaml`

- [ ] **Step 1: Replace the file content end-to-end**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ .Values.fullnameOverride | default "trakrf-db" }}
  namespace: {{ .Release.Namespace }}
spec:
  instances: {{ .Values.cluster.instances }}
  imageName: {{ .Values.cluster.imageName | quote }}

  postgresql:
    shared_preload_libraries:
      {{- range .Values.postgresql.sharedPreloadLibraries }}
      - {{ . }}
      {{- end }}
    parameters:
      {{- range $k, $v := .Values.postgresql.parameters }}
      {{ $k }}: {{ $v | quote }}
      {{- end }}

  bootstrap:
    initdb:
      database: {{ .Values.database.name | quote }}
      owner: {{ .Values.roles.migrate | quote }}
      postInitTemplateSQL:
        - CREATE EXTENSION IF NOT EXISTS timescaledb

  managed:
    roles:
      - name: {{ .Values.roles.app | quote }}
        ensure: present
        login: true
        superuser: false
        createdb: false
        createrole: false
        passwordSecret:
          name: {{ .Values.secrets.app | quote }}
      - name: {{ .Values.roles.migrate | quote }}
        ensure: present
        login: true
        superuser: false
        createdb: true
        createrole: false
        passwordSecret:
          name: {{ .Values.secrets.migrate | quote }}

  storage:
    size: {{ .Values.storage.size }}
    storageClass: {{ required "storage.class must be set in values-<cluster>.yaml" .Values.storage.class | quote }}

  {{- if .Values.backups.enabled }}
  serviceAccountTemplate:
    metadata:
      annotations:
        iam.gke.io/gcp-service-account: {{ required "backups.gcpServiceAccountEmail must be set when backups.enabled=true" .Values.backups.gcpServiceAccountEmail | quote }}
  {{- end }}

  {{- if .Values.backups.cluster.enabled }}
  backup:
    retentionPolicy: {{ .Values.backups.cluster.retentionPolicy | quote }}
    barmanObjectStore:
      destinationPath: {{ printf "gs://%s" (required "backups.bucket must be set when backups.cluster.enabled=true" .Values.backups.bucket) | quote }}
      serverName: {{ .Values.backups.cluster.serverName | quote }}
      googleCredentials:
        gkeEnvironment: true
      wal:
        compression: gzip
      data:
        compression: gzip
        immediateCheckpoint: true
        jobs: 2
  {{- end }}

  {{- if or .Values.affinity.nodeSelector .Values.affinity.tolerations }}
  affinity:
    {{- with .Values.affinity.nodeSelector }}
    nodeSelector:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.affinity.tolerations }}
    tolerations:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  {{- end }}
```

- [ ] **Step 2: Render with the default (preview) values + GKE overlay; confirm the Cluster manifest looks right**

Run:
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=test-bucket --set backups.gcpServiceAccountEmail=test@test.iam \
  -s templates/cluster.yaml
```

Expected: One Cluster manifest, `name: trakrf-db`, `bootstrap.initdb.database: trakrf_preview`, `bootstrap.initdb.owner: "trakrf-migrate-preview"`, `managed.roles` has exactly two entries (`trakrf-app-preview`, `trakrf-migrate-preview`), `spec.backup.barmanObjectStore` present with serverName `trakrf-db`, `serviceAccountTemplate` present.

> Note: `values-gke.yaml` needs `storage.class: premium-rwo-retain` updated in Task 7. For now `helm template` may fail the `required` check on `storage.class`. If it does, also pass `--set storage.class=premium-rwo` in the smoke command to unblock this task's render.

---

## Task 4 — Chart: flatten `templates/databases.yaml`

**Files:**
- Modify: `helm/trakrf-db/templates/databases.yaml`

- [ ] **Step 1: Replace the file content end-to-end**

```yaml
{{- /*
  Single Database CR per release. Each per-env release manages exactly one
  Database, owned by its migrate role. databaseReclaimPolicy=retain means
  deleting this CR leaves the underlying Postgres database intact — combined
  with the Application's automated.prune=false, this is the load-bearing
  guardrail against accidental data loss on prune.
*/ -}}
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: {{ .Values.database.cnpgName | quote }}
  namespace: {{ .Release.Namespace }}
spec:
  name: {{ .Values.database.name | quote }}
  owner: {{ .Values.roles.migrate | quote }}
  cluster:
    name: {{ .Values.fullnameOverride | default "trakrf-db" }}
  ensure: present
  databaseReclaimPolicy: retain
```

- [ ] **Step 2: Render and confirm**

Run:
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=t --set backups.gcpServiceAccountEmail=t --set storage.class=premium-rwo \
  -s templates/databases.yaml
```

Expected: One Database manifest, `metadata.name: trakrf-preview`, `spec.name: trakrf_preview`, `spec.owner: trakrf-migrate-preview`, `spec.cluster.name: trakrf-db`, `spec.databaseReclaimPolicy: retain`.

---

## Task 5 — Chart: flatten `templates/init-grants-job.yaml`

**Files:**
- Modify: `helm/trakrf-db/templates/init-grants-job.yaml`

- [ ] **Step 1: Replace the file content end-to-end**

```yaml
{{- /*
  Init grants Job — applies the trakrf schema + grants in the Postgres
  database. Runs as a Helm post-install,post-upgrade hook so it lands after
  the CNPG operator has reconciled the managed roles + Database CR. SQL is
  idempotent so a re-run on every chart upgrade is a no-op once grants are
  in place.
*/ -}}
{{- $host := .Values.initGrantsJob.host -}}
{{- if not $host -}}
{{- $host = printf "%s-rw" (.Values.fullnameOverride | default "trakrf-db") -}}
{{- end -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ printf "%s-init-grants" (.Values.fullnameOverride | default "trakrf-db") }}
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 6
  template:
    metadata:
      name: {{ printf "%s-init-grants" (.Values.fullnameOverride | default "trakrf-db") }}
    spec:
      restartPolicy: OnFailure
      {{- with .Values.affinity.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: psql
          image: {{ .Values.initGrantsJob.image | quote }}
          env:
            - name: PGHOST
              value: {{ $host | quote }}
            - name: PGPORT
              value: "5432"
            - name: PGSSLMODE
              value: require
            - name: PGDATABASE
              value: {{ .Values.database.name | quote }}
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.migrate | quote }}
                  key: username
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.migrate | quote }}
                  key: password
          command:
            - /bin/sh
            - -c
            - |
              set -e
              # Wait for managed-role password reconcile (CNPG runs async after
              # Cluster admission). Retry psql until auth succeeds.
              for i in $(seq 1 30); do
                if psql -v ON_ERROR_STOP=1 -c '\q' 2>/dev/null; then
                  break
                fi
                echo "waiting for role password reconcile (attempt $i)..."
                sleep 4
              done
              psql -v ON_ERROR_STOP=1 <<'SQL'
              CREATE SCHEMA IF NOT EXISTS trakrf AUTHORIZATION "{{ .Values.roles.migrate }}";
              REVOKE CONNECT ON DATABASE {{ .Values.database.name }} FROM PUBLIC;
              GRANT CONNECT ON DATABASE {{ .Values.database.name }} TO "{{ .Values.roles.app }}";
              GRANT USAGE ON SCHEMA trakrf TO "{{ .Values.roles.app }}";
              GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA trakrf
                TO "{{ .Values.roles.app }}";
              GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA trakrf
                TO "{{ .Values.roles.app }}";
              GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA trakrf
                TO "{{ .Values.roles.app }}";
              ALTER DEFAULT PRIVILEGES FOR ROLE "{{ .Values.roles.migrate }}" IN SCHEMA trakrf
                GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{{ .Values.roles.app }}";
              ALTER DEFAULT PRIVILEGES FOR ROLE "{{ .Values.roles.migrate }}" IN SCHEMA trakrf
                GRANT USAGE, SELECT ON SEQUENCES TO "{{ .Values.roles.app }}";
              ALTER DEFAULT PRIVILEGES FOR ROLE "{{ .Values.roles.migrate }}" IN SCHEMA trakrf
                GRANT EXECUTE ON FUNCTIONS TO "{{ .Values.roles.app }}";
              SQL
```

- [ ] **Step 2: Render and confirm**

Run:
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=t --set backups.gcpServiceAccountEmail=t --set storage.class=premium-rwo \
  -s templates/init-grants-job.yaml
```

Expected: One Job, `metadata.name: trakrf-db-init-grants`, env vars correctly pulled from `trakrf-migrate-preview-credentials`, PGHOST=`trakrf-db-rw`, PGDATABASE=`trakrf_preview`, SQL block references roles `trakrf-app-preview` and `trakrf-migrate-preview`.

---

## Task 6 — Chart: flatten `templates/backup-cronjob.yaml` and `scheduled-backup.yaml`

**Files:**
- Modify: `helm/trakrf-db/templates/backup-cronjob.yaml`
- Modify: `helm/trakrf-db/templates/scheduled-backup.yaml`

- [ ] **Step 1: Replace `backup-cronjob.yaml` end-to-end**

```yaml
{{- /*
  Logical backup CronJob — pg_dump → GCS via WI + curl + JSON API.
  Single-env shape: one CronJob per release, named after the cluster.
  Uploads to gs://<bucket>/<dumpPrefix>/YYYY/MM/DD/HHMM.pgdump so the existing
  GCS lifecycle rule (matches_prefix=["preview/","prod/"]) keeps applying.
*/ -}}
{{- if .Values.backups.enabled }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-dump
  namespace: {{ .Release.Namespace }}
spec:
  schedule: {{ .Values.backups.schedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          serviceAccountName: {{ .Values.backups.serviceAccountName | quote }}
          automountServiceAccountToken: true
          {{- with .Values.affinity.nodeSelector }}
          nodeSelector:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.affinity.tolerations }}
          tolerations:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumes:
            - name: dump
              emptyDir: {}
          initContainers:
            - name: pg-dump
              image: {{ .Values.backups.pgDumpImage | quote }}
              env:
                - name: PGHOST
                  value: {{ printf "%s-rw" (.Values.fullnameOverride | default "trakrf-db") | quote }}
                - name: PGPORT
                  value: "5432"
                - name: PGSSLMODE
                  value: require
                - name: PGDATABASE
                  value: {{ .Values.database.name | quote }}
                - name: PGUSER
                  valueFrom:
                    secretKeyRef:
                      name: {{ .Values.secrets.migrate | quote }}
                      key: username
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: {{ .Values.secrets.migrate | quote }}
                      key: password
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  pg_dump -Fc -Z 6 -f /dump/dump.pgdump
                  ls -la /dump/dump.pgdump
              volumeMounts:
                - name: dump
                  mountPath: /dump
          containers:
            - name: upload
              image: {{ .Values.backups.uploadImage | quote }}
              env:
                - name: DUMP_PREFIX
                  value: {{ .Values.backups.dumpPrefix | quote }}
                - name: BUCKET
                  value: {{ required "backups.bucket must be set when backups.enabled=true" .Values.backups.bucket | quote }}
              command:
                - /bin/sh
                - -c
                - |
                  set -eu
                  ts=$(date -u +%Y/%m/%d/%H%M)
                  object="${DUMP_PREFIX}/${ts}.pgdump"
                  echo "Uploading /dump/dump.pgdump to gs://${BUCKET}/${object}"
                  token=$(curl -sSf \
                    -H "Metadata-Flavor: Google" \
                    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
                    | sed -E 's/.*"access_token":"([^"]+)".*/\1/')
                  test -n "${token}" || { echo "failed to fetch WI access token"; exit 1; }
                  curl -sSf -X POST \
                    -H "Authorization: Bearer ${token}" \
                    -H "Content-Type: application/octet-stream" \
                    --data-binary "@/dump/dump.pgdump" \
                    "https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o?uploadType=media&name=${object}"
                  echo
                  echo "Upload complete."
              volumeMounts:
                - name: dump
                  mountPath: /dump
{{- end }}
```

- [ ] **Step 2: Replace `scheduled-backup.yaml` end-to-end**

```yaml
{{- if .Values.backups.cluster.enabled }}
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: {{ printf "%s-base" (.Values.fullnameOverride | default "trakrf-db") }}
  namespace: {{ .Release.Namespace }}
spec:
  schedule: {{ printf "0 %s" .Values.backups.cluster.baseBackupSchedule | quote }}
  backupOwnerReference: self
  cluster:
    name: {{ .Values.fullnameOverride | default "trakrf-db" }}
  immediate: true
  method: barmanObjectStore
{{- end }}
```

- [ ] **Step 3: Render both and confirm**

Run:
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=t --set backups.gcpServiceAccountEmail=t --set storage.class=premium-rwo \
  -s templates/backup-cronjob.yaml
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=t --set backups.gcpServiceAccountEmail=t --set storage.class=premium-rwo \
  -s templates/scheduled-backup.yaml
```

Expected (cronjob): One CronJob named `pg-dump`, PGHOST=`trakrf-db-rw`, env `DUMP_PREFIX=preview`. Expected (scheduledbackup): One ScheduledBackup `trakrf-db-base`, `cluster.name: trakrf-db`.

---

## Task 7 — Chart: external service, storageclass, values-gke.yaml

**Files:**
- Modify: `helm/trakrf-db/templates/external-service-preview.yaml`
- Create: `helm/trakrf-db/templates/storageclass-retain.yaml`
- Modify: `helm/trakrf-db/values-gke.yaml`

- [ ] **Step 1: Update the selector in `external-service-preview.yaml`**

Open `helm/trakrf-db/templates/external-service-preview.yaml`. Find:

```yaml
  selector:
    cnpg.io/cluster: {{ .Values.fullnameOverride | default "trakrf-db" }}
    cnpg.io/instanceRole: primary
```

This already references `fullnameOverride` — no change needed. Verify the file has no `.Values.envs` references (it shouldn't).

- [ ] **Step 2: Create `templates/storageclass-retain.yaml`**

```yaml
{{- /*
  premium-rwo-retain — clone of GKE's built-in premium-rwo (pd-ssd) with
  reclaimPolicy: Retain so PVs survive PVC deletion. The new dedicated
  CNPG Clusters use this SC; setting createRetainClass=true on exactly one
  release means the cluster-scoped SC is created exactly once.
*/ -}}
{{- if .Values.storage.createRetainClass }}
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: premium-rwo-retain
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-ssd
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
{{- end }}
```

- [ ] **Step 3: Update `values-gke.yaml` storage class**

Open `helm/trakrf-db/values-gke.yaml`. Replace `storage.class: premium-rwo` with:

```yaml
storage:
  class: premium-rwo-retain
```

(Keep the existing affinity tolerations and backups blocks.)

- [ ] **Step 4: Render and confirm**

Run:
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=t --set backups.gcpServiceAccountEmail=t \
  --set storage.createRetainClass=true \
  -s templates/storageclass-retain.yaml

helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=t --set backups.gcpServiceAccountEmail=t \
  --set externalPreview.enabled=true \
  --set externalPreview.loadBalancerIP=9.9.9.9 \
  --set-json 'externalPreview.sourceRanges=["10.0.0.1/32"]' \
  -s templates/external-service-preview.yaml
```

Expected: StorageClass `premium-rwo-retain` with `reclaimPolicy: Retain` + Service with selector `cnpg.io/cluster: trakrf-db`.

Confirm SC is NOT emitted by default (createRetainClass=false):
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=t --set backups.gcpServiceAccountEmail=t \
  -s templates/storageclass-retain.yaml | grep -c StorageClass
```

Expected: `0`.

---

## Task 8 — Chart: full-chart smoke render + commit

**Files:** (no edits; verification only)

- [ ] **Step 1: Render the whole chart with default (preview-shaped) values + GKE overlay**

Run:
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=test-bucket --set backups.gcpServiceAccountEmail=test@iam \
  --set externalPreview.enabled=true \
  --set externalPreview.loadBalancerIP=9.9.9.9 \
  --set-json 'externalPreview.sourceRanges=["10.0.0.1/32"]' \
  --set storage.createRetainClass=true \
  --set fullnameOverride=trakrf-db-preview \
  --set backups.cluster.serverName=trakrf-db-preview \
  | head -200
```

Expected: No template errors. Resources in order: Cluster, Database, ServiceAccount (cnpg-backups), StorageClass (premium-rwo-retain), Service (trakrf-db-preview-preview-external), CronJob (pg-dump), ScheduledBackup, Job (trakrf-db-preview-init-grants).

- [ ] **Step 2: Render with the env=prod overlay to confirm the same chart serves the shared release shape**

Run:
```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set backups.bucket=test-bucket --set backups.gcpServiceAccountEmail=test@iam \
  --set fullnameOverride=trakrf-db \
  --set database.name=trakrf_prod \
  --set database.cnpgName=trakrf-prod \
  --set roles.app=trakrf-app-prod \
  --set roles.migrate=trakrf-migrate-prod \
  --set secrets.app=trakrf-app-prod-credentials \
  --set secrets.migrate=trakrf-migrate-prod-credentials \
  --set backups.dumpPrefix=prod \
  --set backups.cluster.serverName=trakrf-db \
  | grep -E '^(  name:|  namespace:|kind:)' | head -30
```

Expected: Cluster name `trakrf-db`, Database `trakrf-prod` (k8s) / `trakrf_prod` (postgres), no Service emitted (externalPreview off by default), CronJob `pg-dump`, no StorageClass.

- [ ] **Step 3: Commit chart**

```bash
git add helm/trakrf-db/values.yaml helm/trakrf-db/values-gke.yaml \
  helm/trakrf-db/templates/cluster.yaml \
  helm/trakrf-db/templates/databases.yaml \
  helm/trakrf-db/templates/init-grants-job.yaml \
  helm/trakrf-db/templates/backup-cronjob.yaml \
  helm/trakrf-db/templates/scheduled-backup.yaml \
  helm/trakrf-db/templates/external-service-preview.yaml \
  helm/trakrf-db/templates/storageclass-retain.yaml
git commit -m "refactor(trakrf-db): flatten chart to single-env, add retain storageclass"
```

---

## Task 9 — Root: add `automatedPrune` param to the helper

**Files:**
- Modify: `argocd/root/templates/_helpers.tpl`

- [ ] **Step 1: Patch the `trakrf.application` helper to read an optional `.automatedPrune`**

Find the `syncPolicy` block at the end of the helper:

```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Replace with:

```yaml
  syncPolicy:
    automated:
      prune: {{ if hasKey . "automatedPrune" }}{{ .automatedPrune }}{{ else }}true{{ end }}
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Also update the docstring at the top of the helper to mention the new optional key. Find:

```
  - `extraAnnotations` (optional) is a pre-rendered YAML string of
    additional metadata.annotations — e.g. ArgoCD Image Updater
    annotations on the preview Application. Empty string skips.
```

Append:

```
  - `automatedPrune` (optional) overrides syncPolicy.automated.prune.
    Defaults to true. Set false for stateful resources (CNPG Clusters)
    so an accidental prune cannot delete the database.
```

- [ ] **Step 2: Render one existing Application to confirm default behavior is unchanged**

Run:
```bash
helm template trakrf-root argocd/root --set cluster=gke \
  --set gcpProjectId=t --set certManagerGcpServiceAccountEmail=t \
  --set cloudDnsZoneNameApp=t --set cloudDnsZoneNameId=t \
  --set mqttPreviewIp=1.1.1.1 --set mqttProdIp=2.2.2.2 \
  --set dbPreviewIp=3.3.3.3 --set traefikLbIp=4.4.4.4 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  --set cnpgBackupBucket=t --set cnpgBackupsGcpServiceAccountEmail=t \
  -s templates/traefik.yaml | grep -A 3 'syncPolicy'
```

Expected: `automated: prune: true selfHeal: true`. Confirms existing Applications keep `prune: true`.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/_helpers.tpl
git commit -m "feat(argocd/root): optional automatedPrune param on trakrf.application helper"
```

---

## Task 10 — Root: AppProject permits StorageClass

**Files:**
- Modify: `argocd/projects/trakrf.yaml`

- [ ] **Step 1: Add `storage.k8s.io/StorageClass` to `clusterResourceWhitelist`**

Find:

```yaml
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
```

Insert after, in alphabetical order under the section (place between `Namespace` and `CustomResourceDefinition`):

```yaml
    - group: "storage.k8s.io"
      kind: StorageClass
```

- [ ] **Step 2: Apply (this file is kubectl-applied, not synced — per `feedback_argocd_appproject_permits_for_new_apps`)**

Defer the actual `kubectl apply -f argocd/projects/trakrf.yaml` to the post-merge operational step (see Task 17). For now just commit the YAML change.

- [ ] **Step 3: Commit**

```bash
git add argocd/projects/trakrf.yaml
git commit -m "chore(argocd): permit StorageClass on trakrf AppProject"
```

---

## Task 11 — Root: repurpose `trakrf-db.yaml` for env=prod

**Files:**
- Modify: `argocd/root/templates/trakrf-db.yaml`

- [ ] **Step 1: Replace the file content end-to-end**

```yaml
{{- /*
  Shared trakrf-db Cluster — now prod-only. The chart is single-env shape
  (refactored in TRA-849); this Application supplies the env=prod overlay
  via inlineValues. TRA-850 retires this Cluster + Application entirely.

  automatedPrune=false: stateful guardrail. Combined with the underlying
  PV's reclaimPolicy=Retain (one-time kubectl patch on the existing PV),
  neither an accidental prune nor a Cluster CR delete will destroy data.

  externalPreview.enabled stays off here — the FDW dev endpoint moves to
  the new trakrf-db-preview Application.
*/ -}}
{{- $ignore := "- group: postgresql.cnpg.io\n  kind: Cluster\n  name: trakrf-db\n  managedFieldsManagers:\n    - manager\n" -}}
{{- $values := printf "fullnameOverride: trakrf-db\ndatabase:\n  name: trakrf_prod\n  cnpgName: trakrf-prod\nroles:\n  app: trakrf-app-prod\n  migrate: trakrf-migrate-prod\nsecrets:\n  app: trakrf-app-prod-credentials\n  migrate: trakrf-migrate-prod-credentials\nbackups:\n  bucket: %q\n  gcpServiceAccountEmail: %q\n  dumpPrefix: prod\n  cluster:\n    serverName: trakrf-db\n" .Values.cnpgBackupBucket .Values.cnpgBackupsGcpServiceAccountEmail -}}
{{- include "trakrf.application" (dict
  "name" "trakrf-db"
  "path" "helm/trakrf-db"
  "namespace" .Values.namespaces.trakrfSystem
  "syncWave" "0"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" $values
  "ignoreDifferences" $ignore
  "automatedPrune" false
) }}
```

- [ ] **Step 2: Render and confirm**

Run:
```bash
helm template trakrf-root argocd/root --set cluster=gke \
  --set gcpProjectId=t --set certManagerGcpServiceAccountEmail=t \
  --set cloudDnsZoneNameApp=t --set cloudDnsZoneNameId=t \
  --set mqttPreviewIp=1.1.1.1 --set mqttProdIp=2.2.2.2 \
  --set dbPreviewIp=3.3.3.3 --set traefikLbIp=4.4.4.4 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  --set cnpgBackupBucket=test-bucket --set cnpgBackupsGcpServiceAccountEmail=test@iam \
  -s templates/trakrf-db.yaml
```

Expected: Application `trakrf-db` in ns `argocd` targeting namespace `trakrf-system`. inlineValues contains `database.name: trakrf_prod`, `roles.migrate: trakrf-migrate-prod`, `backups.dumpPrefix: prod`. `syncPolicy.automated.prune: false`.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/trakrf-db.yaml
git commit -m "refactor(argocd/root): trakrf-db Application is now prod-only via env=prod overlay"
```

---

## Task 12 — Root: new `trakrf-db-preview.yaml`

**Files:**
- Create: `argocd/root/templates/trakrf-db-preview.yaml`

- [ ] **Step 1: Create the file**

```yaml
{{- /*
  Dedicated CNPG Cluster for the preview environment. Co-located with
  trakrf-backend-preview + trakrf-ingester-preview in the trakrf-preview
  namespace — no cross-namespace secret mirror.

  GKE-only by structure: externalPreview.enabled and the inlineValues only
  populate on cluster=gke. Other cluster overlays render an Application
  with the chart defaults (externalPreview off, backups off).

  automatedPrune=false + premium-rwo-retain StorageClass = stateful guardrail.
  storage.createRetainClass=true here means this Application creates the
  cluster-scoped SC exactly once.
*/ -}}
{{- $ignore := "- group: postgresql.cnpg.io\n  kind: Cluster\n  name: trakrf-db-preview\n  managedFieldsManagers:\n    - manager\n" -}}
{{- $base := printf "fullnameOverride: trakrf-db-preview\ndatabase:\n  name: trakrf_preview\n  cnpgName: trakrf-preview\nroles:\n  app: trakrf-app-preview\n  migrate: trakrf-migrate-preview\nsecrets:\n  app: trakrf-app-preview-credentials\n  migrate: trakrf-migrate-preview-credentials\nstorage:\n  createRetainClass: true\nbackups:\n  bucket: %q\n  gcpServiceAccountEmail: %q\n  dumpPrefix: preview\n  cluster:\n    serverName: trakrf-db-preview\n" .Values.cnpgBackupBucket .Values.cnpgBackupsGcpServiceAccountEmail -}}
{{- $values := $base -}}
{{- if eq .Values.cluster "gke" -}}
{{- $values = printf "%sexternalPreview:\n  enabled: true\n  loadBalancerIP: %q\n  sourceRanges:\n    - %q\n" $base .Values.dbPreviewIp .Values.breakglassSourceCidr -}}
{{- end -}}
{{- include "trakrf.application" (dict
  "name" "trakrf-db-preview"
  "path" "helm/trakrf-db"
  "namespace" .Values.namespaces.trakrfPreview
  "syncWave" "0"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" $values
  "ignoreDifferences" $ignore
  "automatedPrune" false
) }}
```

- [ ] **Step 2: Render and confirm**

Run:
```bash
helm template trakrf-root argocd/root --set cluster=gke \
  --set gcpProjectId=t --set certManagerGcpServiceAccountEmail=t \
  --set cloudDnsZoneNameApp=t --set cloudDnsZoneNameId=t \
  --set mqttPreviewIp=1.1.1.1 --set mqttProdIp=2.2.2.2 \
  --set dbPreviewIp=3.3.3.3 --set traefikLbIp=4.4.4.4 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  --set cnpgBackupBucket=test-bucket --set cnpgBackupsGcpServiceAccountEmail=test@iam \
  -s templates/trakrf-db-preview.yaml
```

Expected: Application `trakrf-db-preview` targeting namespace `trakrf-preview`, inlineValues contains `fullnameOverride: trakrf-db-preview`, `database.name: trakrf_preview`, `backups.cluster.serverName: trakrf-db-preview`, `externalPreview.enabled: true`, `loadBalancerIP: "3.3.3.3"`, `syncPolicy.automated.prune: false`.

Also confirm non-GKE renders without `externalPreview`:
```bash
helm template trakrf-root argocd/root --set cluster=aks \
  --set certManagerIdentityClientId=t --set tenantId=t \
  --set subscriptionId=t --set dnsZoneResourceGroup=t \
  --set traefikLbIp=4.4.4.4 --set mainResourceGroupName=t \
  -s templates/trakrf-db-preview.yaml | grep -c externalPreview
```

Expected: `0`.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/trakrf-db-preview.yaml
git commit -m "feat(argocd/root): trakrf-db-preview Application for dedicated CNPG cluster"
```

---

## Task 13 — Root: preview DSN flip for backend + ingester

**Files:**
- Modify: `argocd/root/templates/trakrf-backend.yaml`
- Modify: `argocd/root/templates/trakrf-ingester.yaml`

- [ ] **Step 1: Update `trakrf-backend.yaml` — preview env host changes**

Find the `$base` printf block:

```
{{- $base := printf "database:\n  name: trakrf_%s\n  user: trakrf-app-%s\n  credentialsSecret: trakrf-app-%s-credentials\n  host: trakrf-db-rw.trakrf-system\nmigrate:\n  database: trakrf_%s\n  user: trakrf-migrate-%s\n  credentialsSecret: trakrf-migrate-%s-credentials\n  host: trakrf-db-rw.trakrf-system\nconfig:\n  appEnv: %s\n" $env $env $env $env $env $env $env }}
```

Replace with a conditional host so preview points at `trakrf-db-preview-rw.trakrf-preview` and prod stays at `trakrf-db-rw.trakrf-system`:

```
{{- $dbHost := "trakrf-db-rw.trakrf-system" }}
{{- if eq $env "preview" }}
{{- $dbHost = "trakrf-db-preview-rw.trakrf-preview" }}
{{- end }}
{{- $base := printf "database:\n  name: trakrf_%s\n  user: trakrf-app-%s\n  credentialsSecret: trakrf-app-%s-credentials\n  host: %s\nmigrate:\n  database: trakrf_%s\n  user: trakrf-migrate-%s\n  credentialsSecret: trakrf-migrate-%s-credentials\n  host: %s\nconfig:\n  appEnv: %s\n" $env $env $env $dbHost $env $env $env $dbHost $env }}
```

- [ ] **Step 2: Same edit in `trakrf-ingester.yaml`** (the file has the same `$base` printf shape — find and apply the equivalent change)

- [ ] **Step 3: Render and confirm both**

Run:
```bash
helm template trakrf-root argocd/root --set cluster=gke \
  --set gcpProjectId=t --set certManagerGcpServiceAccountEmail=t \
  --set cloudDnsZoneNameApp=t --set cloudDnsZoneNameId=t \
  --set mqttPreviewIp=1.1.1.1 --set mqttProdIp=2.2.2.2 \
  --set dbPreviewIp=3.3.3.3 --set traefikLbIp=4.4.4.4 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  --set cnpgBackupBucket=t --set cnpgBackupsGcpServiceAccountEmail=t \
  -s templates/trakrf-backend.yaml | grep -E 'host:|name: trakrf-backend-'
```

Expected: `trakrf-backend-preview` Application's inlineValues has `host: trakrf-db-preview-rw.trakrf-preview` (twice — database + migrate). `trakrf-backend-prod` keeps `host: trakrf-db-rw.trakrf-system`.

Same shape for ingester:
```bash
helm template trakrf-root argocd/root --set cluster=gke \
  --set gcpProjectId=t --set certManagerGcpServiceAccountEmail=t \
  --set cloudDnsZoneNameApp=t --set cloudDnsZoneNameId=t \
  --set mqttPreviewIp=1.1.1.1 --set mqttProdIp=2.2.2.2 \
  --set dbPreviewIp=3.3.3.3 --set traefikLbIp=4.4.4.4 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  --set cnpgBackupBucket=t --set cnpgBackupsGcpServiceAccountEmail=t \
  -s templates/trakrf-ingester.yaml | grep -E 'host:|name: trakrf-ingester-'
```

- [ ] **Step 4: Commit**

```bash
git add argocd/root/templates/trakrf-backend.yaml argocd/root/templates/trakrf-ingester.yaml
git commit -m "feat(argocd/root): point preview DSN at trakrf-db-preview-rw.trakrf-preview"
```

---

## Task 14 — Justfile: `db-secrets` reshape

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Replace the `db-secrets` recipe and the `_db-secret` helper**

Find:

```just
db-secrets:
    @kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${TRAKRF_APP_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_APP_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @just _db-secret app     preview "${TRAKRF_APP_DB_PASSWORD_PREVIEW}"
    @just _db-secret app     prod    "${TRAKRF_APP_DB_PASSWORD_PROD}"
    @just _db-secret migrate preview "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW}"
    @just _db-secret migrate prod    "${TRAKRF_MIGRATE_DB_PASSWORD_PROD}"
    @echo "Secrets applied + reflector annotations set. Reflector will mirror into trakrf-{preview,prod}."

# Helper: create one reflector-annotated CNPG role Secret in trakrf-system.
# Private (leading underscore) — called by db-secrets.
_db-secret ROLE ENV PW:
    @kubectl create secret generic trakrf-{{ROLE}}-{{ENV}}-credentials -n trakrf-system \
      --from-literal=username=trakrf-{{ROLE}}-{{ENV}} \
      --from-literal=password="{{PW}}" \
      --dry-run=client -o yaml | kubectl apply -f -
    @kubectl annotate --overwrite secret trakrf-{{ROLE}}-{{ENV}}-credentials -n trakrf-system \
      reflector.v1.k8s.emberstack.com/reflection-allowed=true \
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-{{ENV}}
```

Replace with:

```just
# Per-env CNPG role credential Secrets.
#
# Preview (post-TRA-849, dedicated Cluster): Secrets live natively in
# trakrf-preview alongside the Cluster + apps. No reflector annotations.
#
# Prod (still on the shared Cluster in trakrf-system until TRA-850): Secrets
# live in trakrf-system and reflector mirrors them into trakrf-prod where
# the backend + ingester run. Reflector goes away for prod when TRA-850
# co-locates prod onto a dedicated Cluster.
#
# Passwords come from .env.local using openssl rand -hex (per
# feedback_db_password_alphabet — base64 / + chars break URL DSNs).
db-secrets:
    @kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${TRAKRF_APP_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_APP_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @just _db-secret app     preview trakrf-preview ""              "${TRAKRF_APP_DB_PASSWORD_PREVIEW}"
    @just _db-secret app     prod    trakrf-system  "trakrf-prod"   "${TRAKRF_APP_DB_PASSWORD_PROD}"
    @just _db-secret migrate preview trakrf-preview ""              "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW}"
    @just _db-secret migrate prod    trakrf-system  "trakrf-prod"   "${TRAKRF_MIGRATE_DB_PASSWORD_PROD}"
    @echo "Secrets applied. Preview: native in trakrf-preview. Prod: reflector-mirrored into trakrf-prod."

# Helper: create one CNPG role credential Secret.
#   ROLE   : "app" | "migrate"
#   ENV    : "preview" | "prod"  (used in the Secret name suffix)
#   NS     : namespace to create the Secret in
#   REFLECT: target namespace for reflector mirroring; empty disables annotations
#   PW     : password
_db-secret ROLE ENV NS REFLECT PW:
    @kubectl create secret generic trakrf-{{ROLE}}-{{ENV}}-credentials -n {{NS}} \
      --from-literal=username=trakrf-{{ROLE}}-{{ENV}} \
      --from-literal=password="{{PW}}" \
      --dry-run=client -o yaml | kubectl apply -f -
    @if [ -n "{{REFLECT}}" ]; then \
       kubectl annotate --overwrite secret trakrf-{{ROLE}}-{{ENV}}-credentials -n {{NS}} \
         reflector.v1.k8s.emberstack.com/reflection-allowed=true \
         reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
         reflector.v1.k8s.emberstack.com/reflection-auto-namespaces={{REFLECT}}; \
     else \
       kubectl annotate --overwrite secret trakrf-{{ROLE}}-{{ENV}}-credentials -n {{NS}} \
         reflector.v1.k8s.emberstack.com/reflection-allowed- \
         reflector.v1.k8s.emberstack.com/reflection-auto-enabled- \
         reflector.v1.k8s.emberstack.com/reflection-auto-namespaces- 2>/dev/null || true; \
     fi
```

- [ ] **Step 2: Lint the justfile**

Run:
```bash
just --list 2>&1 | head -20
```

Expected: `db-secrets` listed without errors.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "refactor(just): db-secrets recipe — preview native in trakrf-preview, prod still reflector-mirrored"
```

---

## Task 15 — Docs: migration runbook

**Files:**
- Create: `docs/db-migration.md`

- [ ] **Step 1: Create the runbook**

```markdown
# Logical migration runbook — TimescaleDB Cloud → CNPG

> Used by TRA-849 (preview) and re-used verbatim by TRA-850 (prod). Substitute
> `<env>` placeholders throughout: `preview` for TRA-849, `prod` for TRA-850.

## Preconditions

- kubectl context points at the target GKE cluster.
- `gcloud auth login --update-adc` recently (so `gcloud storage` works for
  the row-count snapshot and the GCS-side checks).
- TSC psql endpoint reachable from the kubectl host (port 5432 TLS); creds
  for the TSC migration source role in `.env.local` (or equivalent).
- New CNPG Cluster `trakrf-db-<env>` Ready in namespace `trakrf-<env>`.
- Platform FDW pull script available (trakrf/platform PR #413, branch /
  `cutover/<env>-fdw-pull.sql`).
- Application Apps (`trakrf-backend-<env>`, `trakrf-ingester-<env>`) are
  scaled down or already CrashLoopBackOff (post-DSN-flip, pre-data).

## Steps

### 1. Snapshot source row counts

From a host that can reach TSC:

```bash
psql "${TSC_<ENV>_DSN}" -c "
  SELECT relname, n_live_tup
  FROM pg_stat_user_tables
  WHERE schemaname='trakrf'
  ORDER BY relname;
" > /tmp/migration-source-counts.txt
```

Keep `/tmp/migration-source-counts.txt` for the post-pull diff.

### 2. Schema bootstrap via the trakrf-backend migrate Job

The existing migrate Job pattern (TRA-361) runs as the migrate role and
applies the golang-migrate set to the new DB. It's already part of the
trakrf-backend chart; trigger it manually:

```bash
kubectl -n trakrf-<env> create job migrate-bootstrap \
  --from=cronjob/trakrf-backend-migrate \
  || kubectl -n trakrf-<env> rollout restart deploy/trakrf-backend  # if migrate is a deploy-init pattern
```

Confirm completion:

```bash
kubectl -n trakrf-<env> get jobs
kubectl -n trakrf-<env> logs job/migrate-bootstrap
```

Expected: Job Complete, all migrations applied, `\dn` shows `trakrf` schema
present in the new DB.

### 3. Enable FDW

The FDW pull needs superuser. Pull the CNPG-managed superuser secret for
the target Cluster:

```bash
SUPER_PW=$(kubectl -n trakrf-<env> get secret trakrf-db-<env>-superuser \
  -o jsonpath='{.data.password}' | base64 -d)
```

Run the FDW setup SQL against the new Cluster's external LB endpoint
(`db.preview.gke.trakrf.id` for preview; equivalent for prod when added):

```bash
PGPASSWORD="$SUPER_PW" psql \
  "host=db.<env>.gke.trakrf.id user=postgres dbname=trakrf_<env> \
   sslmode=verify-ca sslrootcert=/tmp/trakrf-db-<env>-ca.crt" \
  -f <(curl -fsSL https://raw.githubusercontent.com/trakrf/platform/<sha>/cutover/<env>-fdw-pull.sql)
```

(See trakrf/platform PR #413 for the latest SQL.)

The script performs:
- `CREATE EXTENSION postgres_fdw`
- `CREATE SERVER tsc_source`
- `CREATE USER MAPPING FOR postgres SERVER tsc_source ...`
- `IMPORT FOREIGN SCHEMA trakrf FROM SERVER tsc_source INTO trakrf_remote`
- Per-table `INSERT INTO trakrf.<table> SELECT * FROM trakrf_remote.<table>`
  in FK-respecting order
- For Timescale hypertables, bracket with
  `SELECT timescaledb_pre_restore(); ... SELECT timescaledb_post_restore();`
  (per `feedback_timescale_logical_restore_bracket`)

### 4. Sanity check

```bash
kubectl -n trakrf-<env> exec deploy/trakrf-db-<env>-1 -- \
  psql -U postgres -d trakrf_<env> -c "
    SELECT relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname='trakrf'
    ORDER BY relname;
  " > /tmp/migration-target-counts.txt
diff /tmp/migration-source-counts.txt /tmp/migration-target-counts.txt
```

Expected: empty diff (or only differences in tables intentionally not
migrated).

### 5. Tear down FDW

```bash
PGPASSWORD="$SUPER_PW" psql \
  "host=db.<env>.gke.trakrf.id user=postgres dbname=trakrf_<env> \
   sslmode=verify-ca sslrootcert=/tmp/trakrf-db-<env>-ca.crt" -c "
  DROP USER MAPPING IF EXISTS FOR postgres SERVER tsc_source;
  DROP SERVER IF EXISTS tsc_source;
  DROP SCHEMA IF EXISTS trakrf_remote CASCADE;
  DROP EXTENSION IF EXISTS postgres_fdw;
"
```

### 6. Bring apps back online

Argo will auto-reconcile, but a manual restart accelerates the recovery
from CrashLoopBackOff:

```bash
kubectl -n trakrf-<env> rollout restart deploy/trakrf-backend
kubectl -n trakrf-<env> rollout restart deploy/trakrf-ingester
kubectl -n trakrf-<env> get pods -w
```

Expected: backend Ready, `/healthz` returns 200 via port-forward.

### 7. Negative-auth test

Confirm the env's app role cannot reach the other env's DB:

```bash
PW=$(kubectl -n trakrf-<env> get secret trakrf-app-<env>-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
# For preview: target = trakrf_prod on shared Cluster.
# For prod: target = trakrf_preview on the new preview Cluster (or its
# remnant if reachable).
kubectl run --rm -it psql-neg -n trakrf-<env> --restart=Never --image=postgres:17 \
  --env=PGPASSWORD="$PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app-<env> -d trakrf_<other-env> -c "SELECT 1;"
```

Expected: connection / authentication failure.

### 8. Drop source-env objects from the previous Cluster (TRA-849-only)

On the shared Cluster `trakrf-db` in `trakrf-system`:

```bash
kubectl -n trakrf-system exec trakrf-db-1 -- \
  psql -U postgres -c '
    DROP DATABASE trakrf_<env>;
    DROP ROLE "trakrf-app-<env>";
    DROP ROLE "trakrf-migrate-<env>";
  '
kubectl -n trakrf-system delete secret \
  trakrf-app-<env>-credentials \
  trakrf-migrate-<env>-credentials \
  --ignore-not-found
```

(For TRA-850 prod, the equivalent step is "destroy the shared Cluster
entirely" once prod has cut over to its dedicated Cluster — see TRA-850.)

## Rollback

If sanity check (step 4) fails:

1. Drop the partial data: `psql ... -c "TRUNCATE trakrf.<table> CASCADE;"`
   for the tables that imported.
2. Investigate the failed table — usually a FK ordering issue or a
   trigger needing EXECUTE grants that the init-grants Job did not apply.
3. Re-run the pull SQL (idempotent on TRUNCATE + INSERT pattern).

The apps stay pointed at the new Cluster (the chart change has merged).
If recovery exceeds the disruption budget, point apps back at the old
shared Cluster by reverting the DSN flip commit on the branch (a
one-line edit in `argocd/root/templates/trakrf-backend.yaml` +
`trakrf-ingester.yaml`).
```

- [ ] **Step 2: Commit**

```bash
git add docs/db-migration.md
git commit -m "docs(migration): TSC→CNPG logical migration runbook for TRA-849 + TRA-850"
```

---

## Task 16 — Plan + render full root for both clusters, confirm

**Files:** (no edits; verification only)

- [ ] **Step 1: Render the full root chart for GKE**

Run:
```bash
helm template trakrf-root argocd/root --set cluster=gke \
  --set gcpProjectId=t --set certManagerGcpServiceAccountEmail=t \
  --set cloudDnsZoneNameApp=t --set cloudDnsZoneNameId=t \
  --set mqttPreviewIp=1.1.1.1 --set mqttProdIp=2.2.2.2 \
  --set dbPreviewIp=3.3.3.3 --set traefikLbIp=4.4.4.4 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  --set cnpgBackupBucket=test-bucket --set cnpgBackupsGcpServiceAccountEmail=test@iam \
  | grep -E '^  name:|kind: Application' | head -40
```

Expected (subset): Application names `trakrf-db`, `trakrf-db-preview`, `trakrf-backend-preview`, `trakrf-backend-prod`, `trakrf-ingester-preview`, `trakrf-ingester-prod`, plus the other Applications (argocd, traefik, etc.).

- [ ] **Step 2: Render full root chart for AKS and EKS — confirm trakrf-db-preview still renders without externalPreview**

Run:
```bash
helm template trakrf-root argocd/root --set cluster=aks \
  --set certManagerIdentityClientId=t --set tenantId=t \
  --set subscriptionId=t --set dnsZoneResourceGroup=t \
  --set traefikLbIp=4.4.4.4 --set mainResourceGroupName=t \
  | grep -E 'trakrf-db-preview|externalPreview'
```

Expected: Application `trakrf-db-preview` Application present; zero `externalPreview` occurrences.

- [ ] **Step 3: `tofu plan` is still clean**

Run:
```bash
tofu -chdir=terraform/gcp plan
```

Expected: still the same `2 to add, 0 to change, 0 to destroy` from Task 1.

- [ ] **Step 4: No commit — verification only**

---

## Task 17 — Open PR

**Files:** (no edits; PR-only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin miks2u/tra-849-cluster-per-env-cnpg
```

- [ ] **Step 2: Open PR**

Use this title (no Linear ticket reference per `feedback_no_ticket_refs_in_public_docs`):

> `cluster-per-env CNPG: preview onto dedicated cluster + chart flatten`

Body:

```markdown
## Summary
- `helm/trakrf-db` chart refactored to single-env shape (flat values; no
  `envs:` loop). Same chart now serves both the shared `trakrf-db`
  Application (now prod-only) and a new `trakrf-db-preview` Application
  for the dedicated preview cluster.
- New `trakrf-db-preview` co-located in `trakrf-preview` ns alongside
  backend + ingester. No cross-namespace secret mirror for preview.
- Stateful guardrails: `automated.prune: false` on both CNPG Cluster
  Applications, `premium-rwo-retain` StorageClass for new dedicated
  cluster, plus a one-time PV patch on the shared Cluster (operational).
- Preview rebuild itself happens by runbook around merge — see
  `docs/db-migration.md`.

## Test plan
- [ ] `tofu plan` clean (only the 2 new WI bindings)
- [ ] `helm template` clean for GKE, AKS, EKS root renders
- [ ] Post-merge `scripts/apply-root-app.sh gke` succeeds
- [ ] AppProject patched (`kubectl apply -f argocd/projects/trakrf.yaml`)
- [ ] `tofu apply` (the WI bindings)
- [ ] `just db-secrets` pre-cutover
- [ ] ArgoCD reconciles new + shared Applications, both Healthy
- [ ] `docs/db-migration.md` runbook executed: schema + FDW pull + sanity
- [ ] Negative-auth test passes
- [ ] Old shared cluster cleanup SQL executed
```

- [ ] **Step 3: Verify CI**

Wait for CI checks; address any failures.

---

## Task 18 — Operational cutover (post-merge; not a code change)

The flatten pass means the chart's defaults now match the desired end state
without any env suffix in DB/role/Secret names. The shared Cluster needs a
one-time PG rename so it conforms to the same flat names; the new preview
Cluster comes up clean from scratch.

- [ ] **Step 1: PV reclaimPolicy patch on the shared Cluster PV** (pre-merge,
      protects the existing PV against any accidental delete during transition)

```bash
PV=$(kubectl get pvc -n trakrf-system -l cnpg.io/cluster=trakrf-db \
       -o jsonpath='{.items[0].spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# expect: Retain
```

- [ ] **Step 2: Drop legacy preview state from the shared Cluster** (pre-merge)

```bash
kubectl -n trakrf-system exec trakrf-db-1 -- psql -U postgres <<SQL
DROP DATABASE IF EXISTS trakrf_preview;
DROP ROLE IF EXISTS "trakrf-app-preview";
DROP ROLE IF EXISTS "trakrf-migrate-preview";
SQL
kubectl -n trakrf-system delete secret \
  trakrf-app-preview-credentials trakrf-migrate-preview-credentials \
  --ignore-not-found
```

- [ ] **Step 3: Rename prod objects on the shared Cluster to flat names** (pre-merge)

`trakrf_prod` is empty until the Saturday 2026-05-30 prod cutover, so the
rename is structurally safe.

```bash
kubectl -n trakrf-system exec trakrf-db-1 -- psql -U postgres <<SQL
ALTER DATABASE trakrf_prod RENAME TO trakrf;
ALTER ROLE "trakrf-app-prod" RENAME TO "trakrf-app";
ALTER ROLE "trakrf-migrate-prod" RENAME TO "trakrf-migrate";
SQL
```

- [ ] **Step 4: Delete legacy *-prod-credentials Secrets in trakrf-system** (pre-merge)

`just db-secrets` recreates them under the new flat names in Step 5.

```bash
kubectl -n trakrf-system delete secret \
  trakrf-app-prod-credentials trakrf-migrate-prod-credentials \
  --ignore-not-found
```

- [ ] **Step 5: `just db-secrets` (new shape)** (pre-merge)

Creates flat-named Secrets in both target namespaces. Confirm
`.env.local` has the four password variables set first.

```bash
just db-secrets
```

Expected:
- `trakrf-preview` ns: `trakrf-app-credentials` + `trakrf-migrate-credentials` (no reflector annotations)
- `trakrf-system` ns: `trakrf-app-credentials` + `trakrf-migrate-credentials` (reflector-annotated → trakrf-prod)

- [ ] **Step 6: Snapshot TSC preview row counts** (pre-merge)

```bash
psql "${TSC_PREVIEW_DSN}" -c "
  SELECT relname, n_live_tup
  FROM pg_stat_user_tables
  WHERE schemaname='trakrf'
  ORDER BY relname;
" > /tmp/migration-source-counts.txt
```

- [ ] **Step 7: Merge PR**

After merge, ArgoCD will detect the root-chart changes once
`scripts/apply-root-app.sh gke` reconciles values placeholders.

- [ ] **Step 8: Apply the updated AppProject (kubectl-applied, not synced)**

```bash
kubectl apply -f argocd/projects/trakrf.yaml
```

- [ ] **Step 9: Apply tofu**

```bash
just gcp
```

Expected: 2 to add (the two new WI bindings) + 1 to change (the broadened
lifecycle prefix). Apply.

- [ ] **Step 10: Push root-chart values + watch reconcile**

```bash
scripts/apply-root-app.sh gke
argocd app list | grep -E 'trakrf-db|trakrf-backend|trakrf-ingester'
argocd app get trakrf-db-preview
argocd app get trakrf-db
```

Wait until both Cluster Applications are Synced. `trakrf-db-preview` should
come up Healthy quickly. `trakrf-db` may briefly show Healthy=Degraded while
CNPG syncs role passwords to the new Secret names.

- [ ] **Step 11: Confirm guardrails on new Cluster**

```bash
kubectl -n trakrf-preview get cluster trakrf-db-preview
kubectl -n trakrf-preview get pv $(kubectl get pvc -n trakrf-preview \
  -l cnpg.io/cluster=trakrf-db-preview \
  -o jsonpath='{.items[0].spec.volumeName}') \
  -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# expect: Retain
argocd app get trakrf-db-preview -o jsonpath='{.spec.syncPolicy.automated.prune}'
# expect: false
```

- [ ] **Step 12: Run the migration runbook for `<env>=preview`**

Follow `docs/db-migration.md` end-to-end: schema bootstrap via the
trakrf-backend migrate Job, FDW pull from TSC preview, row-count diff,
FDW teardown, app rollout-restart.

- [ ] **Step 13: Verify**

```bash
# Confirm preview DB has data
kubectl -n trakrf-preview exec trakrf-db-preview-1 -- \
  psql -U postgres -d trakrf -c "SELECT count(*) FROM trakrf.tag_scan;"

# Negative-auth: preview app credential against shared Cluster
PW=$(kubectl -n trakrf-preview get secret trakrf-app-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl run --rm -it psql-neg -n trakrf-preview --restart=Never --image=postgres:17 \
  --env=PGPASSWORD="$PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app -d trakrf -c "SELECT 1;"
# expect: auth failure (different password)

# Confirm legacy preview state gone from shared Cluster
kubectl -n trakrf-system exec trakrf-db-1 -- \
  psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='trakrf_preview';"
# expect: 0 rows
kubectl -n trakrf-system exec trakrf-db-1 -- \
  psql -U postgres -c "\du trakrf-app-preview"
# expect: error (role does not exist)
```

- [ ] **Step 14: Capture acceptance-criteria evidence on the PR**

Trimmed output of:
- `argocd app get trakrf-db-preview` (Synced+Healthy, prune=false)
- `kubectl get pv ...` (Retain on both Cluster PVs)
- migration row-count diff (empty)
- negative-auth `psql` failure
- pg_database / pg_roles queries showing no preview leftovers on shared

---

## Self-review (skim against the spec)

- **Chart flatten**: Task 2 (values), Tasks 3–7 (templates). ✓
- **Storage class + retain**: Task 7. ✓
- **AppProject permits StorageClass**: Task 10. ✓
- **Helper `automatedPrune`**: Task 9. ✓
- **Repurpose trakrf-db Application for env=prod**: Task 11. ✓
- **New trakrf-db-preview Application**: Task 12. ✓
- **Backend + ingester DSN flip for preview**: Task 13. ✓
- **Tofu WI bindings**: Task 1. ✓
- **Justfile db-secrets reshape**: Task 14. ✓
- **Migration runbook**: Task 15. ✓
- **Pre-merge PV patch**: Task 18, Step 1. ✓
- **Post-merge AppProject apply + tofu + db-secrets + apply-root-app**: Task 18. ✓
- **Negative-auth test**: docs/db-migration.md Step 7. ✓
- **Drop preview from old shared Cluster**: docs/db-migration.md Step 8. ✓

All spec acceptance criteria mapped to a task or runbook step.
