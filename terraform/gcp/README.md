# GCP Infrastructure

`terraform/gcp/` — GKE and supporting GCP resources for TrakRF.

**Status:** Phase 2 (cluster + Cloud DNS + CF delegation) — TRA-460.
ArgoCD bootstrap + portable layer + GHCR image pull land in phase 3 (TRA-461).

**Design spec:**
- Phase 1: `docs/superpowers/specs/2026-04-23-tra-459-gke-phase-1-design.md`
- Phase 2: `docs/superpowers/plans/2026-04-23-tra-460-gke-phase-2.md` (Linear TRA-460)

## Local workflow

```bash
gcloud auth application-default login    # one-time
just gcp                                 # plans and applies
```

Requires `TF_VAR_project_id=trakrf-494211` in `.env.local` (loaded via direnv).
