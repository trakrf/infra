# trakrf-backend Helm chart

Deploys the TrakRF Go backend API and its schema migration Job against a CNPG Postgres cluster (`trakrf-db`) in the `trakrf` namespace.

## Migrations (TRA-361)

Schema migrations run as a Helm `pre-install,pre-upgrade` hook Job using `golang-migrate`. The Job runs as the `trakrf-migrate` role (credentials in secret `trakrf-migrate-credentials`). On success, the Job and its ConfigMap are deleted by `hook-delete-policy: hook-succeeded`.

### Fallback path (current default)

- SQL lives in `helm/trakrf-backend/migrations/*.up.sql`.
- Sync from platform repo: `just sync-migrations` (run in repo root).
- Uses image `migrate/migrate:v4.17.0`; files mounted via ConfigMap.

### Backend-image path (target after TRA-363)

Once the platform repo publishes the backend image to GHCR with migrations baked at `/app/db/migrations`, set:

```
helm upgrade ... --set migrate.image=ghcr.io/trakrf/backend:sha-<x>
```

The Job will use the backend image directly. The fallback ConfigMap is skipped and the chart's `migrations/` directory becomes unused (remove in a follow-up).

### Recovering from a dirty migration

If `golang-migrate` marks a version dirty, connect as `trakrf-migrate` and run:

```
migrate -path <dir> -database "$PG_URL" force <version>
```

then re-run `helm upgrade`.

### Known issues

- **TRA-365:** CNPG bootstrap `postInitApplicationSQL` grants are scoped to `public`, but migrations create objects in `trakrf` schema. After a fresh cluster bootstrap, `trakrf-app` will not have access until grants are applied. Stopgap SQL documented in the ticket.
- **TRA-364:** Single-AZ PV can orphan the DB pod after a cross-AZ spot reclaim.
