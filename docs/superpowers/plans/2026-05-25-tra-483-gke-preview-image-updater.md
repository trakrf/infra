# TRA-483 — Auto-track GKE preview image to the platform preview-branch composition — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire ArgoCD Image Updater on the GKE cluster so the `trakrf-backend-preview` Application tracks `ghcr.io/trakrf/backend:preview` (the floating tag shipped by `trakrf/platform#409`) via digest strategy. Prod stays a manual tag promotion.

**Architecture:** Additive — adds one ArgoCD Application for the upstream `argocd-image-updater` chart, a tiny chart helper to support digest references in `helm/trakrf-backend`, and a five-line annotation block on the preview Application (gated to `env=preview AND cluster=gke`). No Terraform changes. No CI changes. No new secrets — the package is public and Image Updater runs in-cluster against the ArgoCD API.

**Tech Stack:** Helm 3, ArgoCD Application templates, `argo/argocd-image-updater` chart 1.2.2 (app v1.2.1).

**Reference spec:** `docs/superpowers/specs/2026-05-25-tra-483-gke-preview-image-updater-design.md`

---

## File Structure

**Modified — `helm/trakrf-backend/`:**
- `templates/_helpers.tpl` — add `trakrf-backend.image` template (digest-aware separator).
- `templates/deployment.yaml` — swap inline `repository:tag` for `include "trakrf-backend.image"`.
- `templates/migrate-job.yaml` — same swap as deployment.

**New — `argocd/root/templates/`:**
- `argocd-image-updater.yaml` — upstream chart Application, GKE-only.

**Modified — `argocd/root/templates/`:**
- `_helpers.tpl` — extend `trakrf.application` with `extraAnnotations`; add `trakrf-backend.previewImageUpdaterAnnotations`.
- `trakrf-backend.yaml` — compute `extraAnnotations` for the preview env on GKE, pass to helper.

**New — `docs/superpowers/`:**
- `specs/2026-05-25-tra-483-gke-preview-image-updater-design.md` — design doc (this PR).
- `plans/2026-05-25-tra-483-gke-preview-image-updater.md` — this file.

**Untouched:**
- `argocd/projects/trakrf.yaml` — `argo-helm` repo and `argocd` namespace already permitted.
- `argocd/bootstrap/values-gke.yaml` — no bootstrap-time changes needed.
- `scripts/apply-root-app.sh` — no new tofu outputs to inject; Image Updater needs no Tofu wiring.
- `terraform/gcp/*` — no IaC changes.

---

## Branch setup

- [ ] **Step 1: Create the feature branch**

```bash
git checkout main
git pull
git checkout -b miks2u/tra-483-gke-preview-image-updater
```

Expected: branch created, clean working tree.

---

## Task 1: Chart helper — digest-aware image reference

**Files:**
- Modify: `helm/trakrf-backend/templates/_helpers.tpl` (append after `trakrf-backend.selectorLabels`)
- Modify: `helm/trakrf-backend/templates/deployment.yaml`
- Modify: `helm/trakrf-backend/templates/migrate-job.yaml`

- [ ] **Step 1: Add `trakrf-backend.image` helper**

Append to `_helpers.tpl`:

```
{{- define "trakrf-backend.image" -}}
{{- $tag := required "image.tag must be set (usually in values-<cluster>.yaml)" .Values.image.tag -}}
{{- $sep := ternary "@" ":" (hasPrefix "sha256:" $tag) -}}
{{- printf "%s%s%s" .Values.image.repository $sep $tag -}}
{{- end -}}
```

- [ ] **Step 2: Use the helper in deployment.yaml**

Replace the existing `image: "{{ .Values.image.repository }}:{{ required ... }}"` line with:

```
image: {{ include "trakrf-backend.image" . | quote }}
```

- [ ] **Step 3: Use the helper in migrate-job.yaml**

Same replacement as Step 2 in `migrate-job.yaml`.

- [ ] **Step 4: Render with tag form (regression check)**

```bash
helm template tb helm/trakrf-backend \
  -f helm/trakrf-backend/values.yaml \
  -f helm/trakrf-backend/values-gke.yaml \
  --set database.name=trakrf_preview \
  --set database.user=trakrf-app-preview \
  --set database.credentialsSecret=trakrf-app-preview-credentials \
  --set database.host=trakrf-db-rw.trakrf-system \
  --set migrate.database=trakrf_preview \
  --set migrate.user=trakrf-migrate-preview \
  --set migrate.credentialsSecret=trakrf-migrate-preview-credentials \
  --set migrate.host=trakrf-db-rw.trakrf-system \
  --set config.appEnv=preview \
  | grep -E '^\s+image:'
```

Expected: `image: "ghcr.io/trakrf/backend:sha-<short>"` for both Deployment and Job containers.

- [ ] **Step 5: Render with digest form**

Repeat the command with `--set image.tag=sha256:abc...` (any 64-hex string).

Expected: `image: "ghcr.io/trakrf/backend@sha256:abc..."` — `@` separator, not `:`.

---

## Task 2: Image Updater Application

**Files:**
- New: `argocd/root/templates/argocd-image-updater.yaml`

- [ ] **Step 1: Create the Application template**

Body wrapped in `{{- if eq .Values.cluster "gke" }} ... {{- end }}`. Source points at `https://argoproj.github.io/argo-helm`, chart `argocd-image-updater`, `targetRevision: "1.2.2"`. Inline helm values configure:

