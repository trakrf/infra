# Helm Charts

Application Helm charts for TrakRF services, deployed to the `trakrf` namespace
alongside the CNPG PostgreSQL cluster.

- `trakrf-backend/` — Go backend API (port 8080, `/healthz` + `/readyz`)
- `trakrf-ingester/` — Redpanda Connect MQTT → PostgreSQL ingester

## Database connection

Both charts consume the CNPG managed role secret `trakrf-app-credentials`
(created by `argocd/clusters/trakrf/cluster.yaml`) and assemble `PG_URL` at
pod-start via Kubernetes `$(VAR)` env interpolation. Role `trakrf-app` has
DML-only grants; DDL is handled separately by the `trakrf-migrate` role.

## Secret management

M1 uses plain `Secret` manifests generated from chart values. Sensitive
defaults live in `values.secret.yaml` (gitignored) and are passed with
`-f values.secret.yaml`:

```sh
cp helm/trakrf-backend/values.secret.yaml.example values.secret.yaml
# edit values.secret.yaml
helm upgrade --install trakrf-backend helm/trakrf-backend \
  -n trakrf -f values.secret.yaml
```

Infisical / HashiCorp Vault integration is planned for a later milestone.

## Local lint

```sh
helm lint helm/trakrf-backend
helm lint helm/trakrf-ingester
helm template helm/trakrf-backend   # render to stdout for review
```

## Monitoring

See `helm/monitoring/README.md` for the kube-prometheus-stack bootstrap.
