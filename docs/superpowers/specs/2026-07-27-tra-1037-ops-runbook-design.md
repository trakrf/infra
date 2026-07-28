# TRA-1037 — Ops runbook + GCP auth/kubectl recipes for preview/prod

- **Date:** 2026-07-27
- **Scope:** `trakrf/infra` only. Platform-side passthrough (`just psql preview` from
  the platform checkout) is **TRA-1053**, blocked by this ticket.
- **Blocks:** TRA-1053, TRA-1046 (prod release)
- **Reference:** Linear TRA-1037 scope-decision comment (2026-07-27)

## Problem

Troubleshooting sessions keep re-deriving the same kubectl invocations from
scratch. If Claude Code is unavailable, reconstructing them costs real time
during exactly the window where time is expensive. This is a learned-helplessness
problem, not a missing-script problem — so the deliverable is a **runbook** that a
human can follow with no agent in the loop, plus the `just` recipes that make the
common paths one command.

**Success criterion:** `docs/ops.md` is followable by a human with no Claude Code,
starting from "you are not authenticated" — not from "you already have a kubectl
context."

## Verified environment facts

Established live on 2026-07-27 against the GKE cluster. These are the values the
runbook records literally.

| Fact | Value |
|---|---|
| GCP project | `trakrf-494211` |
| Zone | `us-central1-a` |
| GKE cluster | `gke-trakrf-demo-usc1` |
| kubectl context | `gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1` |
| Namespaces | `trakrf-preview`, `trakrf-prod` |
| Backend deployment | `trakrf-backend` (same name in both namespaces) |
| CNPG cluster | `trakrf-db-preview` / `trakrf-db-prod` |
| CNPG primary pod | resolve by label `cnpg.io/instanceRole=primary`, **not** the `-1` suffix |
| CNPG container | `postgres`; database `trakrf`, superuser `postgres` (peer auth in-pod) |
| Mosquitto deployment | `trakrf-mosquitto`, containers `mosquitto` + `mosquitto-exporter` |
| Mosquitto listeners | `1883` on `127.0.0.1` (auth required), `8883` on `0.0.0.0` (TLS) |
| Mosquitto creds | Secret `trakrf-mosquitto-auth`, keys `username` / `password` / `passwd` |
| ArgoCD apps | `trakrf-{backend,db,mosquitto}-{preview,prod}` in ns `argocd` |
| gcloud SDK | 565.0.0 |

### Browserless auth — CONFIRMED WORKING (2026-07-27)

The ticket's open question was whether Google still accepts the out-of-band code
exchange. **It does.** Tested end-to-end today:

```
gcloud auth login --no-launch-browser --update-adc
→ prints an accounts.google.com URL
→ paste the verification code at the prompt
→ "Application Default Credentials (ADC) were updated."
→ "You are now logged in as [mike@devopstoai.com]."
```

The flow uses `redirect_uri=https://sdk.cloud.google.com/authcode.html` with
`token_usage=remote` — Google's *current* hosted code-display page, **not** the
deprecated `urn:ietf:wg:oauth:2.0:oob` redirect that has been getting shut off.
That is why it still works, and is a reason to expect it to keep working.

Consequences:

1. **Jump Desktop leaves the critical path**, along with the 1Password lookup for
   the `mike@devopstoai.com` workspace password and the paste into the xfce
   session. The code can be pasted from any browser on any machine.
2. **The ticket's design note #2 is superseded.** It said a headless recipe "can
   only detect, not fix," because it could not complete a browser handoff. With
   `--no-launch-browser` the only interactive step is pasting a code into the
   terminal, so a recipe *can* drive the entire login. This is what makes
   `just gcp-auth` possible.
3. **`--update-adc` does login and ADC in one command.** The `db-restore-test`
   recipe comment currently instructs a separate
   `gcloud auth application-default login`; that is corrected.

The browser flow (`gcloud auth login --update-adc` + xfce/Jump Desktop) is
known-good and **stays documented as the fallback**. It is not removed.

### Known flakiness to document

`kubectl` intermittently fails with:

```
Unable to connect to the server: dial tcp 146.148.95.135:443: connect: network is unreachable
```

Observed repeatedly on 2026-07-27, roughly half of attempts, **succeeding on
retry within seconds** with no credential change. `146.148.95.135` is the GKE
control-plane endpoint. Root cause is not diagnosed here and is out of scope for
this ticket. It must be in the runbook's troubleshooting section because during
an incident it reads like an auth failure and will send an operator down the
wrong path. Guidance: retry two or three times before treating it as real.

## Design

### 1. Auth

**`just gcp-auth`** — zero to ready in one command:

1. Unless `FORCE=1`, check whether credentials are already valid; if so, report
   the active account and exit 0 without a pointless code round-trip.
2. `gcloud auth login --no-launch-browser --update-adc`
3. `gcloud container clusters get-credentials $gke_cluster --zone $gcp_zone --project $gcp_project`
4. `kubectl config use-context gke_${gcp_project}_${gcp_zone}_${gke_cluster}`

**Literals are hoisted to justfile variables**, read by both `gcp-auth` and
`gke-creds`:

