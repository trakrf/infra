# Cluster-per-env CNPG (prod half) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a dedicated `trakrf-db-prod` CNPG Cluster co-located with backend + ingester in `trakrf-prod`, migrate prod data off TimescaleDB Cloud, and prove restore via a full DR drill — all without touching the user-facing `app.trakrf.id` DNS (Saturday's TRA-375 cutover). Smoke testing happens via a dry-run hostname `app.prod.gke.trakrf.id`.

**Architecture:** Reuses the TRA-849 `helm/trakrf-db` chart unchanged — the prod release is values-only: `fullnameOverride: trakrf-db-prod`, `namespace: trakrf-prod`. Two tofu WI bindings on the existing `cnpg-backups-demo` GSA cover the prod Cluster pod KSA + prod pg_dump KSA (third binding added temporarily for DR drill). A small rename + parameterization of the ingress helper in `argocd/root/templates/_helpers.tpl` lets the existing `trakrf-backend.yaml` env loop emit per-env ingress for both preview and prod with no env-name string conditionals.

**Tech Stack:** OpenTofu + GCP provider, Helm, ArgoCD, CNPG 1.29, CloudNativePG-Timescale image, postgres_fdw (migration source), Traefik IngressRoute + cert-manager Certificate.

**Reference spec:** `docs/superpowers/specs/2026-05-27-tra-850-cluster-per-env-cnpg-prod-design.md`

---

## File Structure

**Modified — Terraform:**
- `terraform/gcp/cnpg_backups.tf` — two new permanent `google_service_account_iam_member` resources (`trakrf-prod/trakrf-db-prod` cluster KSA + `trakrf-prod/cnpg-backups` pg_dump KSA). One temporary resource for the DR drill (`trakrf-prod/trakrf-db-prod-dr`), removed in DR teardown. Add `trakrf-db-prod/dump/` to lifecycle `matches_prefix`.

**Modified — Root chart values:**
- `argocd/root/values.yaml` — `envs.prod` overlay flip: `dbHost`, `ingressEnabled`, `dbCluster.{enabled,fullnameOverride,namespace}`.

**Modified — Root chart templates:**
- `argocd/root/templates/_helpers.tpl` — rename `trakrf-backend.previewIngressValues` → `trakrf-backend.ingressValues`; add env param; gate the CF grey-cloud `app.<env>.trakrf.id` route on a per-env flag (default on for preview, off for prod).
- `argocd/root/templates/trakrf-backend.yaml` — pass `env` + per-env config dict into the helper. Preview output stays bit-for-bit; prod emits only the gke-direct route.

**Modified — Justfile:**
- `justfile` — `db-secrets` recipe drops the reflector branch entirely. Prod Secrets land natively in `trakrf-prod`. The `_db-secret` helper signature drops the `REFLECT` parameter.

**Modified — Docs:**
- `docs/db-migration.md` — add a "Restore drill" section capturing the DR drill choreography.
- `docs/superpowers/specs/2026-05-27-tra-850-cluster-per-env-cnpg-prod-design.md` — already committed in `8d8e90c`.
- `docs/superpowers/plans/2026-05-27-tra-850-cluster-per-env-cnpg-prod.md` — this file.

**NOT modified (covered by TRA-849):**
- `helm/trakrf-db/` chart — single-env flat values; the prod release uses identical templates.
- `helm/trakrf-backend/` chart — IngressRoute/Certificate/Middleware templates already values-driven.
- `argocd/root/templates/trakrf-db.yaml` — iterates `envs`, emits one Cluster Application per enabled env. Flipping `envs.prod.dbCluster.enabled: true` is the entire activation.
- `argocd/root/templates/trakrf-ingester.yaml` — picks up new `dbHost` automatically; no template touch.
- `argocd/projects/trakrf.yaml` — destinations already cover `trakrf-prod` ns (verified at Task 6).

---

## Task 1 — Tofu: permanent WI bindings for prod Cluster + pg_dump KSAs

**Files:**
- Modify: `terraform/gcp/cnpg_backups.tf`

- [ ] **Step 1: Append two new resources after the preview WI bindings (after `cnpg_backups_wi_pgdump_preview`)**

```hcl
# CNPG prod Cluster pods (phase-2 WAL archiving + base backups).
# Cluster's pod SA is named after the Cluster (trakrf-db-prod).
resource "google_service_account_iam_member" "cnpg_backups_wi_cluster_prod" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-prod/trakrf-db-prod]"
}

# Prod pg_dump CronJob KSA (phase-1 logical backup).
resource "google_service_account_iam_member" "cnpg_backups_wi_pgdump_prod" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-prod/cnpg-backups]"
}
```

- [ ] **Step 2: Broaden the GCS lifecycle `matches_prefix` to include `trakrf-db-prod/dump/`**

Edit the `lifecycle_rule.condition.matches_prefix` array (currently at `terraform/gcp/cnpg_backups.tf:35-40`):

```hcl
  matches_prefix = [
    "trakrf-db/dump/",
    "trakrf-db-preview/dump/",
    "trakrf-db-prod/dump/",
    "preview/",
    "prod/",
  ]
```

- [ ] **Step 3: Plan and verify**

Run from repo root: `tofu -chdir=terraform/gcp init -backend-config=backend.conf && tofu -chdir=terraform/gcp plan -out=tfplan`

