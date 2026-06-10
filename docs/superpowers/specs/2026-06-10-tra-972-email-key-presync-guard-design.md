# TRA-972 — RESEND_API_KEY PreSync guard (infra hardening)

**Date:** 2026-06-10
**Ticket:** TRA-972 — RESEND_API_KEY empty on preview + prod, all transactional email broken (GKE cutover gate)
**Related:** infra#154 (chart plumbing: omit-when-empty + `ignoreDifferences`), TRA-860 (JWT_SECRET fail-fast pattern), TRA-375 (ESO+GSM future)

## Problem

Transactional email (org invites, password resets) silently failed on preview + prod GKE because `RESEND_API_KEY` was empty in the `trakrf-backend` Secret. The backend logs the Resend "API key is invalid" error but returns `201`/`200` anyway (send is best-effort, non-fatal), so the UI shows success while nothing is delivered. An empty key is **invisible** — nothing fails loudly until a user reports a missing email.

infra#154 stops ArgoCD from clobbering the key (omit-when-empty + per-env `ignoreDifferences`), and the real key is injected out-of-band. But nothing **detects** the regression class: a future env that forgets the injection, a deleted key, or a botched cutover would silently ship broken email again.

## Goal

Add an infra-layer guard that turns "empty `RESEND_API_KEY` in a deployed env" from a silent runtime warning into a **loud sync failure**, surfaced in the ArgoCD UI before the broken state goes live. This is the cutover gate named in the ticket title.

## Design

A helm-templated `Job` in the `trakrf-backend` chart, run as a **PreSync hook**, that fails the sync when `RESEND_API_KEY` is empty or missing.

### Component: `templates/email-guard-job.yaml`

- **Trigger:** `helm.sh/hook: pre-install,pre-upgrade` (ArgoCD maps both to **PreSync**, consistent with the existing `migrate-job.yaml`). `hook-weight: "-10"` so it runs *before* the migrate job (`-5`) — a missing key fails the sync fast, before migrations or pod rollout. `hook-delete-policy: before-hook-creation,hook-succeeded`.
- **Check:** the container receives `RESEND_API_KEY` from the `trakrf-backend` Secret via `secretKeyRef` with `optional: true`, then:
  ```sh
  if [ -z "$RESEND_API_KEY" ]; then
    echo "FATAL: RESEND_API_KEY is empty or missing in this deployed env."
    echo "Transactional email (invites, password resets) will silently fail."
    echo "Inject the key out-of-band (see TRA-972 / TRA-375) before syncing."
    exit 1
  fi
  echo "RESEND_API_KEY present (len ${#RESEND_API_KEY})."
  ```
  `optional: true` is load-bearing: with infra#154 the key is *omitted* from the Secret when empty, so a hard `secretKeyRef` would error at pod-create with an opaque `CreateContainerConfigError`. `optional: true` yields an empty env var instead, which the check catches with a clear message. It also catches a present-but-empty-string key.
- **Validity vs presence:** the guard checks **presence only**, not whether Resend accepts the key. A send-scoped `re_...` key cannot be read-only validated (Resend's `/domains` returns `401 restricted_api_key`); the only validity check is an actual send, which a sync hook must not do. Presence is the high-value, zero-side-effect check.
- **Image:** `busybox` (pinned, multi-arch — **arm64 matters**, GKE nodes are ARM T2A/Axion; the backend's own Go image is shell-less so it can't run the check). Overridable via `emailGuard.image`.
- **Scheduling:** reuses the chart's `nodeSelector`/`affinity`/`tolerations` passthrough (same as `migrate-job`) so it tolerates the GKE `arch=arm64:NoSchedule` taint. Hardened pod (`runAsNonRoot`, drop ALL caps, `readOnlyRootFilesystem`), tiny resources.

### Gating: `emailGuard.enabled`

- New chart value `emailGuard.enabled`, **default `false`** — so local dev, AKS, and EKS overlays render nothing (the guard is GKE-prod-fleet hardening, and CI's eks/aks template runs stay clean).
- Flipped `true` for **preview + prod** via `argocd/root/templates/trakrf-backend.yaml` inlineValues (same mechanism as `mqttEnabled`).

## Rollout ordering (critical)

preview + prod currently hold an **empty** key, so an active guard would block their sync. Required order:

1. Merge infra#154 (omit-when-empty + `ignoreDifferences`).
2. Inject the real `re_...` key out-of-band into preview (then prod, on Mike's timing).
3. Merge **this** guard PR.

The guard PR is held-for-review, so it naturally lands last — no deadlock. On a brand-new env's very first sync the Secret/key must be pre-provisioned (consistent with the out-of-band injection model); documented, not solved here.

## Out of scope

- Backend-side loud failure (boot guard / metric in `resend.go`) — platform repo, handed to platform if wanted.
- ESO + GCP Secret Manager (TRA-375).
- Key *validity* checking (would require a live send).

## Verification

- `helm template trakrf-backend` with `emailGuard.enabled=false` → no guard Job (default / eks / aks).
- `helm template trakrf-backend --set emailGuard.enabled=true` → guard Job present, hook annotations correct, `RESEND_API_KEY` `secretKeyRef` with `optional: true`.
- `helm template argocd/root` → preview + prod backend apps carry `emailGuard.enabled: true`; others absent/false.
- `helm lint` clean; CI eks/aks matrix green.