```just
gcp_project := "trakrf-494211"
gcp_zone    := "us-central1-a"
gke_cluster := "gke-trakrf-demo-usc1"
```

This **removes the tofu/R2 dependency from `gke-creds`**, which currently shells
out to `tofu -chdir=terraform/gcp output -raw` three times. Per the ticket's
design note #3, R2 state must not sit between an operator and prod during an
outage. Single source of truth, no duplication between the two recipes. The
runbook notes that if the cluster is rebuilt, re-derive with
`tofu -chdir=terraform/gcp output` and update the three variables.

**`just ops-check`** — detect-only preflight, never mutates and never launches
anything. Checks: active gcloud account; ADC file present; kubectl context equals
the expected GKE context; both namespaces reachable. On any failure it prints the
exact command that fixes it (normally `just gcp-auth`).

### 2. Recipe layer

Bare names, `ENV` a **required** argument on every env-scoped recipe — no default,
so an omitted argument is an error rather than a silent env choice.

| Family | Recipes |
|---|---|
| Auth | `gcp-auth`, `ops-check` |
| DB | `psql ENV`, `db-status ENV` |
| Backend | `pods ENV`, `logs ENV`, `rollout ENV`, `backend-restart ENV` ⚠, `set-log-level ENV LEVEL` ⚠ |
| ArgoCD | `argo-status`, `argo-sync APP` ⚠ |
| Broker | `mqtt-logs ENV`, `mqtt-sub ENV TOPIC` |

Thirteen recipes total. Existing `argocd-ui`, `argocd-password`, `grafana-ui`,
`grafana-password`, `prometheus-ui` are unchanged and referenced from the runbook
rather than duplicated.

⚠ = guarded against prod.

**Guard.** Read-only recipes are unguarded for both envs. The three mutating
recipes route through **one shared `_confirm-prod` helper** — a single
implementation, not three copies:

- Prompts `Type the environment name to continue:` and requires the literal
  string `prod`.
- **Fails closed with no tty** — a non-interactive caller cannot fall through.
- `YES=1` skips the prompt, for scripted or known-good use.
- `argo-sync` guards when the target app name ends in `-prod`.

**Env → resource mapping** is derived, not enumerated: namespace `trakrf-{{ENV}}`,
CNPG cluster `trakrf-db-{{ENV}}`. `ENV` is validated against `preview|prod` up
front so a typo fails loudly instead of hitting a nonexistent namespace.

**`psql`** resolves the primary by label rather than assuming the `-1` suffix:

```sh
kubectl -n trakrf-$ENV get pod -l cnpg.io/instanceRole=primary -o name
```

so it keeps working after a failover.

**`mqtt-sub`** reads `username`/`password` from the `trakrf-mosquitto-auth`
Secret and subscribes over the loopback plain listener from inside the container
(`-h 127.0.0.1 -p 1883`), avoiding both TLS trust setup and the stale
`MOSQUITTO_USER` value inherited from the environment.

### 3. Runbook — `docs/ops.md`

Ordered for someone who is unauthenticated and under pressure:

1. **Auth** — `just gcp-auth`, with the raw three-command sequence printed
   directly beneath it so it is hand-typeable if `just` is unavailable. Browser
   flow documented as fallback.
2. **Preflight** — `just ops-check` and how to read its output.
3. **Triage** — "the app is down, what do I look at first": a short ordered path
   through pod state → backend logs → DB reachability → ArgoCD sync state.
4. **Per-family sections** — DB, backend, ArgoCD, broker.
5. **Troubleshooting** — including the `network is unreachable` flap above, and
   the ArgoCD-reverts-live-overrides caveat below.

**Every entry shows the raw `kubectl` command alongside the recipe.** This is the
core anti-learned-helplessness requirement: a recipe whose underlying command you
cannot reconstruct has moved the dependency rather than removed it.

**Live-override caveat, documented prominently.** `LOG_LEVEL` is delivered via a
ConfigMap rendered by the `trakrf-backend` chart from `config.runtimeLogLevel`,
managed by ArgoCD. A live `kubectl set env` is therefore **ephemeral** — the next
sync reverts it. The runbook must say so at the point of use, and point at the
root-app values as the durable path.

## Out of scope

- Platform-side wrappers (TRA-1053).
- Diagnosing the `network is unreachable` control-plane flap.
- Any change to what the recipes operate on — this ticket packages existing
  operations, it does not alter cluster state or chart behavior.
- AKS/EKS equivalents. GKE is the live target (per the cloud-portfolio stance);
  `aks-creds` is left untouched.

## Verification

- `just --list` renders cleanly with the new recipes.
- `just ops-check` passes against the live cluster.
- Each read-only recipe executes successfully against **both** `preview` and
  `prod`.
- Each guarded recipe: (a) prompts on `prod`, (b) proceeds without prompting on
  `preview`, (c) fails closed when stdin is not a tty, (d) proceeds under `YES=1`.
- `just gcp-auth` is exercised at least once from a genuinely unauthenticated
  state, since that is the runbook's entry condition.
- The runbook is walked top-to-bottom and every raw command in it is executed
  as written.
