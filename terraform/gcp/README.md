# GCP Infrastructure

`terraform/gcp/` — GKE and supporting GCP resources for TrakRF.

**Status:** Phase 2 (cluster + Cloud DNS + CF delegation) — TRA-460.
ArgoCD bootstrap + portable layer + GHCR image pull land in phase 3 (TRA-461).

## Local workflow

```bash
gcloud auth application-default login    # one-time
just gcp                                 # plans and applies
```

Requires `TF_VAR_project_id=trakrf-494211` in `.env.local` (loaded via direnv).
