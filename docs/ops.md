# Ops runbook — preview + prod

Everything you need to inspect and operate the live TrakRF environments,
starting from a machine that is not authenticated to anything. No Claude
Code required, no prior `kubectl` context required — every recipe here is
shown alongside the raw command it runs, so you can hand-type your way
through an incident if `just` is unavailable.

Scope: the **GKE** cluster, which is the live one. The AKS and EKS stacks
are stopped/deprovisioned and out of scope for this document.

## 1. Authenticate

Zero to ready in one command:

```sh
just gcp-auth
```

It skips the login step if your credentials are already valid and ADC is
present; `FORCE=1 just gcp-auth` re-authenticates unconditionally. It
finishes by printing the kubectl context it selected.

If `just` is not available, the same three steps by hand:

```sh
gcloud auth login --no-launch-browser --update-adc
gcloud container clusters get-credentials gke-trakrf-demo-usc1 --zone us-central1-a --project trakrf-494211
kubectl config use-context gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1
```

`--no-launch-browser` is the browserless flow: gcloud prints a long URL and
waits. Open that URL on any device that has a browser, sign in, and paste
the verification code back at the prompt. Confirmed working 2026-07-27.

`--update-adc` refreshes Application Default Credentials in the same step,
so there is no need for a separate `gcloud auth application-default login`.
ADC is what `gcloud storage` and the backup/restore recipes use.

### Fallback: browser flow

If the code exchange is ever rejected, run the login from a session that
has a browser — the xfce desktop on this host, reached via Jump Desktop:

```sh
gcloud auth login --update-adc
```

That completes the handoff locally instead of via a pasted code. Because
Claude Code and the desktop session are the same box and the same user,
credentials written from either side are immediately live for both — log in
on the desktop, then come back to the terminal and continue.

### Cluster coordinates

| Field | Value |
| --- | --- |
| Project | `trakrf-494211` |
| Zone | `us-central1-a` |
| Cluster | `gke-trakrf-demo-usc1` |
| kubectl context | `gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1` |

These are hardcoded literals at the top of the root `justfile`, on purpose.
`gke-creds` used to derive them from terraform outputs, which puts the R2
state backend between an operator and production during an incident. Now
nothing on the incident path needs `tofu`, R2 credentials, or `.env.local`.

If the cluster is ever rebuilt, re-derive them and update those three
variables in the justfile. Note that `tofu output` reads the R2 state
backend, so it needs an initialized working directory and `.env.local`
credentials — a bare `tofu output` fails with *"Backend initialization
required"*:

```sh
just _backend-conf terraform/gcp                       # writes gitignored backend.conf
tofu -chdir=terraform/gcp init -backend-config=backend.conf
tofu -chdir=terraform/gcp output                       # project_id, zone, cluster_name
```

This is exactly the dependency the hardcoded literals exist to keep off
the incident path. Re-derive when the cluster changes, not when you are
trying to reach it.

Already authenticated but pointed at the wrong cluster? `just gke-creds`
re-points kubectl without touching credentials.

## 2. Preflight

```sh
just ops-check
```

Detect-only — it never authenticates and never mutates. Healthy output:

```
✅ gcloud authenticated as mike@devopstoai.com
✅ ADC present
✅ kubectl context gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1
✅ namespace trakrf-preview reachable
✅ namespace trakrf-prod reachable
```

Every ❌ line prints its own fix on the same line. The namespace checks
retry three times before failing, because of the transient connect error
documented under Troubleshooting. Exit code is 0 only if all five pass.

## 3. Triage: something is broken

Work down this list. Each step names the recipe and what a bad answer looks
like. `<env>` is `preview` or `prod`.

1. **`just pods <env>`** — is anything not `Running` or `Completed`?
   `CrashLoopBackOff`, `ImagePullBackOff`, `Pending`, or a restart count
   climbing between two runs is your lead.
2. **`just logs <env>`** — errors in the last 10 minutes? This follows, so
   Ctrl-C when you have seen enough. `just logs <env> '1h'` widens the
   window.
3. **`just db-status <env>`** — the CNPG cluster should read
   `Cluster in healthy state` with its instance pods `Running`. Anything
   else (`Failover in progress`, `Setting up primary`, 0 ready) means the
   database is the problem, not the app.