Expected output:
- `google_service_account_iam_member.cnpg_backups_wi_cluster_prod` to be created
- `google_service_account_iam_member.cnpg_backups_wi_pgdump_prod` to be created
- `google_storage_bucket.cnpg_backups` to be updated in-place (matches_prefix change)
- "Plan: 2 to add, 1 to change, 0 to destroy."

Do NOT apply yet — apply happens in Task 9 (post-merge).

- [ ] **Step 4: Commit**

```bash
git add terraform/gcp/cnpg_backups.tf
git commit -m "feat(gcp): WI bindings for trakrf-db-prod cluster + pg_dump KSAs"
```

---

## Task 2 — Root values: prod overlay flip

**Files:**
- Modify: `argocd/root/values.yaml`

- [ ] **Step 1: Edit `argocd/root/values.yaml` — replace the `envs.prod` block**

The current block (at `argocd/root/values.yaml:55-64`):

```yaml
  prod:
    dbHost: trakrf-db-rw.trakrf-system
    ingressEnabled: false
    mqttIp: ""
    dbCluster:
      enabled: false
      fullnameOverride: trakrf-db
      namespace: trakrf-system
      createRetainClass: false
      externalIp: ""
```

Replace with:

```yaml
  prod:
    dbHost: trakrf-db-prod-rw.trakrf-prod
    ingressEnabled: true
    mqttIp: ""
    dbCluster:
      enabled: true
      fullnameOverride: trakrf-db-prod
      namespace: trakrf-prod
      createRetainClass: false
      externalIp: ""
```

- [ ] **Step 2: Helm-render the root chart to verify nothing else breaks**

Run from repo root:
```bash
helm template root argocd/root -f argocd/root/values.yaml --set cluster=gke > /tmp/root-render.yaml
echo "exit=$?"
grep -c 'kind: Application' /tmp/root-render.yaml
```

Expected: exit=0; Application count = previous count + 1 (new `trakrf-db-prod` Application from the existing `trakrf-db.yaml` envs loop).

- [ ] **Step 3: Commit**

```bash
git add argocd/root/values.yaml
git commit -m "feat(argocd/root): flip envs.prod onto dedicated trakrf-db-prod Cluster"
```

---

## Task 3 — Helper: rename + parameterize ingress helper

**Files:**
- Modify: `argocd/root/templates/_helpers.tpl`

