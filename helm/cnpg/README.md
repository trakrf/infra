# helm/cnpg/ — CNPG operator values

Values overlays only (no `Chart.yaml`, no `templates/`) for the upstream
`cnpg/cloudnative-pg` chart. Applied via:

```
just cnpg-bootstrap <cluster>
```

CNPG operator stays out of ArgoCD by design — its pre-install hooks
depend on CRDs the same chart installs, which creates a chicken-and-egg
problem ArgoCD doesn't gracefully handle. See
`docs/superpowers/specs/2026-04-12-trakrf-db-design.md` for the full
rationale.

The CNPG `Cluster` CR itself (the actual DB) is managed by ArgoCD via
the `helm/trakrf-db/` chart — only the operator lives outside.