4. **`just argo-status`** — is the env's app `Synced` / `Healthy`? A
   `Degraded` or long-`OutOfSync` app means the desired state never landed.
   The `argocd` application itself showing `OutOfSync` is cosmetic and
   expected — it is self-managed after a helm bootstrap and never
   reconciles. `Healthy` is what matters there.
5. **`just mqtt-logs <env>`** — only if the symptom is ingestion-related
   (missing scans, silent readers).

## 4. Environments

| Env | Namespace | CNPG cluster | ArgoCD apps |
| --- | --- | --- | --- |
| `preview` | `trakrf-preview` | `trakrf-db-preview` | `trakrf-backend-preview`, `trakrf-db-preview`, `trakrf-mosquitto-preview` |
| `prod` | `trakrf-prod` | `trakrf-db-prod` | `trakrf-backend-prod`, `trakrf-db-prod`, `trakrf-mosquitto-prod` |

The `ENV` argument is required on every per-env recipe and is validated
against exactly these two names — a typo fails loudly instead of resolving
to a namespace that does not exist.

**Guard rule.** Read-only recipes (`pods`, `logs`, `rollout`, `db-status`,
`psql`, `mqtt-logs`, `mqtt-sub`, `argo-status`) run unguarded against both
environments. Mutating recipes (`backend-restart`, `set-log-level`,
`argo-sync` of a `*-prod` app) prompt before touching prod: they print what
they are about to do and require you to type `prod`. They **fail closed**
without a tty, so nothing scripted or piped can fall through the prompt.
Set `YES=1` to skip the prompt deliberately:

```sh
YES=1 just backend-restart prod
```

**Quote your arguments.** `TOPIC` and `SINCE` values are interpolated
straight into the recipe body. A topic containing a single quote, or a
duration pasted with unexpected characters, can behave surprisingly. Wrap
arguments in single quotes — the examples below do this consistently, and
you need it anyway for MQTT topics, where `#` and `$SYS` are shell
metacharacters.

## 5. Database

### Interactive psql

```sh
just psql preview
just psql prod
```

Raw equivalent:

```sh
kubectl -n trakrf-prod exec -it "$(kubectl -n trakrf-prod get pod -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')" -c postgres -- psql -U postgres -d trakrf
```

The primary is resolved by the `cnpg.io/instanceRole=primary` label rather
than a fixed pod name, so it follows a failover automatically — you always
land on whichever instance is currently primary. Auth is superuser via
in-pod peer auth over the unix socket, so no password is involved. The
database name is `trakrf` in both namespaces (the namespace is what
separates the environments, not the database name).

### Cluster health

```sh
just db-status prod
```

Raw equivalent:

```sh
kubectl -n trakrf-prod get cluster trakrf-db-prod
kubectl -n trakrf-prod get pods -l cnpg.io/cluster=trakrf-db-prod -o wide
```

Sample healthy output:

```
NAME             AGE   INSTANCES   READY   STATUS                     PRIMARY
trakrf-db-prod   61d   1           1       Cluster in healthy state   trakrf-db-prod-1
```

Backups, PITR, and restore procedures are in [backups.md](backups.md).

## 6. Backend

### Pods

```sh
just pods prod
```

Raw equivalent:

```sh
kubectl -n trakrf-prod get pods -o wide
```

This shows the whole namespace — backend, the CNPG instance, the mosquitto
broker, and completed `pg-dump` CronJob pods.

### Logs

```sh
just logs prod
just logs prod '1h'
```

Raw equivalent:

```sh
kubectl -n trakrf-prod logs -l app.kubernetes.io/name=trakrf-backend --since='10m' --tail=200 -f
```

`SINCE` defaults to `10m`. The `-f` means it follows — Ctrl-C to stop.

### Rollout status

```sh
just rollout prod
```

Raw equivalent:

```sh
kubectl -n trakrf-prod rollout status deploy/trakrf-backend --timeout=30s
kubectl -n trakrf-prod get deploy trakrf-backend -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:'.spec.template.spec.containers[0].image'
```

The `IMAGE` column is the fastest way to confirm which build is actually
serving traffic.

### Restart the backend

```sh
just backend-restart preview
YES=1 just backend-restart prod
```

Raw equivalent:

