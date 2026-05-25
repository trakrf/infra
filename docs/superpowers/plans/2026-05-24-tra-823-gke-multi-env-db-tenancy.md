# TRA-823 GKE Multi-Env DB Tenancy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up two app environments (`preview`, `prod`) on a single shared CNPG cluster in `trakrf-system`, with DB-per-env isolation, per-env managed roles, and reflector-mirrored credentials into per-env namespaces.

**Architecture:** CNPG Cluster lives in `trakrf-system`. Two `Database` CRDs (`trakrf-preview`, `trakrf-prod`) plus four managed roles (`trakrf-app-{preview,prod}`, `trakrf-migrate-{preview,prod}`). Per-env post-install Helm-hook Jobs apply schema/grants idempotently. emberstack/reflector mirrors annotated credential Secrets from `trakrf-system` into `trakrf-preview` / `trakrf-prod`. Backend and ingester Applications fan out into `-preview` / `-prod` releases via a `range` in the root chart.

**Tech Stack:** Kubernetes, ArgoCD app-of-apps, Helm, CloudNativePG, emberstack/reflector, just, bash.

**Spec reference:** `docs/superpowers/specs/2026-05-24-tra-823-gke-multi-env-db-tenancy-design.md`

**Cutover model:** Full clean cutover. The existing `trakrf` namespace and its CNPG PVC are destroyed. Data loss is acceptable per user direction. The final task tears the old namespace down and verifies the new layout.

**Verification model:** This is an infra repo with no Go/Python/JS test suite. The "tests" for each chart change are `helm template` renders that must succeed without error and produce expected manifests. Cluster verification (kubectl exec, psql, ArgoCD diff) lands in the final cutover task once everything is committed and ArgoCD has reconciled.

---

## Task 1: Update AppProject for new namespaces + sourceRepo

The `trakrf` AppProject restricts which namespaces apps can target and which Helm repos can be used. Add the three new namespaces and emberstack's Helm repo before any new Application can sync.

**Files:**
- Modify: `argocd/projects/trakrf.yaml`

- [ ] **Step 1: Edit `argocd/projects/trakrf.yaml`**

Replace `sourceRepos:` and `destinations:` with:

```yaml
  sourceRepos:
    - "https://github.com/trakrf/infra.git"
    - "https://argoproj.github.io/argo-helm"
    - "https://prometheus-community.github.io/helm-charts"
    - "https://cloudnative-pg.github.io/charts"
    - "https://traefik.github.io/charts"
    - "https://charts.jetstack.io"
    - "https://emberstack.github.io/helm-charts"
  destinations:
    - server: https://kubernetes.default.svc
      namespace: argocd
    - server: https://kubernetes.default.svc
      namespace: trakrf-system
    - server: https://kubernetes.default.svc
      namespace: trakrf-preview
    - server: https://kubernetes.default.svc
      namespace: trakrf-prod
    - server: https://kubernetes.default.svc
      namespace: reflector
    - server: https://kubernetes.default.svc
      namespace: monitoring
    - server: https://kubernetes.default.svc
      namespace: kube-system
    - server: https://kubernetes.default.svc
      namespace: cnpg-system
    - server: https://kubernetes.default.svc
      namespace: traefik
    - server: https://kubernetes.default.svc
      namespace: cert-manager
```

(The old `trakrf` and `trakrf-db` entries are dropped — those namespaces are being retired in this change.)

- [ ] **Step 2: Render and verify**

```bash
kubectl --dry-run=client apply -f argocd/projects/trakrf.yaml
```
Expected: exit 0, prints `appproject.argoproj.io/trakrf configured (dry run)` or `created (dry run)`.

- [ ] **Step 3: Commit**

```bash
git add argocd/projects/trakrf.yaml
git commit -m "chore: expand trakrf AppProject for multi-env namespaces + reflector"
```

---

## Task 2: Add reflector Application at sync wave -1

Upstream chart, inline `source:` block (matches cert-manager / traefik pattern in this repo).

**Files:**
- Create: `argocd/root/templates/reflector.yaml`

- [ ] **Step 1: Look up the latest reflector chart version**

```bash
helm repo add emberstack https://emberstack.github.io/helm-charts 2>/dev/null || true
helm repo update emberstack
helm search repo emberstack/reflector --versions | head -5
```

Pick the latest stable (numeric SemVer, no `-rc`/`-beta`). Note the version string — it goes into the template below as `targetRevision`. (At time of writing: `9.1.0` is a known-good pin. If `helm search` shows newer, use that.)

- [ ] **Step 2: Create `argocd/root/templates/reflector.yaml`**

