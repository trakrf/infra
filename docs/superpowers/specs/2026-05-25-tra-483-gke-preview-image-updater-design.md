# TRA-483 — Auto-track GKE preview image to the platform preview-branch composition

**Status:** Design
**Date:** 2026-05-25
**Related:** TRA-825 (preview cutover to GKE — consumer of this), TRA-837 (platform-side preview-branch image + floating tag — prereq, shipped 2026-05-25), TRA-458 (superseded; AKS version, consolidated here), TRA-481 (build metadata on `/health` + `/version.json` — makes the transition observable)

## Context

The GKE preview env's backend image was manually pinned in `helm/trakrf-backend/values-gke.yaml` and drifted from platform main — last bump was `sha-c18ee87`, then `sha-67f3dbc`, but both required a hand-merged PR. The cutover from Railway preview (TRA-825) leaves GKE preview as the only preview-tier env once Railway preview retires, and a manual-bump preview can't host PR-stacked CI work.

Platform side (TRA-837, shipped 2026-05-25 in two PRs):

- `trakrf/platform#408` added `preview` to `docker-build.yml`'s push branches so every `sync-preview.yml` rewrite of the `preview` branch publishes `ghcr.io/trakrf/backend:sha-<short>`.
- `trakrf/platform#409` added a floating `:preview` tag (priority 50, below `sha-<short>`'s priority 100) so ArgoCD Image Updater can watch the digest of `:preview` without racing main-branch builds. Primary version output stays `sha-<short>` so `/version.json` continues to report a real commit, not a floating label.

The contract the platform side documented in #409:

> Hand off to TRA-483 (infra): point ArgoCD Image Updater at `ghcr.io/trakrf/backend:preview` with `update-strategy: digest`.

This ticket is the infra side of that contract.

## Decision

Deploy [ArgoCD Image Updater](https://argocd-image-updater.readthedocs.io/) as an ArgoCD-managed Application on GKE only, configured to watch `ghcr.io/trakrf/backend:preview` with the `digest` update strategy. Annotate the `trakrf-backend-preview` Application (and only that Application) so Image Updater patches its `spec.source.helm.parameters` with the resolved digest on every change.

Three sub-decisions worth calling out:

1. **`argocd` write-back, not `git` write-back.** Default write-back patches the live Application object — no GitHub credentials to manage, no commit churn on `main` every PR open/sync/close. The `values-gke.yaml` `image.tag` field stays as a bootstrap value; the live tag lives on the Application as a helm parameter override. Audit trail is in the ArgoCD app history. Git write-back to a side branch + auto-merge PR is the cleaner long-term shape if we ever want git as the source of truth for the live tag, but the credential plumbing isn't warranted today.

2. **Digest strategy on the floating `:preview` tag.** PR #409 documents why `newest-build` filtered on `^sha-` won't work: `main` and `preview` branches both publish `sha-<short>` tags against the same image, and a `main` build landing after a `preview` rewrite would (wrongly) win. The floating `:preview` tag breaks the tie — its digest changes only when the preview-branch builds — so digest-watch is the unambiguous primitive.

3. **Chart change to accept either tag-shape OR digest in `image.tag`.** Image Updater writes the resolved digest into the helm parameter named `image.tag` as `sha256:<hex>`. The Docker reference for a digest uses `@` between repo and digest, not `:` — so the chart's deployment template needs to recognise the `sha256:` prefix and switch separators. A small `trakrf-backend.image` helper centralises the logic and keeps both `deployment.yaml` and `migrate-job.yaml` consistent.

GKE-only gating is critical for two reasons. First, the preview composition only lands on GKE today (AKS stopped, EKS deprovisioned). Second, when prod shares the GKE cluster post-cutover, the `trakrf-backend-prod` Application MUST stay unannotated so Image Updater never touches it — prod is a deliberate manual tag promotion. Gating annotations on `env=preview` (not on cluster) is the structural guarantee.

## Out of scope

- Prod auto-bump — prod stays manual tag promotion. The Application emitted at `env=prod` carries no Image Updater annotations regardless of cluster.
- Building the preview-branch image — that was TRA-837, already shipped.
- Cross-repo bot-PR write-back — explicitly chose ArgoCD write-back instead.
- Git credential management — would only matter if write-back changed to `git` (not planned).
- Automated rollback on failed deploys — out of scope per ticket.
- Ingester auto-track — `trakrf-ingester` runs the upstream Redpanda Connect image, not a platform image; no auto-track surface today. If we ever publish a custom ingester image to GHCR with a `:preview` floating tag, the same pattern applies.

## Architecture

```
trakrf/platform (sync-preview.yml force-rewrites preview branch on PR events)
                              │
                              ▼
trakrf/platform (docker-build.yml on push to preview)
  builds + pushes:
    ghcr.io/trakrf/backend:sha-<short>   (priority 100, primary version)
    ghcr.io/trakrf/backend:preview       (priority 50, floating)
                              │
                              ▼
ArgoCD Image Updater (GKE only, argocd ns)
  argo/argocd-image-updater chart 1.2.2
  reads :preview manifest digest from ghcr.io anonymously (public package)
  ─ if digest unchanged ──→ no-op
  ─ if digest changed ───→ patch Application
                              │
                              ▼
Application trakrf-backend-preview (argocd ns) — annotations:
  image-list: backend=ghcr.io/trakrf/backend:preview
  backend.update-strategy: digest
  backend.helm.image-name: image.repository
  backend.helm.image-tag: image.tag
  write-back-method: argocd
                              │
  Image Updater writes:       │
    spec.source.helm.parameters:
      - name: image.tag
        value: sha256:<digest>
      - name: image.repository
        value: ghcr.io/trakrf/backend
                              │
                              ▼
ArgoCD reconciles helm release → kubectl apply on Deployment
  helm chart trakrf-backend renders deployment.yaml:
    image: ghcr.io/trakrf/backend@sha256:<digest>
                              │
                              ▼
Kubernetes rolls Deployment (kubelet pulls new digest, restarts pod)

Application trakrf-backend-prod (argocd ns) — NO Image Updater annotations.
  Stays on whatever values-gke.yaml.image.tag says. Manual tag promotion.
```

## Components

### Chart helper

`helm/trakrf-backend/templates/_helpers.tpl` gains a `trakrf-backend.image` template:

- Reads `image.tag` (required).
- If tag starts with `sha256:`, render `<repo>@<tag>` (digest reference).
- Else render `<repo>:<tag>` (tag reference, today's shape).

`deployment.yaml` and `migrate-job.yaml` both call `include "trakrf-backend.image" .`.

### Image Updater Application

`argocd/root/templates/argocd-image-updater.yaml`:

- Gated on `eq .Values.cluster "gke"`.
- `argo/argocd-image-updater` chart pinned to `1.2.2` (chart version, not appVersion — per [memory feedback](../../README.md)).
- In-cluster ArgoCD target (`argocd-server.argocd.svc.cluster.local:443`) — no token needed; the chart's default Role + RoleBinding in the `argocd` ns lets Image Updater patch Applications via the K8s API.
- One registry entry for `ghcr.io` (anonymous; `trakrf/backend` is a public package).
- ARM toleration on the controller pod (single-pod controller, no sub-component split).
- Sync wave `-1` so it's up before workload applications at wave 1.

### Annotations on the preview Application

`argocd/root/templates/_helpers.tpl` gains a `trakrf-backend.previewImageUpdaterAnnotations` template emitting the five annotation lines.

`argocd/root/templates/trakrf-backend.yaml` is modified so the per-env loop:

- Always computes `inlineValues`.
- Computes `extraAnnotations` only when `env == "preview" AND cluster == "gke"`.
- Passes both to the `trakrf.application` helper, which is extended with an `extraAnnotations` parameter that injects pre-rendered YAML into `metadata.annotations`.

This shape lets the helper be reused later for other Image-Updater-tracked Applications (e.g. a future custom ingester image) without further structural changes.

### Project + destination wiring

Already in place — `argocd/projects/trakrf.yaml` lists `https://argoproj.github.io/argo-helm` under `sourceRepos` and `argocd` under `destinations`. No project edit needed.

## Verification (post-merge, on GKE)

Manual steps (apply-root-app.sh is not auto-run):

1. `scripts/apply-root-app.sh gke` to re-render the root chart with the new templates.
2. `kubectl -n argocd get applications` — `argocd-image-updater` Healthy, Synced.
3. `kubectl -n argocd describe app trakrf-backend-preview` — annotations present.
4. `kubectl -n argocd describe app trakrf-backend-prod` — no Image Updater annotations.
5. Open or sync a non-draft PR on `trakrf/platform`. Watch:
   - `sync-preview.yml` rewrites the `preview` branch.
   - `docker-build.yml` publishes new `:sha-<short>` + `:preview` tags.
   - Image Updater logs show a new digest detected for `ghcr.io/trakrf/backend:preview`.
   - `trakrf-backend-preview` Application picks up a new `image.tag` helm parameter (digest form).
   - ArgoCD rolls the Deployment.
   - `/health` and `/version.json` on the preview env show the new commit.
6. Confirm prod stays put: `kubectl -n trakrf-prod get deployment trakrf-backend -o jsonpath='{.spec.template.spec.containers[0].image}'` matches whatever the manual `values-gke.yaml` pin says.

## Risks + mitigations

- **Image Updater patches prod by accident.** Mitigated structurally — the annotations only emit when `env=preview AND cluster=gke`. Image Updater is opt-in per Application via annotations; if an Application carries none, it's invisible to the controller.
- **The `:preview` tag goes private.** Public anonymous reads work today. If `trakrf/backend` flips visibility, the Image Updater Application's `registries` block needs a `credentials:` ref pointing at a GHCR PAT secret. Documented in the chart helper comment.
- **`helm.parameters` override drifts from `values-gke.yaml`.** Acceptable — `values-gke.yaml.image.tag` is the bootstrap value; runtime is the parameter override. If we want to manually pin preview to a specific tag later, we can remove the Image Updater annotation, delete the parameter override, and bump `values-gke.yaml`.
- **Preview env redeploys frequently.** Intentional — every PR open/update/close on platform rewrites the preview branch, triggers a build, and rolls preview. Documented in the parent ticket.