```sh
kubectl -n trakrf-prod rollout restart deploy/trakrf-backend
kubectl -n trakrf-prod rollout status deploy/trakrf-backend --timeout=120s
```

### Set the log level

```sh
just set-log-level preview debug
```

Raw equivalent:

```sh
kubectl -n trakrf-preview set env deploy/trakrf-backend LOG_LEVEL=debug
kubectl -n trakrf-preview rollout status deploy/trakrf-backend --timeout=120s
```

`LEVEL` must be one of `debug`, `info`, `warn`, `error`; anything else is
rejected before it touches the cluster. `LOG_LEVEL` is the exact variable
name the Go backend logger reads — do not invent a different one.

> **⚠️ EPHEMERAL.** ArgoCD reverts this on the next sync. Normally
> `LOG_LEVEL` reaches the pod through a ConfigMap that the `trakrf-backend`
> chart renders from `config.runtimeLogLevel` and consumes via `envFrom`.
> `set env` instead writes a literal env var into the ArgoCD-managed
> Deployment spec, so the override survives only until
> `trakrf-backend-<env>` next reconciles. Use it for a debugging window,
> not for a decision.
>
> The durable path is the per-env `inlineValues` in `argocd/root/templates/`
> followed by `./scripts/apply-root-app.sh gke`. Note that
> `apply-root-app.sh` is cluster-wide — one run re-renders every per-env
> child app, so whatever is in git for the *other* environment gets applied
> too.

### Exit codes on the three rollout recipes

`rollout`, `backend-restart`, and `set-log-level` all end their
`kubectl rollout status` call with `|| true`, so the recipe continues to its
trailing summary (or the EPHEMERAL warning) even when the rollout stalls.
**Consequence: `just` exits 0 even if the rollout never completed.** For
these three, read the streamed output — `deployment "trakrf-backend"
successfully rolled out` is the thing to look for. Do not trust the exit
code. Confirm with `just pods <env>` if the output was ambiguous.

## 7. ArgoCD

### Status of every application

```sh
just argo-status
```

Raw equivalent:

```sh
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:'.status.sync.revision'
```

The `REVISION` column shows the git SHA (or chart version) each app last
synced — useful for answering "did my merge actually land?".

### Request a sync

```sh
just argo-sync trakrf-backend-preview
just argo-sync trakrf-backend-prod      # prompts
```

Raw equivalent:

```sh
kubectl -n argocd patch application trakrf-backend-preview --type merge -p '{"operation":{"initiatedBy":{"username":"just-argo-sync"},"sync":{"revision":"HEAD"}}}'
```

The `argocd` CLI is not installed on this box. Patching the Application's
`operation` field is exactly what the CLI does under the hood. The recipe
verifies the Application exists before patching, and prompts for any
`*-prod` app. Watch the result with `just argo-status`.

Note: edits under `argocd/root/templates/*` do **not** auto-sync — a sync
request will not pick them up. Those require `./scripts/apply-root-app.sh gke`.

## 8. Broker

### Broker logs

```sh
just mqtt-logs prod
```

Raw equivalent:

```sh
kubectl -n trakrf-prod logs -l app.kubernetes.io/name=trakrf-mosquitto -c mosquitto --tail=100 -f
```

The `-c mosquitto` is required — the broker pod also runs an exporter
sidecar. Follows; Ctrl-C to stop.

### Subscribe to a topic

```sh
just mqtt-sub preview '#'
just mqtt-sub prod 'trakrf.id/+/tag_scan'
```

Raw equivalent:

```sh
kubectl -n trakrf-prod get secret trakrf-mosquitto-auth -o jsonpath='{.data.username}' | base64 -d
kubectl -n trakrf-prod get secret trakrf-mosquitto-auth -o jsonpath='{.data.password}' | base64 -d
kubectl -n trakrf-prod exec -i deploy/trakrf-mosquitto -c mosquitto -- mosquitto_sub -h 127.0.0.1 -p 1883 -u '<username>' -P '<password>' -t '#' -v
```

This runs inside the broker pod against the loopback listener on `:1883`,
so there is no TLS or client-cert setup to do. Credentials are read live
from the `trakrf-mosquitto-auth` Secret in the target namespace — not from
your environment, which on this host may hold a stale `MOSQUITTO_USER`.
`-v` prints `topic payload` so you can see routing, not merely traffic.