```yaml
# emberstack/reflector — mirrors annotated Secrets across namespaces.
# Used to copy CNPG-managed role credential Secrets from trakrf-system
# into trakrf-preview / trakrf-prod so app pods can mount them.
# Cluster-scoped operator, installed in its own namespace.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: reflector
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: trakrf
  source:
    repoURL: https://emberstack.github.io/helm-charts
    chart: reflector
    targetRevision: "9.1.0"  # update to the version from `helm search` above
    helm:
      values: |
        # No customization needed — the operator reads annotations
        # off the source Secrets and reflects accordingly.
  destination:
    server: {{ .Values.destination.server }}
    namespace: reflector
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 3: Render via helm template**

```bash
helm template argocd/root -f argocd/root/values.yaml \
  --set cluster=gke \
  | grep -A 5 "name: reflector"
```
Expected: emits the Application manifest cleanly, no template error.

- [ ] **Step 4: Commit**

```bash
git add argocd/root/templates/reflector.yaml
git commit -m "feat(argocd): add emberstack/reflector Application at wave -1"
```

---

## Task 3: Restructure `helm/trakrf-db/values.yaml` around an envs list

Replace the singular `managedRoles:` block with an `envs:` list. Drop `postInitApplicationSQL` (moves to per-env init Jobs in Task 5). Change `initdb.database` / `initdb.owner` to the preview env names.

**Files:**
- Modify: `helm/trakrf-db/values.yaml`

- [ ] **Step 1: Replace `helm/trakrf-db/values.yaml` with**

```yaml
# Common CNPG+Timescale defaults. Storage class + affinity per cluster overlay.
# Managed role passwordSecrets (4 of them, one per env-role pair) are
# created out-of-band by `just db-secrets` — do not template them here.

fullnameOverride: trakrf-db

cluster:
  instances: 1
  imageName: ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18

postgresql:
  sharedPreloadLibraries:
    - timescaledb
  parameters:
    timescaledb.license: timescale
    password_encryption: scram-sha-256

# `initdb` bootstraps a single Postgres database. We use trakrf_preview as
# the initial DB so its owner role (trakrf-migrate-preview) is also created
# by initdb. The trakrf_prod database is created later by a Database CRD
# (templates/databases.yaml) and its roles by `managed.roles` below.
bootstrap:
  initdb:
    database: trakrf_preview
    owner: trakrf-migrate-preview
    postInitTemplateSQL:
      - CREATE EXTENSION IF NOT EXISTS timescaledb
    postInitSQL: []
    # All schema/grants are applied by per-env post-install Jobs
    # (templates/init-grants-job.yaml) so the bootstrap path and the
    # second-DB path use one source of truth.
    postInitApplicationSQL: []

# Each entry defines one Postgres database and its role pair.
# Database CRD (templates/databases.yaml) and managed-role list
# (templates/cluster.yaml) both range over this.
envs:
  - name: preview
    database: trakrf_preview          # Postgres DB name (underscore)
    cnpgDatabaseName: trakrf-preview  # K8s Database CRD metadata.name (hyphen)
    appRole: trakrf-app-preview
    migrateRole: trakrf-migrate-preview
    appSecret: trakrf-app-preview-credentials
    migrateSecret: trakrf-migrate-preview-credentials
    reflectTo: trakrf-preview
  - name: prod
    database: trakrf_prod
    cnpgDatabaseName: trakrf-prod
    appRole: trakrf-app-prod
    migrateRole: trakrf-migrate-prod
    appSecret: trakrf-app-prod-credentials
    migrateSecret: trakrf-migrate-prod-credentials
    reflectTo: trakrf-prod

# Init-grants Job knobs (one Job per env via templates/init-grants-job.yaml)
initGrantsJob:
  # CNPG ships psql in its postgresql image
  image: ghcr.io/cloudnative-pg/postgresql:17.2
  # The DB host the Job connects to — CNPG service in the chart's namespace
  host: trakrf-db-rw

storage:
  size: 10Gi
  class: ""              # REQUIRED — set in values-<cluster>.yaml

affinity:
  nodeSelector: {}
  tolerations: []
```

- [ ] **Step 2: Render and inspect**

```bash
helm template helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml
```
Expected: error about managed.roles being empty (templates/cluster.yaml still references the old `managedRoles:` key — fixed in next task) OR clean render if templates were already updated. Either way confirms values syntax is valid YAML.

You can also pre-flight with `yq`:
```bash
yq '.envs[].name' helm/trakrf-db/values.yaml
# expect: preview, prod
```

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-db/values.yaml
git commit -m "refactor(trakrf-db): values shift to envs list for multi-env DB tenancy"
```

---

## Task 4: Update `helm/trakrf-db/templates/cluster.yaml` to range over envs

`managed.roles:` now generates four entries from `.Values.envs`. Bootstrap `postInitApplicationSQL`/`postInitSQL` reference the empty lists (moved to Jobs).

**Files:**
- Modify: `helm/trakrf-db/templates/cluster.yaml`

