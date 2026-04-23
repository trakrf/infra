# GCP Infrastructure

`terraform/gcp/` — GKE and supporting GCP resources for TrakRF.

**Status:** Phase 1 (scaffolding + API enablement) — TRA-459.
Cluster, Cloud DNS zone, and Artifact Registry land in phase 2 (TRA-460).

**Design spec:** `docs/superpowers/specs/2026-04-23-tra-459-gke-phase-1-design.md`

## Local workflow

```bash
gcloud auth application-default login    # one-time
just gcp                                 # plans and applies
```

Requires `TF_VAR_project_id=trakrf-494211` in `.env.local` (loaded via direnv).