Always single-quote the topic: `#` starts a comment and `$SYS` expands as a
variable in an unquoted shell word.

> **Password visibility.** `mosquitto_sub` takes the password as `-P` on the
> command line and offers no environment-variable alternative, so for the
> few seconds the recipe runs the broker password is visible in `ps aux` to
> any other user on the box. That is acceptable on a single-user machine.
> Know about it before running this on a shared one.

## 9. Existing recipes worth knowing

Not duplicated here — run `just --list` for the full set:

- `just argocd-ui` / `just argocd-password` — port-forward the ArgoCD UI to
  `:8080` and fetch the admin password.
- `just grafana-ui` / `just grafana-password` — Grafana on `:3000`.
- `just prometheus-ui` — Prometheus on `:9090`. Note that the
  `trakrf-preview` namespace is deliberately excluded from scraping, so
  preview series are empty by design; prod is scraped.
- `just db-restore-test [env]` — restore proof from the latest logical dump.
  See [backups.md](backups.md).
- `just smoke-gke` — scripted post-deploy smoke checks.

## 10. Troubleshooting

### `dial tcp 146.148.95.135:443: connect: network is unreachable`

Intermittent — hit on roughly half of attempts on 2026-07-27, and it clears
on retry within seconds with no credential change. `146.148.95.135` is the
GKE control-plane endpoint.

**Retry two or three times before treating this as an auth problem.**
Mid-incident it reads like a credential failure and will send you down the
wrong path — re-authenticating does not fix it and wastes minutes. Root
cause is undiagnosed. `just ops-check` already retries three times per
namespace for this reason.

The converse also holds: when `ops-check` reports a namespace unreachable,
it points here, but **check its first two lines first**. Expired or missing
credentials produce the same unreachable-namespace result, and then the fix
is `just gcp-auth`, not a retry:

```
❌ gcloud not authenticated  → run: just gcp-auth
❌ ADC missing               → run: just gcp-auth
✅ kubectl context gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1
❌ namespace trakrf-preview unreachable after 3 tries → see docs/ops.md (Troubleshooting)
❌ namespace trakrf-prod unreachable after 3 tries → see docs/ops.md (Troubleshooting)
```

Two ❌ auth lines above the unreachable namespaces means this is an auth
failure wearing a network error's clothes. Unreachable namespaces with the
first two lines green is the real transient.

### ``Recipe `psql` got 0 arguments but takes 1``

`ENV` is required by design on every per-env recipe — there is no default
that could silently mean prod. Name the environment explicitly:
`just psql preview`.

Similarly, `ERROR: ENV must be 'preview' or 'prod', got '...'` means you
passed something that is not one of the two environments (a namespace name,
for instance — pass `prod`, not `trakrf-prod`).

### `error: You must be logged in to the server (Unauthorized)`

Credentials expired. Run `just gcp-auth`. If it reports it is already
authenticated but you still get 401s, force a fresh login:
`FORCE=1 just gcp-auth`.

### Wrong kubectl context

This box also carries AKS and EKS contexts from the other cloud stacks, and
`kubectl config use-context` is sticky across sessions. `just ops-check`
catches it; `just gke-creds` fixes it without re-authenticating.

```sh
kubectl config current-context
```

### `no CNPG primary found in trakrf-<env>`

Either the cluster is mid-failover (no pod currently carries
`cnpg.io/instanceRole=primary`) or you are in the wrong namespace/context.
Check with `just db-status <env>` first.

### `ERROR: no ArgoCD Application named '...'`

`argo-sync` validates the name before patching. Get the exact spelling from
`just argo-status` — apps are suffixed `-preview` / `-prod`.

### Recipes that need `.env.local`

The ops recipes in this document deliberately need nothing but gcloud and
kubectl. But `tofu`-backed recipes (`just gcp`, `just cloudflare`) and the
`*-secrets` recipes read `.env.local`, which lives only in the main
checkout. From a git worktree, run `just worktree-bootstrap` to symlink it,
or run those from the main checkout.

## See also

- [backups.md](backups.md) — logical dumps, WAL archiving, PITR, restores.
- [db-migration.md](db-migration.md) — schema migration procedure.
- [prod-cutover.md](prod-cutover.md) — the production cutover record.

---

Ticket: TRA-1037.