- [ ] **Step 1: Replace `helm/trakrf-db/templates/cluster.yaml` with**

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
      database: {{ .Values.bootstrap.initdb.database }}
      owner: {{ .Values.bootstrap.initdb.owner | quote }}
      postInitTemplateSQL:
        {{- range .Values.bootstrap.initdb.postInitTemplateSQL }}
        - {{ . | quote }}
        {{- end }}
      postInitSQL:
        {{- range .Values.bootstrap.initdb.postInitSQL }}
        - {{ . | quote }}
        {{- end }}
      postInitApplicationSQL:
        {{- range .Values.bootstrap.initdb.postInitApplicationSQL }}
        - {{ . | quote }}
        {{- end }}

  managed:
    roles:
      {{- range .Values.envs }}
      - name: {{ .appRole | quote }}
        ensure: present
        login: true
        superuser: false
        createdb: false
        createrole: false
        passwordSecret:
          name: {{ .appSecret | quote }}
      - name: {{ .migrateRole | quote }}
        ensure: present
        login: true
        superuser: false
        createdb: true
        createrole: false
        passwordSecret:
          name: {{ .migrateSecret | quote }}
      {{- end }}

  storage:
    size: {{ .Values.storage.size }}
    storageClass: {{ required "storage.class must be set in values-<cluster>.yaml" .Values.storage.class | quote }}

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

- [ ] **Step 2: Render and verify**

```bash
helm template helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  | yq 'select(.kind == "Cluster") | .spec.managed.roles[].name'
```
Expected:
```
trakrf-app-preview
trakrf-migrate-preview
trakrf-app-prod
trakrf-migrate-prod
```

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-db/templates/cluster.yaml
git commit -m "refactor(trakrf-db): cluster template ranges managed.roles over envs"
```

---

## Task 5: Add `helm/trakrf-db/templates/databases.yaml`

One `postgresql.cnpg.io/v1 Database` per env. The preview DB exists (initdb made it); declaring it with `ensure: present` brings it into the model without recreation.

**Files:**
- Create: `helm/trakrf-db/templates/databases.yaml`

- [ ] **Step 1: Create `helm/trakrf-db/templates/databases.yaml`**

```yaml
{{- /*
  One CNPG Database CRD per env entry. The preview DB is already created
  by initdb; ensure: present reconciles it into the model without dropping.
  Each Database is owned by its env-specific migrate role so the role can
  CREATE SCHEMA + GRANT inside its own DB without superuser.
*/ -}}
{{- range $env := .Values.envs }}
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: {{ $env.cnpgDatabaseName | quote }}
  namespace: {{ $.Release.Namespace }}
spec:
  name: {{ $env.database | quote }}
  owner: {{ $env.migrateRole | quote }}
  cluster:
    name: {{ $.Values.fullnameOverride | default "trakrf-db" }}
  ensure: present
{{- end }}
```

- [ ] **Step 2: Render and verify**

```bash
helm template helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  | yq 'select(.kind == "Database") | .metadata.name + " -> " + .spec.name'
```
Expected:
```
trakrf-preview -> trakrf_preview
trakrf-prod -> trakrf_prod
```

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-db/templates/databases.yaml
git commit -m "feat(trakrf-db): declare Database CRD per env (trakrf-preview, trakrf-prod)"
```

---

## Task 6: Add `helm/trakrf-db/templates/init-grants-job.yaml`

One Helm post-install,post-upgrade hook Job per env. Runs idempotent SQL as the env's migrate role: creates schema, grants `trakrf-app-<env>` privileges, sets `app.current_org_id` default.

**Files:**
- Create: `helm/trakrf-db/templates/init-grants-job.yaml`

- [ ] **Step 1: Create `helm/trakrf-db/templates/init-grants-job.yaml`**

```yaml
{{- /*
  Per-env init Job — applies schema + grants in each Postgres database.
  Runs as a Helm post-install,post-upgrade hook so it lands after the
  CNPG operator has created the managed roles and the Database CRDs
  have reconciled. SQL is idempotent so a re-run on every chart
  upgrade is a no-op when grants are already in place.

  The Job connects to trakrf-db-rw as the env's migrate role, reading
  the password from the same Secret CNPG manages for that role.
*/ -}}
{{- range $env := .Values.envs }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ printf "trakrf-db-init-grants-%s" $env.name }}
  namespace: {{ $.Release.Namespace }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 6
  template:
    metadata:
      name: {{ printf "trakrf-db-init-grants-%s" $env.name }}
    spec:
      restartPolicy: OnFailure
      {{- with $.Values.affinity.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $.Values.affinity.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: psql
          image: {{ $.Values.initGrantsJob.image | quote }}
          env:
            - name: PGHOST
              value: {{ $.Values.initGrantsJob.host | quote }}
            - name: PGPORT
              value: "5432"
            - name: PGSSLMODE
              value: require
            - name: PGDATABASE
              value: {{ $env.database | quote }}
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: {{ $env.migrateSecret | quote }}
                  key: username
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ $env.migrateSecret | quote }}
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
              CREATE SCHEMA IF NOT EXISTS trakrf AUTHORIZATION "{{ $env.migrateRole }}";
              GRANT CONNECT ON DATABASE {{ $env.database }} TO "{{ $env.appRole }}";
              GRANT USAGE ON SCHEMA trakrf TO "{{ $env.appRole }}";
              ALTER DEFAULT PRIVILEGES FOR ROLE "{{ $env.migrateRole }}" IN SCHEMA trakrf
                GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{{ $env.appRole }}";
              ALTER DEFAULT PRIVILEGES FOR ROLE "{{ $env.migrateRole }}" IN SCHEMA trakrf
                GRANT USAGE, SELECT ON SEQUENCES TO "{{ $env.appRole }}";
              ALTER ROLE "{{ $env.appRole }}" SET app.current_org_id = '0';
              SQL
{{- end }}
```