Current state: `trakrf-backend.previewIngressValues` (at `_helpers.tpl:86-129`) hardcodes `app.preview.gke.trakrf.id` and `app.preview.trakrf.id`. We rename to `trakrf-backend.ingressValues` and take env from caller context. The CF grey-cloud `app.<env>.trakrf.id` route is gated on a flag passed by the caller (default behavior at the call site preserves preview's current output bit-for-bit).

- [ ] **Step 1: Replace the helper definition**

Find the block `{{- define "trakrf-backend.previewIngressValues" -}}` through `{{- end -}}` (lines 86-129). Replace with:

```gotemplate
{{/*
  trakrf-backend.ingressValues — YAML block injected into a trakrf-backend
  Application's inline helm.values. Renders the GKE-direct route
  `app.<env>.gke.trakrf.id` (always when ingress is on) and optionally the
  CF grey-cloud route `app.<env>.trakrf.id` (gated on .appTrakrfIdRouteEnabled).
  Both Cloudflare/breakglass IPAllowList middlewares are always emitted —
  they're cheap and future-proof for the Saturday `app.trakrf.id` route.

  Caller MUST pass a dict with:
    env                       — env slug ("preview", "prod")
    appTrakrfIdRouteEnabled   — bool; true on preview today, false on prod
                                (prod's CF grey-cloud route lands Saturday)
    breakglassSourceCidr      — root values pass-through
    cloudflareIpv4Cidrs       — root values pass-through (list)
    cloudflareIpv6Cidrs       — root values pass-through (list)
*/}}
{{- define "trakrf-backend.ingressValues" -}}
ingress:
  enabled: true
  routes:
    - name: gke-direct
      host: app.{{ .env }}.gke.trakrf.id
      secretName: app-{{ .env }}-gke-trakrf-id-tls
      cert:
        issue: true
        issuer: letsencrypt-prod
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: breakglass-allow
    {{- if .appTrakrfIdRouteEnabled }}
    # `app.<env>.trakrf.id` runs grey-cloud (CF DNS-only) because CF Universal
    # SSL (Free tier) can't issue an edge cert for two-label hosts under
    # trakrf.id. Per-host LE cert via HTTP-01 at origin; same breakglass
    # IPAllowList as the gke-direct route. The Origin Cert + cloudflare-allow
    # middleware live on for future use when prod cutover lands ACM/Total TLS.
    - name: trakrf-id-direct
      host: app.{{ .env }}.trakrf.id
      secretName: app-{{ .env }}-trakrf-id-tls
      cert:
        issue: true
        issuer: letsencrypt-prod
      middlewares:
        - name: default-chain
          namespace: traefik
        - name: breakglass-allow
    {{- end }}
  middlewares:
    breakglass:
      enabled: true
      sourceRange:
        - {{ .breakglassSourceCidr | quote }}
    cloudflare:
      enabled: true
      sourceRange:
        {{- range .cloudflareIpv4Cidrs }}
        - {{ . | quote }}
        {{- end }}
        {{- range .cloudflareIpv6Cidrs }}
        - {{ . | quote }}
        {{- end }}
{{- end -}}
```

- [ ] **Step 2: Verify no other callers of the old name exist**

```bash
grep -rn "previewIngressValues" argocd/ helm/
```

Expected: zero matches (Task 4 updates the only caller).

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/_helpers.tpl
git commit -m "refactor(argocd/root): parameterize ingress helper by env"
```

---

## Task 4 — `trakrf-backend.yaml`: route both envs through parameterized helper

**Files:**
- Modify: `argocd/root/templates/trakrf-backend.yaml`

Current state: `trakrf-backend.yaml:18-21` flips on `$cfg.ingressEnabled` and calls `previewIngressValues` with `$` (the root chart context). After Task 3 the helper expects a dict — we build it here.

- [ ] **Step 1: Replace the ingress branch**

Find this block (at `trakrf-backend.yaml:18-21`):

```gotemplate
{{- $ingress := "ingress:\n  enabled: false\n" }}
{{- if $cfg.ingressEnabled }}
{{- $ingress = include "trakrf-backend.previewIngressValues" $ }}
{{- end }}
```

Replace with:

```gotemplate
{{- $ingress := "ingress:\n  enabled: false\n" }}
{{- if $cfg.ingressEnabled }}
{{- $ingressCtx := dict
      "env" $env
      "appTrakrfIdRouteEnabled" (eq $env "preview")
      "breakglassSourceCidr" $.Values.breakglassSourceCidr
      "cloudflareIpv4Cidrs" $.Values.cloudflareIpv4Cidrs
      "cloudflareIpv6Cidrs" $.Values.cloudflareIpv6Cidrs }}
{{- $ingress = include "trakrf-backend.ingressValues" $ingressCtx }}
{{- end }}
```

- [ ] **Step 2: Helm-render diff to verify preview output is unchanged + prod output gains the route**

```bash
# Render with cluster=gke (the only env where ingress is on for either env)
helm template root argocd/root \
  -f argocd/root/values.yaml \
  --set cluster=gke \
  --set breakglassSourceCidr=203.0.113.10/32 \
  --set 'cloudflareIpv4Cidrs={173.245.48.0/20}' \
  --set 'cloudflareIpv6Cidrs={2400:cb00::/32}' \
  > /tmp/root-render.yaml

# Preview block: expect both gke-direct + trakrf-id-direct routes
grep -A2 'name: trakrf-backend-preview' /tmp/root-render.yaml | head
grep -A20 'host: app.preview.gke.trakrf.id' /tmp/root-render.yaml | head
grep -A2 'host: app.preview.trakrf.id' /tmp/root-render.yaml | head

# Prod block: expect ONLY gke-direct (no trakrf-id-direct)
grep -A20 'host: app.prod.gke.trakrf.id' /tmp/root-render.yaml | head
grep 'host: app.prod.trakrf.id' /tmp/root-render.yaml
# expect: empty (no match)
```

Expected: preview retains both routes; prod has only `app.prod.gke.trakrf.id`.

- [ ] **Step 3: Commit**

```bash
git add argocd/root/templates/trakrf-backend.yaml
git commit -m "feat(argocd/root): trakrf-backend ingress through env-parameterized helper"
```

---

## Task 5 — Justfile: `db-secrets` drops reflector

**Files:**
- Modify: `justfile`

Current state: `db-secrets` (at `justfile:135-147`) creates preview Secrets natively in `trakrf-preview` and prod Secrets in `trakrf-system` with reflector mirror to `trakrf-prod`. `_db-secret` (at `justfile:154-169`) takes a REFLECT target ns as 3rd arg. After this PR, prod Secrets are native in `trakrf-prod`; the REFLECT arg goes away.

- [ ] **Step 1: Replace the `db-secrets` recipe header comment block (lines 118-133)**

Find the comment block starting `# Per-env CNPG role credential Secrets.` through `# feedback_db_password_alphabet — base64 / + chars break URL DSNs).`. Replace with:

```just
# Per-env CNPG role credential Secrets.
#
# Each Cluster (preview, prod) holds the same role names (trakrf-app,
# trakrf-migrate) and references the same Secret names (trakrf-app-credentials,
# trakrf-migrate-credentials) — the K8s namespace is what disambiguates them.
#
# Both env Secrets live natively in their cluster's namespace
# (trakrf-preview / trakrf-prod). No reflector annotations — the prod Cluster
# is now co-located in trakrf-prod, so the cross-namespace mirror that the
# shared-cluster topology needed is gone.
#
# Passwords come from .env.local using openssl rand -hex (per
# feedback_db_password_alphabet — base64 / + chars break URL DSNs).
```

- [ ] **Step 2: Replace the `db-secrets` recipe body (lines 135-147)**

Find:

```just
# Apply CNPG role credential Secrets (preview native, prod reflector-mirrored)
db-secrets:
    @kubectl create namespace trakrf-system --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${TRAKRF_APP_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_APP_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @just _db-secret app     trakrf-preview ""             "${TRAKRF_APP_DB_PASSWORD_PREVIEW}"
    @just _db-secret app     trakrf-system  "trakrf-prod"  "${TRAKRF_APP_DB_PASSWORD_PROD}"
    @just _db-secret migrate trakrf-preview ""             "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW}"
    @just _db-secret migrate trakrf-system  "trakrf-prod"  "${TRAKRF_MIGRATE_DB_PASSWORD_PROD}"
    @echo "Secrets applied. Preview: native in trakrf-preview. Prod: reflector-mirrored into trakrf-prod."
```

Replace with:

```just
# Apply CNPG role credential Secrets (both envs native, no reflector)
db-secrets:
    @kubectl create namespace trakrf-preview --dry-run=client -o yaml | kubectl apply -f -
    @kubectl create namespace trakrf-prod --dry-run=client -o yaml | kubectl apply -f -
    @test -n "${TRAKRF_APP_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_APP_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_APP_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW not set in .env.local"; exit 1; }
    @test -n "${TRAKRF_MIGRATE_DB_PASSWORD_PROD:-}" || { echo "ERROR: TRAKRF_MIGRATE_DB_PASSWORD_PROD not set in .env.local"; exit 1; }
    @just _db-secret app     trakrf-preview "${TRAKRF_APP_DB_PASSWORD_PREVIEW}"
    @just _db-secret app     trakrf-prod    "${TRAKRF_APP_DB_PASSWORD_PROD}"
    @just _db-secret migrate trakrf-preview "${TRAKRF_MIGRATE_DB_PASSWORD_PREVIEW}"
    @just _db-secret migrate trakrf-prod    "${TRAKRF_MIGRATE_DB_PASSWORD_PROD}"
    @echo "Secrets applied. Both envs native in their namespaces (no reflector)."
```

- [ ] **Step 3: Replace the `_db-secret` helper (lines 149-169)**

Find:

```just
# Helper: create one CNPG role credential Secret.
#   ROLE   : "app" | "migrate"          → produces Secret `trakrf-<ROLE>-credentials`
#   NS     : namespace to create the Secret in
#   REFLECT: target namespace for reflector mirroring; empty disables annotations
#   PW     : password
_db-secret ROLE NS REFLECT PW:
    @kubectl create secret generic trakrf-{{ROLE}}-credentials -n {{NS}} \
      --from-literal=username=trakrf-{{ROLE}} \
      --from-literal=password="{{PW}}" \
      --dry-run=client -o yaml | kubectl apply -f -
    @if [ -n "{{REFLECT}}" ]; then \
       kubectl annotate --overwrite secret trakrf-{{ROLE}}-credentials -n {{NS}} \
         reflector.v1.k8s.emberstack.com/reflection-allowed=true \
         reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
         reflector.v1.k8s.emberstack.com/reflection-auto-namespaces={{REFLECT}}; \
     else \
       kubectl annotate --overwrite secret trakrf-{{ROLE}}-credentials -n {{NS}} \
         reflector.v1.k8s.emberstack.com/reflection-allowed- \
         reflector.v1.k8s.emberstack.com/reflection-auto-enabled- \
         reflector.v1.k8s.emberstack.com/reflection-auto-namespaces- 2>/dev/null || true; \
     fi
```

Replace with:

```just
# Helper: create one CNPG role credential Secret.
#   ROLE : "app" | "migrate"   → produces Secret `trakrf-<ROLE>-credentials`
#   NS   : namespace to create the Secret in
#   PW   : password
_db-secret ROLE NS PW:
    @kubectl create secret generic trakrf-{{ROLE}}-credentials -n {{NS}} \
      --from-literal=username=trakrf-{{ROLE}} \
      --from-literal=password="{{PW}}" \
      --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 4: Verify recipe syntax**

```bash
just --list 2>&1 | grep db-secrets
```

Expected: one line `db-secrets    Apply CNPG role credential Secrets (both envs native, no reflector)`.

```bash
just --evaluate _db-secret 2>&1 || true   # syntax check; expected to ask for args
```

- [ ] **Step 5: Commit**

```bash
git add justfile
git commit -m "refactor(just): db-secrets drops reflector; prod native in trakrf-prod"
```

---

## Task 6 — Pre-flight check: AppProject destinations

**Files:** read-only — verify `argocd/projects/trakrf.yaml` already permits the new Application's destination.

- [ ] **Step 1: Inspect**

```bash
grep -A5 'destinations:' argocd/projects/trakrf.yaml
grep 'trakrf-prod' argocd/projects/trakrf.yaml
```

Expected: a `destinations` entry for `namespace: 'trakrf-*'` or explicit `trakrf-prod`. The trakrf-backend-prod / trakrf-ingester-prod Applications already use trakrf-prod; the new trakrf-db-prod Application uses the same ns and chart `helm/trakrf-db`, so destinations should already cover it.

- [ ] **Step 2: If a permit is missing, add it**

Only if Step 1 reveals a gap, edit `argocd/projects/trakrf.yaml` to add the destination and/or `helm/trakrf-db` sourceRepo entry, then commit. Most likely this task is a no-op.

---

## Task 7 — Pre-merge ops: generate obfuscation_key + apply db-secrets

These steps happen on the operator's workstation against the live GKE cluster BEFORE the PR is opened. They do not touch tracked files.

- [ ] **Step 1: Generate `app.obfuscation_key` and store in 1Password**

```bash
openssl rand -hex 32
```

Copy the 64-hex output. In 1Password (Infrastructure vault), create a new Password item:
- Title: `trakrf-prod app.obfuscation_key`
- Password field: the 64-hex value
- Notes: "Feistel cipher key for trakrf-db-prod. Must re-apply via ALTER DATABASE trakrf SET app.obfuscation_key = ... on any Cluster rebuild or PITR restore. Generated 2026-05-27 for TRA-850."

Verify: open the item, copy the password, paste it back into a terminal — confirm round-trip is 64 hex chars.

- [ ] **Step 2: Apply the new db-secrets shape**

```bash
just gke-creds              # ensure kubectl points at GKE
just db-secrets
```

Expected last line: `Secrets applied. Both envs native in their namespaces (no reflector).`

- [ ] **Step 3: Verify Secret state**

```bash
# Native + no reflector annotations
for ns in trakrf-preview trakrf-prod; do
  echo "=== $ns ==="
  kubectl -n $ns get secret trakrf-app-credentials trakrf-migrate-credentials \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n  annotations: "}{.metadata.annotations}{"\n"}{end}'
done
```

Expected: each Secret prints; `annotations:` is empty or shows only `kubectl.kubernetes.io/last-applied-configuration` — no `reflector.v1.k8s.emberstack.com/*` keys.

- [ ] **Step 4: Snapshot TSC prod row counts (for the post-migration diff)**

```bash
psql "$TSC_PROD_DSN" -At -F $'\t' -c "
  SELECT schemaname || '.' || relname AS table, n_live_tup
  FROM pg_stat_user_tables
  WHERE schemaname IN ('public','trakrf')
  ORDER BY table
" > /tmp/tsc-prod-rowcounts-pre.tsv

wc -l /tmp/tsc-prod-rowcounts-pre.tsv
```

Expected: non-empty TSV with one line per table. Keep `/tmp/tsc-prod-rowcounts-pre.tsv` for the diff at Task 11.

---

## Task 8 — Open PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin miks2u/tra-850-cluster-per-env-cnpg-prod-onto-dedicated-cluster-retire
```

- [ ] **Step 2: Open PR via gh**

```bash
gh pr create --base main --title "feat: cluster-per-env CNPG prod-half (dry-run cutover)" --body "$(cat <<'EOF'
## Summary
- Stand up dedicated `trakrf-db-prod` CNPG Cluster in `trakrf-prod` namespace
- Repoint `envs.prod` workloads onto the new Cluster
- Wire `app.prod.gke.trakrf.id` IngressRoute for dry-run smoke testing (LE cert + breakglass IPAllowList)
- Drop reflector pattern from `db-secrets`: prod credentials now native in `trakrf-prod`
- Tofu WI bindings for the new prod Cluster + pg_dump KSAs; GCS lifecycle prefix broadened

`app.trakrf.id` DNS is intentionally untouched — Saturday's TRA-375 cutover flips it.

## Test plan
- [ ] `tofu -chdir=terraform/gcp plan` shows 2 add + 1 in-place change
- [ ] `helm template root argocd/root` renders both envs cleanly; prod has gke-direct route only
- [ ] Post-merge: `trakrf-db-prod` Application Synced+Healthy; `automated.prune: false`
- [ ] Post-merge: `trakrf-backend-prod` and `trakrf-ingester-prod` recover from CrashLoop
- [ ] Logical migration TSC prod → trakrf-db-prod completes with matching row counts
- [ ] `app.obfuscation_key` set; smoke tests pass via `app.prod.gke.trakrf.id`
- [ ] DR drill: PITR into side cluster, sentinel row + row counts + Feistel decode all consistent

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Capture the PR URL for the merge step.

- [ ] **Step 3: Merge once approved**

Per CLAUDE.md: `gh pr merge --merge` (no squash, no rebase). Operator-driven; do not auto-merge.

---

## Task 9 — Post-merge ops: tofu apply + root chart re-render

These run after the PR merges to main.

- [ ] **Step 1: Pull latest main locally**

```bash
git checkout main
git pull
```

- [ ] **Step 2: Apply tofu**

```bash
just gcp
```

Expected last line of plan: "Plan: 2 to add, 1 to change, 0 to destroy." Apply proceeds; verify success.

- [ ] **Step 3: Re-render root chart**

Per memory `feedback_root_chart_needs_manual_bump`: edits under `argocd/root/templates/*` and `values.yaml` do NOT auto-sync; the root Application is re-rendered by:

```bash
./scripts/apply-root-app.sh gke
```

Expected: script applies the rendered root Application; no error.

- [ ] **Step 4: Watch reconcile**

```bash
# In one terminal:
kubectl -n trakrf-prod get cluster,svc,pvc -w
# In another:
argocd app list | grep -E 'trakrf-(db|backend|ingester)-(prod|preview)'
```

Wait for:
- `trakrf-db-prod` cluster: `Ready=True` (typically 60-90s after Application syncs)
- `trakrf-backend-prod` pods: `Running` (recover from CrashLoop once DSN resolves)
- `trakrf-ingester-prod` pods: `Running`
- All four Applications: `Synced + Healthy`

- [ ] **Step 5: Verify Application invariants**

```bash
argocd app get trakrf-db-prod -o json \
  | jq '.spec.syncPolicy.automated.prune'
# expect: false

kubectl get pvc -n trakrf-prod -l cnpg.io/cluster=trakrf-db-prod \
  -o jsonpath='{.items[0].spec.storageClassName}'
# expect: premium-rwo-retain

kubectl -n trakrf-prod get pods -l app=trakrf-backend \
  -o jsonpath='{.items[*].status.phase}'
# expect: Running (no CrashLoopBackOff)
```

---

## Task 10 — Apply `app.obfuscation_key` + bounce backend

- [ ] **Step 1: Apply the GUC**

Retrieve the 64-hex value from 1Password (item: `trakrf-prod app.obfuscation_key`). Then:

```bash
KEY=<paste-64-hex-from-1Password>
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf \
       -c "ALTER DATABASE trakrf SET app.obfuscation_key = '${KEY}'"
unset KEY    # don't leave it in shell history
```

- [ ] **Step 2: Verify**

```bash
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -At -c "SHOW app.obfuscation_key" \
  | grep -qE '^[0-9a-f]{64}$' && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Bounce the backend so connections pick up the new GUC**

```bash
kubectl -n trakrf-prod rollout restart deploy/trakrf-backend
kubectl -n trakrf-prod rollout status deploy/trakrf-backend
```

Expected: rollout completes; new pods Running.

---

## Task 11 — Logical migration (TSC prod → trakrf-db-prod)

This re-runs `docs/db-migration.md` with prod substitutions. The runbook is the authoritative step-by-step; this task is a checklist that the runbook was followed.

- [ ] **Step 1: Read the runbook**

```bash
less docs/db-migration.md
```

Substitution table for prod execution:
| Placeholder in runbook | Prod value |
|---|---|
| `<env>` | `prod` |
| `<ns>` | `trakrf-prod` |
| `<cluster>` | `trakrf-db-prod` |
| `<tsc-source-dsn>` | TSC prod instance DSN from 1Password |

- [ ] **Step 2: Run schema bootstrap (migrate Job)**

The migrate Job is already wired in the trakrf-backend Application; trigger a manual run if it hasn't fired:

```bash
kubectl -n trakrf-prod create job --from=cronjob/trakrf-backend-migrate trakrf-backend-migrate-tra850-bootstrap 2>/dev/null \
  || kubectl -n trakrf-prod get jobs -l app=trakrf-backend
```

Wait for Job `Complete=True`. Expected: schema (public + trakrf schemas, all migrations) present in trakrf-db-prod.

- [ ] **Step 3: FDW pull (per the runbook)**

Follow the runbook's FDW section. For TimescaleDB hypertables, bracket the COPY with `timescaledb_pre_restore()` / `timescaledb_post_restore()` per `feedback_timescale_logical_restore_bracket`. Order tables by FK dependency.

Throttle: one table at a time (preserves TSC prod connection headroom).

- [ ] **Step 4: Row-count diff**

```bash
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -At -F $'\t' -c "
    SELECT schemaname || '.' || relname AS table, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname IN ('public','trakrf')
    ORDER BY table
  " > /tmp/cnpg-prod-rowcounts-post.tsv

diff /tmp/tsc-prod-rowcounts-pre.tsv /tmp/cnpg-prod-rowcounts-post.tsv
```

Expected: empty diff. Any new rows ingested via the GKE prod ingester after migration land in the post snapshot — re-run the source snapshot side if you've crossed a non-zero ingest window since Task 7 step 4.

- [ ] **Step 5: Tear down FDW state**

Per the runbook: drop the foreign server + user mapping. Verify:

```bash
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -c "SELECT srvname FROM pg_foreign_server"
# expect: zero rows
```

---

## Task 12 — Cleanup orphan reflector source Secrets

- [ ] **Step 1: Delete the now-orphan prod Secrets in trakrf-system**

```bash
kubectl -n trakrf-system delete secret \
  trakrf-app-credentials \
  trakrf-migrate-credentials \
  --ignore-not-found
```

- [ ] **Step 2: Verify trakrf-prod's Secrets are unaffected**

```bash
kubectl -n trakrf-prod get secret trakrf-app-credentials trakrf-migrate-credentials \
  -o jsonpath='{.items[*].metadata.name}'
```

Expected: `trakrf-app-credentials trakrf-migrate-credentials`.

- [ ] **Step 3: Verify reflector didn't auto-create them somewhere unexpected**

```bash
kubectl get secret -A | grep -E 'trakrf-(app|migrate)-credentials' | grep -v 'trakrf-(preview|prod):'
```

Expected: zero matches.

---

## Task 13 — Smoke tests via `app.prod.gke.trakrf.id`

- [ ] **Step 1: Confirm cert issued**

```bash
kubectl -n trakrf-prod get certificate app-prod-gke-trakrf-id-tls \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# expect: True
```

- [ ] **Step 2: Confirm DNS resolves**

The breakglass IPAllowList gates access to operator IP. Run from the operator workstation (which `breakglassSourceCidr` points at):

```bash
curl -sf https://app.prod.gke.trakrf.id/healthz
# expect: 200 with the healthz payload (no "403 Forbidden" from breakglass)
```

If `app.prod.gke.trakrf.id` has no DNS record yet (the GKE/CloudDNS auto-record may need a moment), use `--resolve`:

```bash
LB_IP=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sf --resolve app.prod.gke.trakrf.id:443:$LB_IP https://app.prod.gke.trakrf.id/healthz
```

- [ ] **Step 3: Login round-trip (validates obfuscation_key path)**

In a browser (or with a scripted login flow if the operator has one), sign in via `https://app.prod.gke.trakrf.id`. Expected: successful auth + dashboard renders. Failure mode would be "user lookup by Feistel-encoded ID fails" — that's the obfuscation_key drift indicator.

- [ ] **Step 4: One read + one write of a Feistel-encoded resource**

Through the UI or API, perform a CRUD on any resource that exposes a Feistel-encoded ID in its URL (e.g., a tag, location, or device). Expected: the encoded ID decodes consistently across read + write; no 500s.

- [ ] **Step 5: Ingester sanity**

```bash
kubectl -n trakrf-prod logs -l app=trakrf-ingester --tail=50 | grep -iE 'connect|subscr|msg'
```

Expected: connected to broker, subscribed to `trakrf.id/#`, ingest messages processing.

```bash
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -c "
    SELECT MAX(received_at) FROM trakrf.<recent-events-table>"
```

Expected: a timestamp within the last minute or two (live ingest from MQTT).

---

## Task 14 — DR drill: PITR into a side cluster

This task validates the AC "Per-Cluster PITR confirmed on the prod Cluster via the TRA-842 stanza; restore tested (with key re-applied post-restore)".

- [ ] **Step 1: Pre-drill snapshot + sentinel**

```bash
# Row counts (live)
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -At -F $'\t' -c "
    SELECT schemaname || '.' || relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname IN ('public','trakrf')
    ORDER BY 1
  " > /tmp/dr-drill-rowcounts-pre.tsv

# Sentinel row + WAL flush
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -v ON_ERROR_STOP=1 -c "
    CREATE TABLE IF NOT EXISTS public.dr_drill_sentinel (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      written_at timestamptz NOT NULL DEFAULT now()
    );
    INSERT INTO public.dr_drill_sentinel DEFAULT VALUES RETURNING id, written_at;
    SELECT pg_switch_wal();
  " | tee /tmp/dr-drill-sentinel.txt
```

Note the `written_at` timestamp — that's the PITR target time (formatted as ISO8601 UTC).

```bash
TARGET_TIME=$(awk '/^ *[0-9]/{print $3" "$4}' /tmp/dr-drill-sentinel.txt | head -1 \
              | sed 's/+.*//' | awk '{print $1"T"$2"Z"}')
echo "TARGET_TIME=$TARGET_TIME"
```

- [ ] **Step 2: Add temporary WI binding for the DR cluster KSA**

Append to `terraform/gcp/cnpg_backups.tf` (will be removed in Step 7):

```hcl
# TEMPORARY — TRA-850 DR drill (2026-05-27). Remove after drill teardown.
resource "google_service_account_iam_member" "cnpg_backups_wi_cluster_prod_dr" {
  service_account_id = google_service_account.cnpg_backups.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[trakrf-prod/trakrf-db-prod-dr]"
}
```

```bash
just gcp
```

Expected: "Plan: 1 to add". Apply.

- [ ] **Step 3: Take an off-schedule base backup**

```bash
BACKUP_NAME=trakrf-db-prod-drill-$(date -u +%Y%m%d%H%M%S)
kubectl -n trakrf-prod apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: trakrf-prod
spec:
  cluster:
    name: trakrf-db-prod
  method: barmanObjectStore
EOF

kubectl -n trakrf-prod wait --for=jsonpath='{.status.phase}'=completed \
  backup/${BACKUP_NAME} --timeout=10m
```

- [ ] **Step 4: Restore into a side Cluster**

```bash
BUCKET=$(tofu -chdir=terraform/gcp output -raw cnpg_backup_bucket)
GSA=$(tofu -chdir=terraform/gcp output -raw cnpg_backups_service_account_email)

kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: trakrf-db-prod-dr
  namespace: trakrf-prod
spec:
  instances: 1
  imageName: ghcr.io/clevyr/cloudnativepg-timescale:17.2-ts2.18
  storage:
    size: 10Gi
    storageClass: premium-rwo-retain
  affinity:
    tolerations:
      - key: kubernetes.io/arch
        operator: Equal
        value: arm64
        effect: NoSchedule
  serviceAccountTemplate:
    metadata:
      annotations:
        iam.gke.io/gcp-service-account: ${GSA}
  bootstrap:
    recovery:
      source: trakrf-db-prod-source
      recoveryTarget:
        targetTime: "${TARGET_TIME}"
  externalClusters:
    - name: trakrf-db-prod-source
      barmanObjectStore:
        destinationPath: gs://${BUCKET}
        serverName: trakrf-db-prod
        googleCredentials:
          gkeEnvironment: true
        wal:
          compression: gzip
EOF

kubectl -n trakrf-prod wait --for=condition=Ready cluster/trakrf-db-prod-dr --timeout=10m
```

- [ ] **Step 5: Verify the GUC + sentinel + counts**

```bash
DR_POD=$(kubectl -n trakrf-prod get pod -l cnpg.io/cluster=trakrf-db-prod-dr,role=primary \
         -o jsonpath='{.items[0].metadata.name}')

# GUC carried through (ALTER DATABASE persists in pg_catalog, present in basebackup)
kubectl -n trakrf-prod exec "$DR_POD" -- \
  psql -U postgres -d trakrf -At -c "SHOW app.obfuscation_key" \
  | grep -qE '^[0-9a-f]{64}$' && echo "GUC OK"

# Sentinel row present
kubectl -n trakrf-prod exec "$DR_POD" -- \
  psql -U postgres -d trakrf -c "SELECT * FROM public.dr_drill_sentinel"

# Row counts match live
kubectl -n trakrf-prod exec "$DR_POD" -- \
  psql -U postgres -d trakrf -At -F $'\t' -c "
    SELECT schemaname || '.' || relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname IN ('public','trakrf')
    ORDER BY 1
  " > /tmp/dr-drill-rowcounts-dr.tsv

diff /tmp/dr-drill-rowcounts-pre.tsv /tmp/dr-drill-rowcounts-dr.tsv
# expect: empty diff (ingester writes after TARGET_TIME won't be replayed)
```

If the GUC test fails (empty), re-apply per Task 10 against the DR pod and document that as a finding.

- [ ] **Step 6: Feistel decode consistency check**

Pick one Feistel-encoded ID from a smoke-test resource created in Task 13. Verify both clusters decode it identically:

```bash
ENCODED_ID=<value-from-smoke-test>
LIVE_POD=trakrf-db-prod-1

for pod in "$LIVE_POD" "$DR_POD"; do
  echo "=== $pod ==="
  kubectl -n trakrf-prod exec "$pod" -- \
    psql -U postgres -d trakrf -At -c "SELECT trakrf.decode_id(${ENCODED_ID}::bigint)"
done
```

Expected: identical output from both pods. Confirms `app.obfuscation_key` is consistent across live + DR.

- [ ] **Step 7: Teardown**

```bash
# Delete the DR Cluster
kubectl -n trakrf-prod delete cluster trakrf-db-prod-dr

# PVCs are Retain — manually free storage
kubectl -n trakrf-prod delete pvc -l cnpg.io/cluster=trakrf-db-prod-dr
kubectl get pv | awk '/trakrf-db-prod-dr/ {print $1}' | xargs -r kubectl delete pv

# Delete the sentinel table
kubectl -n trakrf-prod exec trakrf-db-prod-1 -- \
  psql -U postgres -d trakrf -c "DROP TABLE public.dr_drill_sentinel"
```

Remove the temporary tofu resource added in Step 2:

```bash
# Edit terraform/gcp/cnpg_backups.tf and DELETE the cnpg_backups_wi_cluster_prod_dr block
# (do this in the worktree, not on a branch — it's a one-off, not for the PR)
```

Wait — the PR has already merged. Add this to main via a small follow-up commit on a new branch:

```bash
git checkout -b chore/tra-850-dr-drill-cleanup
# edit terraform/gcp/cnpg_backups.tf, remove the resource
git add terraform/gcp/cnpg_backups.tf
git commit -m "chore(gcp): remove temp DR-drill WI binding"
git push -u origin chore/tra-850-dr-drill-cleanup
gh pr create --base main --title "chore: remove DR-drill WI binding" --body "Temporary binding added during TRA-850 DR drill. Cluster torn down; revert."
```

Merge that PR; then `just gcp` (locally) to apply the removal — `Plan: 0 to add, 1 to destroy`.

- [ ] **Step 8: Verify GCS untouched**

```bash
gcloud storage ls gs://${BUCKET}/trakrf-db-prod/ | head
```

Expected: original base/wals/dump paths intact; only the new `${BACKUP_NAME}` base added.

---

## Task 15 — Update `docs/db-migration.md` with a Restore drill section

This documents the choreography from Task 14 so it's re-runnable. Lands as part of the SAME PR (Task 8) so the runbook + impl ship atomically. Move this BEFORE Task 8 in execution order if implementing sequentially — listed here because it's most useful AFTER Task 14 validates the steps in practice.

- [ ] **Step 1: Append a "Restore drill" section to `docs/db-migration.md`**

Use the Task 14 step list as source material. Generalize over env (preview / prod). Cross-reference the spec section "DR drill choreography".

The section should cover:
- Goal + when to run (pre-major-maintenance)
- Pre-drill snapshot + sentinel + WAL flush
- Adding the temporary DR-cluster WI binding (and removing it after)
- Side-cluster restore manifest template
- Verification (GUC, sentinel, row counts, Feistel decode)
- Teardown (cluster, PVC/PV, sentinel table, tofu revert)

- [ ] **Step 2: Commit (on the same TRA-850 branch BEFORE the PR is opened, or as the chore/cleanup PR above)**

If still pre-PR-open:
```bash
git add docs/db-migration.md
git commit -m "docs(db-migration): add Restore drill section"
```

---

## Self-Review Notes

- **Spec coverage:**
  - Dedicated trakrf-db-prod Cluster → Tasks 1, 2, 9
  - app.obfuscation_key gen + apply → Tasks 7, 10; documented in runbook (Task 15)
  - Data cutover via TRA-810 logical path → Task 11
  - Per-Cluster PITR confirmed → Task 14
  - Shared Cluster decommissioned → already done by TRA-849; orphan Secret cleanup at Task 12
  - End-to-end DR drill → Task 14
  - Smoke testing via app.prod.gke.trakrf.id → Tasks 3, 4, 13
- **Placeholders:** No "TBD"/"TODO". `<value-from-smoke-test>`, `<paste-64-hex-from-1Password>` are runtime substitutions, intentional.
- **Type/name consistency:**
  - `trakrf-db-prod` used consistently for Cluster name.
  - `trakrf-prod` used consistently for namespace.
  - `app.prod.gke.trakrf.id` used consistently for smoke hostname.
  - `app-prod-gke-trakrf-id-tls` used consistently for cert Secret name (matches helper template).
- **Ordering caveat:** Task 15 docs commit ideally lands BEFORE Task 8 (PR open). If subagent execution treats tasks strictly serially, swap their order at run time — noted in Task 15 prose.