- `config.argocd.serverAddress: argocd-server.argocd.svc.cluster.local:443`, `grpcWeb: true`, `insecure: false`, `plaintext: false`.
- `config.registries[0]` — one entry for `ghcr.io` (anonymous, public package).
- `tolerations` — ARM toleration for GKE node taint.

Destination: `argocd` namespace, in-cluster server.

Sync wave: `-1` (so it's up before wave-1 application Applications get their first reconcile).

- [ ] **Step 2: Verify chart version exists**

```bash
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null
helm repo update
helm search repo argo/argocd-image-updater --versions | grep '^argo/argocd-image-updater\s\+1\.2\.2'
```

Expected: one matching line; do not pin a missing chart version.

- [ ] **Step 3: Render the GKE root chart and confirm the Application is present**

```bash
helm template trakrf-root argocd/root \
  --set cluster=gke \
  --set gcpProjectId=test --set certManagerGcpServiceAccountEmail=test \
  --set cloudDnsZoneNameApp=test --set cloudDnsZoneNameId=test \
  --set mqttPreviewIp=1.2.3.4 --set mqttProdIp=5.6.7.8 \
  --set traefikLbIp=9.9.9.9 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  | grep -A 2 'name: argocd-image-updater'
```

Expected: Application metadata block.

- [ ] **Step 4: Render the AKS root chart and confirm the Application is absent**

```bash
helm template trakrf-root argocd/root \
  --set cluster=aks \
  --set certManagerIdentityClientId=test --set tenantId=test \
  --set subscriptionId=test --set dnsZoneResourceGroup=test \
  --set traefikLbIp=9.9.9.9 --set mainResourceGroupName=test \
  | grep -c 'argocd-image-updater'
```

Expected: `0`.

---

## Task 3: Annotations on the preview Application

**Files:**
- Modify: `argocd/root/templates/_helpers.tpl`
- Modify: `argocd/root/templates/trakrf-backend.yaml`

- [ ] **Step 1: Extend `trakrf.application` helper**

Add an `extraAnnotations` parameter (optional, default empty). When non-empty, inject the pre-rendered YAML into `metadata.annotations` (indent 4).

- [ ] **Step 2: Add `trakrf-backend.previewImageUpdaterAnnotations` helper**

Emit the five annotations exactly:

```
argocd-image-updater.argoproj.io/image-list: backend=ghcr.io/trakrf/backend:preview
argocd-image-updater.argoproj.io/backend.update-strategy: digest
argocd-image-updater.argoproj.io/backend.helm.image-name: image.repository
argocd-image-updater.argoproj.io/backend.helm.image-tag: image.tag
argocd-image-updater.argoproj.io/write-back-method: argocd
```

- [ ] **Step 3: Compute extraAnnotations in the per-env loop**

In `trakrf-backend.yaml`, set `$extraAnnotations` only when `(eq $env "preview") AND (eq $.Values.cluster "gke")`. Pass to `trakrf.application` alongside `inlineValues`.

- [ ] **Step 4: Render the GKE root chart and confirm annotations on preview, NONE on prod**

```bash
helm template trakrf-root argocd/root --set cluster=gke ... \
  | awk '/name: trakrf-backend-preview/,/spec:/' | head -10

helm template trakrf-root argocd/root --set cluster=gke ... \
  | awk '/name: trakrf-backend-prod/,/spec:/' | head -10
```

Expected: preview block has the five Image Updater annotations; prod block has only `argocd.argoproj.io/sync-wave`.

- [ ] **Step 5: Render the AKS root chart and confirm no annotations on preview either**

```bash
helm template trakrf-root argocd/root --set cluster=aks ... \
  | grep 'argocd-image-updater.argoproj.io'
```

Expected: empty.

---

## Task 4: Documentation

**Files:**
- New: `docs/superpowers/specs/2026-05-25-tra-483-gke-preview-image-updater-design.md`
- New: `docs/superpowers/plans/2026-05-25-tra-483-gke-preview-image-updater.md`

- [ ] **Step 1: Write the design spec**

Cover: context (platform side TRA-837 shipped; the contract), the three sub-decisions (argocd write-back, digest strategy, chart digest-aware helper), out-of-scope, architecture diagram, components, verification steps, risks + mitigations.

- [ ] **Step 2: Write this plan**

(You are here.)

---

## Task 5: Open the PR

- [ ] **Step 1: Commit**

Group commits by component for review-friendliness:

- `feat(trakrf-backend): digest-aware image helper`
- `feat(argocd/root): argocd-image-updater Application (GKE-only)`
- `feat(argocd/root): wire Image Updater annotations on preview backend`
- `docs(superpowers): TRA-483 spec + plan`

(Or one squash-friendly commit if reviewer prefers — the repo merges with `--merge` not `--squash`, so multi-commit history is preserved.)

- [ ] **Step 2: Push branch + open PR**

Per CLAUDE.md: no Linear ticket refs in the PR body. Reference the platform PRs (`trakrf/platform#408`, `trakrf/platform#409`) as context.

- [ ] **Step 3: Post-merge — apply on GKE**

```bash
scripts/apply-root-app.sh gke
kubectl -n argocd get applications -w
```

The argocd-image-updater Application should sync, and the next sync-preview.yml run on platform should be reflected in the preview deployment within a few minutes.

---

## Out of scope (here, just to be explicit)

- Git write-back to a side branch or PR.
- Auto-track on prod.
- Custom ingester image — `trakrf-ingester` uses an upstream Redpanda image; no surface to track yet.
- Smoke checks for Image Updater in `scripts/smoke-gke.sh` — controller health is visible via the Application status; no extra scripted check needed for this ticket.