- [ ] **Step 2: Render and verify**

```bash
helm template helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  | yq 'select(.kind == "Job") | .metadata.name'
```
Expected:
```
trakrf-db-init-grants-preview
trakrf-db-init-grants-prod
```

Also confirm the rendered SQL substitutes the env values:
```bash
helm template helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  | grep -E "CREATE SCHEMA|GRANT CONNECT|ALTER ROLE" | head -10
```
Expected: two sets of SQL (preview + prod), each referencing the correct role names.

- [ ] **Step 3: Commit**

```bash
git add helm/trakrf-db/templates/init-grants-job.yaml
git commit -m "feat(trakrf-db): per-env post-install Job applies schema + grants"
```

---

## Task 7: Update `argocd/root/values.yaml` namespaces

Drop `namespaces.trakrf`; add three new keys.

**Files:**
- Modify: `argocd/root/values.yaml`

- [ ] **Step 1: Edit `argocd/root/values.yaml`**

Replace:
```yaml
namespaces:
  argocd: argocd
  certManager: cert-manager
  traefik: traefik
  trakrf: trakrf
```

with:
```yaml
namespaces:
  argocd: argocd
  certManager: cert-manager
  traefik: traefik
  trakrfSystem: trakrf-system
  trakrfPreview: trakrf-preview
  trakrfProd: trakrf-prod
```

- [ ] **Step 2: Render and verify keys exist**

```bash
yq '.namespaces' argocd/root/values.yaml
```
Expected: shows the four keys above (argocd, certManager, traefik, trakrfSystem, trakrfPreview, trakrfProd) — six total.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/values.yaml
git commit -m "chore(argocd): split trakrf namespace into trakrf-system/preview/prod"
```

---

## Task 8: Point `argocd/root/templates/trakrf-db.yaml` at `trakrf-system`

**Files:**
- Modify: `argocd/root/templates/trakrf-db.yaml`

- [ ] **Step 1: Replace `argocd/root/templates/trakrf-db.yaml` with**

```yaml
{{- /* CNPG operator fills runtime defaults on the Cluster spec
       (connectionLimit, inRoles, etc.). Ignore fields owned by the
       operator's field manager to silence cosmetic OutOfSync. */ -}}
{{- /* CNPG's Go client uses the default field manager name "manager".
       Ignoring fields owned by it filters out all operator-filled
       defaults (podAntiAffinityType, connectionLimit, inherit, etc.). */ -}}
{{- $ignore := "- group: postgresql.cnpg.io\n  kind: Cluster\n  name: trakrf-db\n  managedFieldsManagers:\n    - manager\n" -}}
{{- include "trakrf.application" (dict
  "name" "trakrf-db"
  "path" "helm/trakrf-db"
  "namespace" .Values.namespaces.trakrfSystem
  "syncWave" "0"
  "cluster" .Values.cluster
  "repoURL" .Values.repoURL
  "targetRevision" .Values.targetRevision
  "destination" .Values.destination
  "inlineValues" ""
  "ignoreDifferences" $ignore
) }}
```

- [ ] **Step 2: Render and verify destination namespace**

```bash
helm template argocd/root -f argocd/root/values.yaml --set cluster=gke \
  | yq 'select(.metadata.name == "trakrf-db") | .spec.destination.namespace'
```
Expected: `trakrf-system`.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/trakrf-db.yaml
git commit -m "chore(argocd): move trakrf-db Application to trakrf-system namespace"
```

---

## Task 9: Fan out `argocd/root/templates/trakrf-backend.yaml` per env

`range` over `preview`/`prod`; emit one Application per env with per-env `inlineValues`. `ingress.enabled: false` since this PR punts cert/DNS.

**Files:**
- Modify: `argocd/root/templates/trakrf-backend.yaml`

- [ ] **Step 1: Replace `argocd/root/templates/trakrf-backend.yaml` with**

```yaml
{{- /*
  One trakrf-backend Application per env (preview, prod). Each release
  installs into its own namespace and connects to its own Postgres
  database via its own credentials. Ingress is disabled for now — temp
  soak hostnames + cert issuance are a follow-up ticket.
*/ -}}
{{- range $env := list "preview" "prod" }}
{{- $values := printf "database:\n  name: trakrf_%s\n  credentialsSecret: trakrf-app-%s-credentials\n  host: trakrf-db-rw.trakrf-system\nmigrate:\n  database: trakrf_%s\n  credentialsSecret: trakrf-migrate-%s-credentials\n  host: trakrf-db-rw.trakrf-system\nconfig:\n  appEnv: %s\ningress:\n  enabled: false\n" $env $env $env $env $env }}
---
{{- include "trakrf.application" (dict
  "name" (printf "trakrf-backend-%s" $env)
  "path" "helm/trakrf-backend"
  "namespace" (printf "trakrf-%s" $env)
  "syncWave" "1"
  "cluster" $.Values.cluster
  "repoURL" $.Values.repoURL
  "targetRevision" $.Values.targetRevision
  "destination" $.Values.destination
  "inlineValues" $values
) }}
{{- end }}
```

Both `database.host` and `migrate.host` are overridden to `trakrf-db-rw.trakrf-system` — the chart defaults are same-namespace short names, but the backend now lives in a different namespace from the DB, so the fully-qualified service DNS is required.

- [ ] **Step 2: Render and verify Application names + inlineValues**

```bash
helm template argocd/root -f argocd/root/values.yaml --set cluster=gke \
  | yq 'select(.metadata.name | test("trakrf-backend")) | .metadata.name + " -> " + .spec.destination.namespace'
```
Expected:
```
trakrf-backend-preview -> trakrf-preview
trakrf-backend-prod -> trakrf-prod
```

Spot-check inlineValues:
```bash
helm template argocd/root -f argocd/root/values.yaml --set cluster=gke \
  | yq 'select(.metadata.name == "trakrf-backend-preview") | .spec.source.helm.values'
```
Expected: includes `name: trakrf_preview`, `credentialsSecret: trakrf-app-preview-credentials`, `host: trakrf-db-rw.trakrf-system`, `appEnv: preview`, `enabled: false`.

If yq emits "duplicate key" warning, switch to the single-`database:` form shown above and re-test.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/trakrf-backend.yaml
git commit -m "feat(argocd): fan out trakrf-backend Application per env (preview, prod)"
```

---

## Task 10: Fan out `argocd/root/templates/trakrf-ingester.yaml` per env

Same pattern as Task 9. The ingester chart has its own `database.*` keys; confirm structure matches before copying.

**Files:**
- Modify: `argocd/root/templates/trakrf-ingester.yaml`

- [ ] **Step 1: Inspect existing ingester values to find the right keys**

```bash
grep -E "^(database|migrate|config|ingress):" -A 5 helm/trakrf-ingester/values.yaml
```
Expected: shows the `database:` block and any ingress key. Note exact key names (e.g., `database.name`, `database.credentialsSecret`, `database.host`).

- [ ] **Step 2: Replace `argocd/root/templates/trakrf-ingester.yaml` with**

```yaml
{{- /*
  One trakrf-ingester Application per env. Mirrors the trakrf-backend
  pattern — same per-env DB credentials, same trakrf-system DB host.
*/ -}}
{{- range $env := list "preview" "prod" }}
{{- $values := printf "database:\n  name: trakrf_%s\n  credentialsSecret: trakrf-app-%s-credentials\n  host: trakrf-db-rw.trakrf-system\n" $env $env }}
---
{{- include "trakrf.application" (dict
  "name" (printf "trakrf-ingester-%s" $env)
  "path" "helm/trakrf-ingester"
  "namespace" (printf "trakrf-%s" $env)
  "syncWave" "1"
  "cluster" $.Values.cluster
  "repoURL" $.Values.repoURL
  "targetRevision" $.Values.targetRevision
  "destination" $.Values.destination
  "inlineValues" $values
) }}
{{- end }}
```

If `helm/trakrf-ingester/values.yaml` uses different key names than the ones above (e.g. `db.*` instead of `database.*`), adjust the printf accordingly before committing — Step 1 surfaces this.

- [ ] **Step 3: Render and verify**

```bash
helm template argocd/root -f argocd/root/values.yaml --set cluster=gke \
  | yq 'select(.metadata.name | test("trakrf-ingester")) | .metadata.name + " -> " + .spec.destination.namespace'
```
Expected:
```
trakrf-ingester-preview -> trakrf-preview
trakrf-ingester-prod -> trakrf-prod
```

- [ ] **Step 4: Commit**

```bash
git add argocd/root/templates/trakrf-ingester.yaml
git commit -m "feat(argocd): fan out trakrf-ingester Application per env"
```

---

## Task 11: Extend `justfile` db-secrets recipe for per-env credentials

Four passwords, four annotated Secrets in `trakrf-system`. Reflector annotations cause emberstack/reflector to mirror each Secret into its target env namespace.

**Files:**
- Modify: `justfile` (the `db-secrets` recipe, around line 93)

- [ ] **Step 1: Inspect the current `db-secrets` recipe**

```bash
grep -n -A 20 "^db-secrets:" justfile
```

- [ ] **Step 2: Replace the `db-secrets` recipe block**

Replace lines 93–105 (the existing `db-secrets:` block) with:

```makefile
# Create per-env CNPG role secrets in trakrf-system with reflector annotations
# so they mirror into trakrf-preview / trakrf-prod. Run BEFORE argocd-bootstrap.
# Requires four passwords in .env.local:
#   TRAKRF_APP_DB_PASSWORD_PREVIEW
#   TRAKRF_APP_DB_PASSWORD_PROD
#   TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW
#   TRAKRF_MIGRATE_DB_PASSWORD_PROD
# Generate with: openssl rand -hex 32  (avoid base64 — / and + break URL DSNs)
db-secrets:
    @kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${TRAKRF_APP_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_APP_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @for env in preview prod; do \
      for role in app migrate; do \
        upper_env=$$(echo $$env | tr '[:lower:]' '[:upper:]'); \
        upper_role=$$(echo $$role | tr '[:lower:]' '[:upper:]'); \
        pw_var="TRAKRF_$${upper_role}_DB_PASSWORD_$${upper_env}"; \
        pw=$$(eval "echo \$$$$pw_var"); \
        kubectl create secret generic trakrf-$${role}-$${env}-credentials -n trakrf-system \
          --from-literal=username=trakrf-$${role}-$${env} \
          --from-literal=password="$$pw" \
          --dry-run=client -o yaml | kubectl apply -f -; \
        kubectl annotate --overwrite secret trakrf-$${role}-$${env}-credentials -n trakrf-system \
          reflector.v1.k8s.emberstack.com/reflection-allowed=true \
          reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
          reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-$${env}; \
      done; \
    done
    @echo "Secrets applied + reflector annotations set. Reflector will mirror into trakrf-{preview,prod}."
```

- [ ] **Step 3: Syntax-check the recipe**

```bash
just --list | grep db-secrets
```
Expected: `db-secrets` appears in the list, no parse error.

Also lint the shell:
```bash
just --dry-run db-secrets 2>&1 | head -30
```
Expected: prints the kubectl commands; no syntax error.

- [ ] **Step 4: Update `.env.local.example`** (if it exists)

```bash
test -f .env.local.example && grep -q TRAKRF_APP_DB_PASSWORD .env.local.example && \
  echo "exists; manually replace the two old vars with the four new ones"
```

If `.env.local.example` references the old `TRAKRF_APP_DB_PASSWORD` / `TRAKRF_MIGRATE_DB_PASSWORD`, replace them with the four new env-suffixed vars. If the example file doesn't exist, skip this step.

- [ ] **Step 5: Commit**

```bash
git add justfile .env.local.example 2>/dev/null
git commit -m "chore(just): split db-secrets into 4 per-env credentials with reflector annotations"
```

---

## Task 12: Final helm template smoke across the whole root chart

Belt-and-suspenders render before cluster cutover.

- [ ] **Step 1: Render the entire root chart**

```bash
helm template argocd/root -f argocd/root/values.yaml --set cluster=gke > /tmp/root-render.yaml
echo "Exit: $?"
wc -l /tmp/root-render.yaml
```
Expected: exit 0, nonzero line count.

- [ ] **Step 2: List all Applications**

```bash
yq 'select(.kind == "Application") | .metadata.name' /tmp/root-render.yaml | sort
```
Expected (set; order may vary):
```
argocd
cert-manager
cert-manager-config
reflector
traefik
traefik-config
trakrf-backend-preview
trakrf-backend-prod
trakrf-db
trakrf-ingester-preview
trakrf-ingester-prod
```

- [ ] **Step 3: Render trakrf-db with both cluster overlays for sanity**

```bash
for cluster in gke aks eks; do
  echo "=== $cluster ==="
  helm template helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-$cluster.yaml > /dev/null
  echo "exit=$?"
done
```
Expected: each exits 0. (aks/eks overlays may not be currently active per the cloud portfolio strategy memory, but the chart should still render against them.)

- [ ] **Step 4: Commit nothing — this is a verification gate, not a code change**

If any step fails, fix in the relevant earlier task and re-run.

---

## Task 13: Cutover — apply on GKE cluster, verify acceptance criteria

This is the live-cluster step. Run against the GKE kube-context. Everything before this was source-code work and can land in a PR; this task gates the merge.

- [ ] **Step 1: Switch kube-context to GKE**

```bash
kubectl config use-context gke_<project>_<region>_<cluster>  # adjust to actual name
kubectl config current-context
kubectl get nodes
```
Expected: GKE context active; nodes listed.

- [ ] **Step 2: Generate four passwords + add to `.env.local`**

```bash
for env in preview prod; do
  for role in app migrate; do
    upper_env=$(echo $env | tr '[:lower:]' '[:upper:]')
    upper_role=$(echo $role | tr '[:lower:]' '[:upper:]')
    echo "TRAKRF_${upper_role}_DB_PASSWORD_${upper_env}=$(openssl rand -hex 32)"
  done
done
```
Append the four lines to `.env.local`. (Do NOT commit `.env.local`.)

- [ ] **Step 3: Tear down the old `trakrf` namespace**

```bash
# Remove the old single-env Applications first so ArgoCD doesn't re-sync them
kubectl delete application -n argocd trakrf-backend trakrf-ingester trakrf-db 2>/dev/null || true
# Wait for finalizers to clear
kubectl wait --for=delete application/trakrf-db -n argocd --timeout=120s 2>/dev/null || true
# Now drop the namespace and its PVC
kubectl delete namespace trakrf --wait=true
```

If `kubectl delete namespace trakrf` hangs, check for stuck finalizers:
```bash
kubectl get namespace trakrf -o json | jq '.spec.finalizers'
# If non-empty, the per memory `feedback_argocd_finalizer_blocks_root_sync` cleanup applies.
```

- [ ] **Step 4: Run `just db-secrets`**

```bash
direnv reload  # picks up the new .env.local vars
just db-secrets
kubectl get secret -n trakrf-system | grep credentials
```
Expected: four secrets listed (trakrf-app-preview-credentials, trakrf-app-prod-credentials, trakrf-migrate-preview-credentials, trakrf-migrate-prod-credentials).

Check annotations:
```bash
kubectl get secret trakrf-app-preview-credentials -n trakrf-system -o jsonpath='{.metadata.annotations}' | jq
```
Expected: includes `reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: trakrf-preview`.

- [ ] **Step 5: Push the branch and trigger ArgoCD reconcile**

```bash
git push -u origin <branch-name>
# After merge, ArgoCD will pick up the new manifests on its next refresh.
# To force immediate refresh:
argocd app sync argocd-root --prune || kubectl annotate application argocd-root -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

(The actual merge happens via PR per repo policy. This step assumes the PR is merged. If still pre-merge, ArgoCD can be pointed at the branch via `argocd app set argocd-root --revision <branch>` for soak.)

- [ ] **Step 6: Verify all Applications Synced+Healthy**

```bash
argocd app list -o wide | grep -E 'reflector|trakrf'
```
Expected: `reflector`, `trakrf-db`, `trakrf-backend-preview`, `trakrf-backend-prod`, `trakrf-ingester-preview`, `trakrf-ingester-prod` all `Synced` and `Healthy`. (Cosmetic-OOS on the self-managed `argocd` Application stays per memory.)

- [ ] **Step 7: Verify Database CRDs Ready**

```bash
kubectl get database -n trakrf-system
kubectl get database trakrf-preview -n trakrf-system -o jsonpath='{.status.ready}'
echo
kubectl get database trakrf-prod -n trakrf-system -o jsonpath='{.status.ready}'
echo
```
Expected: both `true`.

- [ ] **Step 8: Verify managed roles reconciled**

```bash
kubectl exec -n trakrf-system trakrf-db-1 -- psql -d trakrf_preview -c "\du"
```
Expected: `trakrf-app-preview`, `trakrf-app-prod`, `trakrf-migrate-preview`, `trakrf-migrate-prod` all listed with `Login` attribute.

```bash
kubectl exec -n trakrf-system trakrf-db-1 -- psql -d trakrf_preview -c "\dn"
```
Expected: `trakrf` schema owned by `trakrf-migrate-preview`.

Same against the prod DB:
```bash
kubectl exec -n trakrf-system trakrf-db-1 -- psql -d trakrf_prod -c "\dn"
```
Expected: `trakrf` schema owned by `trakrf-migrate-prod`.

- [ ] **Step 9: Verify reflector mirror**

```bash
kubectl get secret -n trakrf-preview | grep credentials
kubectl get secret -n trakrf-prod | grep credentials
```
Expected: each env ns has its own two secrets (`trakrf-app-<env>-credentials`, `trakrf-migrate-<env>-credentials`).

```bash
kubectl get secret trakrf-app-preview-credentials -n trakrf-preview -o jsonpath='{.metadata.annotations}' | jq | grep reflected-version
```
Expected: presence of `reflector.v1.k8s.emberstack.com/reflected-version` annotation.

- [ ] **Step 10: Verify backend app health per env**

```bash
kubectl get pods -n trakrf-preview
kubectl logs -n trakrf-preview job/trakrf-backend-migrate | tail -20
kubectl exec -n trakrf-preview deploy/trakrf-backend -- printenv | grep ^PG_URL
```
Expected: pods Running, migrate job Succeeded, PG_URL targets `trakrf_preview` on `trakrf-db-rw.trakrf-system`.

Port-forward and hit /healthz:
```bash
kubectl port-forward -n trakrf-preview svc/trakrf-backend 8080:8080 &
PF=$!
sleep 2
curl -fsS http://localhost:8080/healthz
kill $PF
```
Expected: 200 OK.

Repeat against `trakrf-prod`.

- [ ] **Step 11: Run the per-env isolation negative test**

```bash
PREV_PW=$(kubectl get secret -n trakrf-preview trakrf-app-preview-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl run --rm -it --restart=Never psql-neg --image=postgres:17 -n trakrf-prod \
  --env=PGPASSWORD="$PREV_PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app-preview -d trakrf_prod -c "SELECT 1;"
```
Expected: error along the lines of `FATAL: permission denied for database "trakrf_prod"` (CONNECT privilege missing). The auth succeeds (the password is real); the database access is what's denied.

Symmetric test:
```bash
PROD_PW=$(kubectl get secret -n trakrf-prod trakrf-app-prod-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl run --rm -it --restart=Never psql-neg2 --image=postgres:17 -n trakrf-preview \
  --env=PGPASSWORD="$PROD_PW" -- \
  psql -h trakrf-db-rw.trakrf-system -U trakrf-app-prod -d trakrf_preview -c "SELECT 1;"
```
Expected: same `permission denied for database "trakrf_preview"`.

- [ ] **Step 12: Document verification in the PR description**

Copy the command outputs from Steps 7–11 into the PR description as evidence. Tie each output back to the spec's AC. The PR is ready to merge once all ACs are green.

---

## Task 14: Open the PR

Per CLAUDE.md: never merge to main locally — push the branch and open a PR.

- [ ] **Step 1: Push branch and open PR**

```bash
git push -u origin miks2u/tra-823-gke-multi-env-db-tenancy-db-per-env-on-shared-cnpg-database
gh pr create --title "feat(gke): multi-env DB tenancy on shared CNPG (TRA-823)" --body "$(cat <<'EOF'
## Summary
- CNPG Cluster moves to `trakrf-system` ns; two Database CRDs (`trakrf-preview`, `trakrf-prod`) on it
- Per-env managed roles replace shared `trakrf-app`/`trakrf-migrate` — split credentials
- emberstack/reflector mirrors role passwordSecrets into per-env app namespaces
- `trakrf-backend` + `trakrf-ingester` Applications fan out per env via `range`
- `just db-secrets` extended to four annotated Secrets

## Test plan
- [x] `helm template argocd/root` renders all Applications cleanly
- [x] `helm template helm/trakrf-db` renders 2 Databases, 4 managed roles, 2 init Jobs
- [x] On GKE: `kubectl get database -n trakrf-system` shows both Ready
- [x] On GKE: `\du` lists 4 per-env roles, no shared `trakrf-app`/`trakrf-migrate`
- [x] On GKE: `\dn` per DB shows `trakrf` schema owned by env's migrate role
- [x] On GKE: reflector mirrors credentials into `trakrf-{preview,prod}`
- [x] On GKE: backend `/healthz` 200 in each env via port-forward; migrate Job Succeeded
- [x] On GKE: negative test — preview creds cannot CONNECT to prod DB and vice versa
- [x] ArgoCD: all `trakrf-*` and `reflector` Apps Synced+Healthy

Out of scope (deferred tickets):
- Cert issuance + DNS records for soak hostnames against `trakrf.id`
- Data cutover off Railway / TimescaleDB Cloud (TRA-810, TRA-825)
- DB HA + replicas (TRA-544)
- Backups (TRA-798)
- External Secrets / Infisical (TRA-362) — reflector is the transitional mirror

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Done.

---

## Self-review notes (informational, not steps)

- **Spec coverage:** every AC has at least one verification step in Task 13. The three "pieces" (Database CRDs, role split, secret mirror) map to Tasks 5+8, 4+11, 2+11 respectively.
- **Out-of-scope items** match the spec exactly. Cert/DNS punted; PR body lists this.
- **Naming consistency:** k8s names use hyphens (`trakrf-preview`, `trakrf-prod`), Postgres DB names use underscores (`trakrf_preview`, `trakrf_prod`). Same convention throughout.
- **Idempotency:** init Job SQL uses `IF NOT EXISTS` for schema; all GRANTs and ALTER DEFAULT PRIVILEGES are idempotent in Postgres. Hook delete policy ensures Job re-runs on every upgrade without orphaning state.
- **Rollback path:** if anything goes wrong on cutover, the destroy-and-recreate path is symmetric — `kubectl delete ns trakrf-{system,preview,prod}`, fix the offending file, push, re-sync. Data loss already accepted.
