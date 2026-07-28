# TRA-1037 Ops Runbook + GCP Auth/kubectl Recipes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `docs/ops.md` — a runbook followable by a human with no Claude Code starting from "you are not authenticated" — plus 13 `just` recipes that make its common paths one command.

**Architecture:** Two shared bash helpers live in `scripts/ops-lib.sh` (env validation, prod confirmation) and are sourced by shebang recipes in the root `justfile`. Cluster coordinates are hoisted to justfile variables so no recipe on the incident path depends on tofu/R2 state. The runbook documents the raw `kubectl` command next to every recipe, so the recipe is a convenience and never the only way.

**Tech Stack:** `just`, bash, `gcloud` (SDK 565.0.0), `kubectl`, CloudNativePG, ArgoCD, Mosquitto.

## Global Constraints

- Cluster coordinates, verbatim: project `trakrf-494211`, zone `us-central1-a`, cluster `gke-trakrf-demo-usc1`, context `gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1`.
- `ENV` is a **required** argument on every env-scoped recipe. No default. Valid values `preview` | `prod` only.
- Namespace is derived as `trakrf-<ENV>`; CNPG cluster as `trakrf-db-<ENV>`.
- Read-only recipes are unguarded for both envs. Mutating recipes against `prod` require typed confirmation, **fail closed without a tty**, and honor `YES=1`.
- **In justfiles use a single `$` for shell variables.** `$$VAR` expands to `<PID>VAR`, not `$VAR`.
- Every recipe that touches a cluster uses a shebang recipe (`#!/usr/bin/env bash` + `set -euo pipefail`), matching the existing `origin-cert-secret` and `db-restore-test` style.
- The `argocd` CLI is **not installed**. All ArgoCD operations go through `kubectl`.
- Never remove the browser auth flow from the docs. It is the documented fallback.

---

### Task 1: Shared ops helpers (`scripts/ops-lib.sh`)

The safety-critical piece. `confirm_prod` is the single implementation behind every prod guard, so it gets its own task and its own tests.

**Files:**
- Create: `scripts/ops-lib.sh`
- Test: `scripts/test-ops-lib.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: two shell functions, sourced (never executed) by justfile recipes:
  - `require_env <env>` — returns 0 for `preview`/`prod`; prints an error to stderr and returns 1 otherwise.
  - `confirm_prod <env> <action-description>` — returns 0 immediately when `<env>` is not `prod`; otherwise gates as described. Returns 1 on abort or missing tty.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-ops-lib.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/ops-lib.sh. Run: ./scripts/test-ops-lib.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/ops-lib.sh
source scripts/ops-lib.sh

pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected rc=$3, got rc=$2)"; fi; }

echo "require_env:"
require_env preview >/dev/null 2>&1; check "accepts preview" $? 0
require_env prod    >/dev/null 2>&1; check "accepts prod"    $? 0
require_env staging >/dev/null 2>&1; check "rejects staging" $? 1
require_env ""      >/dev/null 2>&1; check "rejects empty"   $? 1

echo "confirm_prod:"
confirm_prod preview "restart backend" >/dev/null 2>&1
check "no-ops for preview" $? 0

# Fails closed: stdin is not a tty and YES is unset.
confirm_prod prod "restart backend" </dev/null >/dev/null 2>&1
check "fails closed without a tty" $? 1

# YES=1 bypasses, even without a tty.
YES=1 confirm_prod prod "restart backend" </dev/null >/dev/null 2>&1
check "YES=1 bypasses" $? 0

# Interactive paths need a pty; `script` provides one.
if command -v script >/dev/null 2>&1; then
  script -qec 'source scripts/ops-lib.sh; confirm_prod prod act' /dev/null <<<'prod' >/dev/null 2>&1
  check "accepts typed 'prod' on a tty" $? 0
  script -qec 'source scripts/ops-lib.sh; confirm_prod prod act' /dev/null <<<'nope' >/dev/null 2>&1
  check "rejects wrong answer on a tty" $? 1
else
  echo "  ⏭  skipped tty tests (util-linux 'script' not found)"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
```

Make it executable:

```bash
chmod +x scripts/test-ops-lib.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-ops-lib.sh`
Expected: FAIL — `scripts/ops-lib.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/ops-lib.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for the ops recipes in the root justfile.
# SOURCE this file; do not execute it.
#
# Tested by scripts/test-ops-lib.sh — run that after any change here.

# require_env <env>
# Validate that an ENV argument names a real environment, so a typo fails
# loudly instead of resolving to a namespace that does not exist.
require_env() {
    case "${1:-}" in
        preview|prod) return 0 ;;
        *)
            echo "ERROR: ENV must be 'preview' or 'prod', got '${1:-<empty>}'" >&2
            return 1
            ;;
    esac
}

# confirm_prod <env> <action-description>
# Gate a mutating operation on prod behind a typed confirmation.
# No-ops for any env other than prod. Fails closed when stdin is not a
# tty, so a non-interactive caller can never fall through the prompt.
# YES=1 skips the prompt for scripted or known-good use.
confirm_prod() {
    local env="${1:-}" action="${2:-this operation}" answer

    [ "$env" = "prod" ] || return 0

    if [ "${YES:-0}" = "1" ]; then
        echo "⚠️  prod: ${action} (YES=1, confirmation skipped)"
        return 0
    fi

    if [ ! -t 0 ]; then
        echo "❌ Refusing to run '${action}' against prod without a tty." >&2
        echo "   Re-run interactively, or set YES=1 if you are certain." >&2
        return 1
    fi

    echo "⚠️  This MUTATES production (namespace trakrf-prod): ${action}"
    printf "    Type the environment name to continue: "
    read -r answer
    if [ "$answer" != "prod" ]; then
        echo "❌ Aborted." >&2
        return 1
    fi
    return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-ops-lib.sh`
Expected: PASS — `passed: 9  failed: 0` (or `passed: 7` with the tty tests skipped).

- [ ] **Step 5: Commit**

```bash
git add scripts/ops-lib.sh scripts/test-ops-lib.sh
git commit -m "feat(tra-1037): shared ops helpers with fail-closed prod guard"
```

---

### Task 2: Cluster coordinates + `gcp-auth`, and de-tofu `gke-creds`

**Files:**
- Modify: `justfile` (add variables near the top, alongside the existing `r2_endpoint`; add `gcp-auth`; rewrite `gke-creds` at lines 101-107; fix the `db-restore-test` comment at line 276)

**Interfaces:**
- Consumes: nothing.
- Produces: justfile variables `gcp_project`, `gcp_zone`, `gke_cluster`, `gke_context`, referenced by `gcp-auth`, `gke-creds`, and `ops-check` (Task 3).

- [ ] **Step 1: Add the coordinate variables**

In `justfile`, immediately after the existing `r2_endpoint := ...` line:

```just
# GKE ops coordinates — deliberately literal. `gke-creds` used to derive these
# from `tofu -chdir=terraform/gcp output`, which puts R2 state between an
# operator and prod during an incident. If the cluster is ever rebuilt,
# re-derive with `tofu -chdir=terraform/gcp output` and update these three.
gcp_project := "trakrf-494211"
gcp_zone    := "us-central1-a"
gke_cluster := "gke-trakrf-demo-usc1"
gke_context := "gke_" + gcp_project + "_" + gcp_zone + "_" + gke_cluster
```

- [ ] **Step 2: Verify the variables render correctly**

Run: `just --evaluate | grep -E 'gcp_|gke_'`
Expected: four lines; `gke_context` reads exactly `gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1`.

Cross-check it matches the live context name:

Run: `kubectl config get-contexts -o name | grep gke_`
Expected: identical string.

- [ ] **Step 3: Add the `gcp-auth` recipe**

Add to `justfile` immediately before the existing `gke-creds` recipe:

```just
# Authenticate to GCP and point kubectl at the GKE cluster — zero to ready.
#
# Uses the browserless flow: it prints a URL, you open it anywhere (phone,
# laptop, any browser), and paste the verification code back at the prompt.
# `--update-adc` refreshes Application Default Credentials in the same step,
# so no separate `gcloud auth application-default login` is needed.
#
# Skips re-authentication if credentials are already valid; FORCE=1 overrides.
gcp-auth:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${FORCE:-0}" != "1" ] \
       && gcloud auth print-access-token >/dev/null 2>&1 \
       && [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
        echo "✅ Already authenticated as $(gcloud config get-value account 2>/dev/null), ADC present."
        echo "   Re-run with FORCE=1 to re-authenticate."
    else
        gcloud auth login --no-launch-browser --update-adc
    fi
    gcloud container clusters get-credentials {{ gke_cluster }} \
        --zone {{ gcp_zone }} --project {{ gcp_project }}
    kubectl config use-context {{ gke_context }}
    echo "✅ kubectl context: {{ gke_context }}"
```

- [ ] **Step 4: Rewrite `gke-creds` to drop the tofu calls**

Replace the existing `gke-creds` recipe (currently `justfile:101-107`, the one with the three `tofu -chdir=terraform/gcp output -raw` calls) with:

```just
# Point kubectl at the GKE cluster using the coordinates above (no tofu, no R2).
# Assumes you are already authenticated — run `just gcp-auth` if not.
gke-creds:
    @gcloud container clusters get-credentials {{ gke_cluster }} \
        --zone {{ gcp_zone }} --project {{ gcp_project }}
    @kubectl config use-context {{ gke_context }}
```

- [ ] **Step 5: Fix the stale ADC instruction in `db-restore-test`**

In `justfile`, the `db-restore-test` comment block (near line 276) currently reads:

```
#   - `gcloud auth application-default login` (for `gcloud storage`)
```

Replace that line with:

```
#   - `just gcp-auth` (logs in and refreshes ADC in one step — `gcloud storage`
#     needs ADC, which `gcloud auth login --update-adc` already provides)
```

- [ ] **Step 6: Verify both recipes work**

Run: `just gcp-auth`
Expected: reports already-authenticated (credentials are currently valid), then fetches credentials and prints the context line. No code prompt.

Run: `just gke-creds`
Expected: `kubeconfig entry generated for gke-trakrf-demo-usc1.` No tofu output, no R2 access.

Run: `just --list | grep -E 'gcp-auth|gke-creds'`
Expected: both present with their doc comments.

- [ ] **Step 7: Commit**

```bash
git add justfile
git commit -m "feat(tra-1037): add gcp-auth, drop tofu dependency from gke-creds"
```

---

### Task 3: `ops-check` preflight

**Files:**
- Modify: `justfile` (add `ops-check` after `gcp-auth`)

**Interfaces:**
- Consumes: `gke_context` from Task 2.
- Produces: `just ops-check`, exit 0 when everything is ready, exit 1 otherwise.

- [ ] **Step 1: Add the recipe**

Detect-only. It never launches a browser and never mutates. Namespace reachability retries three times because the control-plane endpoint flaps intermittently (see the runbook's troubleshooting section) and a single failure would raise a false alarm mid-incident.

```just
# Preflight: is this machine ready to operate the cluster? Detect-only —
# never authenticates, never mutates. Prints the fix for anything it finds.
ops-check:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0

    acct=$(gcloud config get-value account 2>/dev/null || true)
    if [ -n "$acct" ] && gcloud auth print-access-token >/dev/null 2>&1; then
        echo "✅ gcloud authenticated as $acct"
    else
        echo "❌ gcloud not authenticated  → run: just gcp-auth"
        rc=1
    fi

    if [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
        echo "✅ ADC present"
    else
        echo "❌ ADC missing               → run: just gcp-auth"
        rc=1
    fi

    ctx=$(kubectl config current-context 2>/dev/null || true)
    if [ "$ctx" = "{{ gke_context }}" ]; then
        echo "✅ kubectl context {{ gke_context }}"
    else
        echo "❌ kubectl context is '${ctx:-<none>}' → run: just gcp-auth"
        rc=1
    fi

    for ns in trakrf-preview trakrf-prod; do
        reachable=0
        for _ in 1 2 3; do
            if kubectl get ns "$ns" >/dev/null 2>&1; then reachable=1; break; fi
            sleep 2
        done
        if [ "$reachable" = "1" ]; then
            echo "✅ namespace $ns reachable"
        else
            echo "❌ namespace $ns unreachable after 3 tries → see docs/ops.md (Troubleshooting)"
            rc=1
        fi
    done

    exit $rc
```

- [ ] **Step 2: Verify the healthy path**

Run: `just ops-check; echo "rc=$?"`
Expected: five ✅ lines and `rc=0`.

- [ ] **Step 3: Verify it detects a wrong context**

```bash
kubectl config use-context aks-trakrf-demo-ussc
just ops-check; echo "rc=$?"
```
Expected: the context line reports ❌ with the `just gcp-auth` fix, and `rc=1`.

Restore:

```bash
just gke-creds
just ops-check; echo "rc=$?"
```
Expected: back to all ✅ and `rc=0`.

- [ ] **Step 4: Commit**

```bash
git add justfile
git commit -m "feat(tra-1037): add ops-check preflight"
```

---

### Task 4: Database recipes

**Files:**
- Modify: `justfile` (add `psql`, `db-status`)

**Interfaces:**
- Consumes: `require_env` from Task 1.
- Produces: `just psql ENV`, `just db-status ENV`.

- [ ] **Step 1: Add both recipes**

`psql` resolves the primary by label rather than assuming the `-1` suffix, so it survives a failover.

```just
# Interactive psql on the CNPG primary. Superuser via in-pod peer auth.
#   just psql preview
#   just psql prod
psql ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    pod=$(kubectl -n "$ns" get pod -l cnpg.io/instanceRole=primary \
            -o jsonpath='{.items[0].metadata.name}')
    if [ -z "$pod" ]; then
        echo "ERROR: no CNPG primary found in $ns" >&2
        exit 1
    fi
    echo "→ $ns/$pod (database: trakrf)"
    kubectl -n "$ns" exec -it "$pod" -c postgres -- psql -U postgres -d trakrf

# CNPG cluster health plus its instance pods.
#   just db-status prod
db-status ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" get cluster "trakrf-db-{{ ENV }}"
    echo
    kubectl -n "$ns" get pods -l "cnpg.io/cluster=trakrf-db-{{ ENV }}" -o wide
```

- [ ] **Step 2: Verify env validation rejects a typo**

Run: `just db-status stagingg; echo "rc=$?"`
Expected: `ERROR: ENV must be 'preview' or 'prod', got 'stagingg'` and `rc=1`.

Run: `just psql; echo "rc=$?"`
Expected: just's own error — `Recipe \`psql\` got 0 arguments but takes 1` — confirming ENV is required.

- [ ] **Step 3: Verify against both environments**

Run: `just db-status preview`
Expected: one row, `Cluster in healthy state`, primary `trakrf-db-preview-1`; then the instance pod, Running.

Run: `just db-status prod`
Expected: same shape for `trakrf-db-prod`.

Run: `just psql preview`
Expected: a `trakrf=#` prompt. Confirm with `\conninfo` then `\q`.

Run: `just psql prod`
Expected: same. `\q` to exit. (Read-only recipe — unguarded on prod by design.)

- [ ] **Step 4: Commit**

```bash
git add justfile
git commit -m "feat(tra-1037): add psql and db-status recipes"
```

---

### Task 5: Backend read-only recipes

**Files:**
- Modify: `justfile` (add `pods`, `logs`, `rollout`)

**Interfaces:**
- Consumes: `require_env` from Task 1.
- Produces: `just pods ENV`, `just logs ENV [SINCE]`, `just rollout ENV`.

Backend pod selector, verified live: `app.kubernetes.io/name=trakrf-backend`. Deployment name is `trakrf-backend` in both namespaces.

- [ ] **Step 1: Add the three recipes**

```just
# All pods in an environment, wide.
#   just pods prod
pods ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    kubectl -n "trakrf-{{ ENV }}" get pods -o wide

# Follow backend logs. SINCE defaults to 10m.
#   just logs prod
#   just logs prod 1h
logs ENV SINCE="10m":
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    kubectl -n "trakrf-{{ ENV }}" logs -l app.kubernetes.io/name=trakrf-backend \
        --since={{ SINCE }} --tail=200 -f

# Backend rollout status plus recent revision history.
#   just rollout prod
rollout ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" rollout status deploy/trakrf-backend --timeout=30s
    echo
    kubectl -n "$ns" get deploy trakrf-backend \
        -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:'.spec.template.spec.containers[0].image'
```

- [ ] **Step 2: Verify against both environments**

Run: `just pods preview` then `just pods prod`
Expected: backend, db, mosquitto pods listed Running, plus completed `pg-dump-*` jobs.

Run: `just rollout preview` then `just rollout prod`
Expected: `deployment "trakrf-backend" successfully rolled out`, then a row showing READY and the pinned image.

Run: `just logs preview` — confirm log lines stream, then Ctrl-C.
Run: `just logs prod 5m` — confirm the `--since` override is honored, then Ctrl-C.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "feat(tra-1037): add pods, logs, rollout recipes"
```

---

### Task 6: Backend mutating recipes (prod-guarded)

**Files:**
- Modify: `justfile` (add `backend-restart`, `set-log-level`)

**Interfaces:**
- Consumes: `require_env` and `confirm_prod` from Task 1.
- Produces: `just backend-restart ENV`, `just set-log-level ENV LEVEL`.

- [ ] **Step 1: Add both recipes**

`set-log-level` carries the ArgoCD-revert warning at the point of use — `LOG_LEVEL` is rendered into a ConfigMap from `config.runtimeLogLevel` and managed by ArgoCD, so a live override does not survive the next sync.

```just
# Restart the backend deployment. Prompts before touching prod.
#   just backend-restart preview
#   YES=1 just backend-restart prod
backend-restart ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    confirm_prod "{{ ENV }}" "rollout restart deploy/trakrf-backend"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" rollout restart deploy/trakrf-backend
    kubectl -n "$ns" rollout status deploy/trakrf-backend --timeout=120s

# Override the backend log level on the live deployment.
#
# EPHEMERAL: LOG_LEVEL is rendered into a ConfigMap by the trakrf-backend
# chart from `config.runtimeLogLevel` and is managed by ArgoCD, so the next
# sync reverts this. For a durable change, edit the per-env inlineValues in
# argocd/root/templates/ and re-run scripts/apply-root-app.sh gke.
#
#   just set-log-level preview debug
set-log-level ENV LEVEL:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    case "{{ LEVEL }}" in
        debug|info|warn|error) ;;
        *) echo "ERROR: LEVEL must be debug|info|warn|error, got '{{ LEVEL }}'" >&2; exit 1 ;;
    esac
    confirm_prod "{{ ENV }}" "set LOG_LEVEL={{ LEVEL }} on deploy/trakrf-backend"
    ns="trakrf-{{ ENV }}"
    kubectl -n "$ns" set env deploy/trakrf-backend LOG_LEVEL={{ LEVEL }}
    kubectl -n "$ns" rollout status deploy/trakrf-backend --timeout=120s
    echo
    echo "⚠️  EPHEMERAL — ArgoCD will revert this on the next sync of trakrf-backend-{{ ENV }}."
    echo "   Durable path: argocd/root/templates/ inlineValues + scripts/apply-root-app.sh gke"
```

- [ ] **Step 2: Verify the guard fires on prod and not on preview**

Run: `just backend-restart preview`
Expected: **no prompt**; restart proceeds and rollout completes.

Run: `just backend-restart prod` and answer `nope` at the prompt.
Expected: the ⚠️ production warning, then `❌ Aborted.` and a non-zero exit. Confirm nothing restarted:

Run: `just pods prod`
Expected: the backend pod's AGE is unchanged (still ~18d, not seconds).

- [ ] **Step 3: Verify it fails closed without a tty**

Run: `just backend-restart prod < /dev/null; echo "rc=$?"`
Expected: `❌ Refusing to run '...' against prod without a tty.` and `rc=1`.

- [ ] **Step 4: Verify LEVEL validation**

Run: `just set-log-level preview verbose; echo "rc=$?"`
Expected: `ERROR: LEVEL must be debug|info|warn|error, got 'verbose'` and `rc=1`. Note this fires **before** any cluster mutation.

- [ ] **Step 5: Verify the real mutation path on preview only**

Run: `just set-log-level preview debug`
Expected: deployment updated, rollout completes, then the EPHEMERAL warning.

Confirm it took effect:

Run: `kubectl -n trakrf-preview get deploy trakrf-backend -o jsonpath='{.spec.template.spec.containers[0].env}'; echo`
Expected: includes `LOG_LEVEL` with value `debug`.

Now revert, so the branch leaves no live drift behind:

```bash
kubectl -n trakrf-preview set env deploy/trakrf-backend LOG_LEVEL-
kubectl -n trakrf-preview rollout status deploy/trakrf-backend --timeout=120s
```
Expected: rollout completes. Preview's durable level (`info`) comes back from the ConfigMap.

**Do not exercise the mutating path against prod.** The guard itself was proven in Step 2 with an aborted prompt.

- [ ] **Step 6: Commit**

```bash
git add justfile
git commit -m "feat(tra-1037): add guarded backend-restart and set-log-level"
```

---

### Task 7: ArgoCD recipes

**Files:**
- Modify: `justfile` (add `argo-status`, `argo-sync`)

**Interfaces:**
- Consumes: `confirm_prod` from Task 1.
- Produces: `just argo-status`, `just argo-sync APP`.

The `argocd` CLI is **not installed on this machine**, so both recipes use `kubectl` against the `argocd` namespace. `argo-sync` requests a sync by patching the Application's `operation` field, which is what the CLI does under the hood.

- [ ] **Step 1: Add both recipes**

```just
# Sync + health for every ArgoCD Application.
argo-status:
    @kubectl get applications -n argocd \
        -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:'.status.sync.revision'

# Request a sync of one ArgoCD Application. Prompts for any *-prod app.
# The argocd CLI is not installed here; this patches the Application's
# operation field, which is what the CLI does under the hood.
#   just argo-sync trakrf-backend-preview
argo-sync APP:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    if ! kubectl -n argocd get application "{{ APP }}" >/dev/null 2>&1; then
        echo "ERROR: no ArgoCD Application named '{{ APP }}' — see: just argo-status" >&2
        exit 1
    fi
    case "{{ APP }}" in
        *-prod) confirm_prod prod "argocd sync {{ APP }}" ;;
    esac
    kubectl -n argocd patch application "{{ APP }}" --type merge \
        -p '{"operation":{"initiatedBy":{"username":"just-argo-sync"},"sync":{"revision":"HEAD"}}}'
    echo "→ sync requested; watch with: just argo-status"
```

- [ ] **Step 2: Verify status output**

Run: `just argo-status`
Expected: 14 Applications. All `Synced`/`Healthy` except `argocd` itself, which shows `OutOfSync`/`Healthy` — that is the known-cosmetic self-managed-app state, not a fault.

- [ ] **Step 3: Verify the unknown-app guard**

Run: `just argo-sync trakrf-backend-nope; echo "rc=$?"`
Expected: `ERROR: no ArgoCD Application named 'trakrf-backend-nope'` and `rc=1`.

- [ ] **Step 4: Verify the prod guard fires on name suffix**

Run: `just argo-sync trakrf-backend-prod < /dev/null; echo "rc=$?"`
Expected: fails closed without a tty, `rc=1`, no patch applied.

- [ ] **Step 5: Verify a real sync on preview**

Run: `just argo-sync trakrf-backend-preview`
Expected: `application.argoproj.io/trakrf-backend-preview patched`.

Run: `just argo-status`
Expected: `trakrf-backend-preview` returns to `Synced`/`Healthy` within a few seconds. (It was already synced, so this is a no-op sync — safe.)

- [ ] **Step 6: Commit**

```bash
git add justfile
git commit -m "feat(tra-1037): add argo-status and argo-sync recipes"
```

---

### Task 8: Broker recipes

**Files:**
- Modify: `justfile` (add `mqtt-logs`, `mqtt-sub`)

**Interfaces:**
- Consumes: `require_env` from Task 1.
- Produces: `just mqtt-logs ENV`, `just mqtt-sub ENV TOPIC`.

Verified live: the Mosquitto pod runs two containers (`mosquitto`, `mosquitto-exporter`) so exec must pass `-c mosquitto`; `mosquitto_sub` is present at `/usr/bin/mosquitto_sub` inside the container; the broker has a loopback plain listener on `127.0.0.1:1883` that still requires auth; credentials live in Secret `trakrf-mosquitto-auth` under keys `username` and `password`.

Subscribing from inside the container over the loopback listener avoids TLS trust setup entirely, and reads the live credentials from the cluster rather than a possibly stale `MOSQUITTO_USER` in the environment.

- [ ] **Step 1: Add both recipes**

```just
# Follow broker logs.
#   just mqtt-logs prod
mqtt-logs ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    kubectl -n "trakrf-{{ ENV }}" logs -l app.kubernetes.io/name=trakrf-mosquitto \
        -c mosquitto --tail=100 -f

# Subscribe to a topic from inside the broker pod (loopback listener, no TLS
# setup needed). Credentials are read live from the trakrf-mosquitto-auth
# Secret, not from the environment. Ctrl-C to stop.
#   just mqtt-sub preview '#'
#   just mqtt-sub prod 'trakrf.id/+/tag_scan'
mqtt-sub ENV TOPIC:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/ops-lib.sh
    require_env "{{ ENV }}"
    ns="trakrf-{{ ENV }}"
    user=$(kubectl -n "$ns" get secret trakrf-mosquitto-auth -o jsonpath='{.data.username}' | base64 -d)
    pass=$(kubectl -n "$ns" get secret trakrf-mosquitto-auth -o jsonpath='{.data.password}' | base64 -d)
    echo "→ $ns broker, user $user, topic {{ TOPIC }} (Ctrl-C to stop)"
    kubectl -n "$ns" exec -i deploy/trakrf-mosquitto -c mosquitto -- \
        mosquitto_sub -h 127.0.0.1 -p 1883 -u "$user" -P "$pass" -t '{{ TOPIC }}' -v
```

- [ ] **Step 2: Verify logs against both environments**

Run: `just mqtt-logs preview` — confirm broker log lines, Ctrl-C.
Run: `just mqtt-logs prod` — same, Ctrl-C.

- [ ] **Step 3: Verify subscribe connects and authenticates**

Run: `just mqtt-sub preview '$SYS/broker/uptime'`
Expected: the `→ trakrf-preview broker, user trakrf-mqtt, ...` line, then an uptime message within ~10s. This proves the loopback listener accepted the credentials. Ctrl-C.

Note: quote the topic. `#` and `$SYS` are shell metacharacters unquoted.

Run: `just mqtt-sub prod '$SYS/broker/uptime'`
Expected: same against prod. Ctrl-C. (Read-only; unguarded by design.)

- [ ] **Step 4: Commit**

```bash
git add justfile
git commit -m "feat(tra-1037): add mqtt-logs and mqtt-sub recipes"
```

---

### Task 9: The runbook — `docs/ops.md`

The actual deliverable. Everything above exists to make this document short and executable.

**Files:**
- Create: `docs/ops.md`

**Interfaces:**
- Consumes: every recipe from Tasks 2-8.
- Produces: nothing consumed by later code; Task 10 validates it.

- [ ] **Step 1: Write the runbook**

Match the prose style of `docs/backups.md` — `##` sections, short paragraphs, fenced `sh` blocks. Required content and order:

**Header.** One sentence on what this is and the promise it makes: *usable with no Claude Code and no prior kubectl context.* Note that it covers GKE (the live cluster); AKS/EKS are out of scope.

**1. Authenticate.** Lead with:

```sh
just gcp-auth
```

Immediately beneath it, the hand-typeable equivalent, introduced with a line saying to use it if `just` is unavailable:

```sh
gcloud auth login --no-launch-browser --update-adc
gcloud container clusters get-credentials gke-trakrf-demo-usc1 \
  --zone us-central1-a --project trakrf-494211
kubectl config use-context gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1
```

Explain the browserless flow in two sentences: it prints a URL, you open it on any device with a browser and paste the verification code back. Confirmed working 2026-07-27. State that `--update-adc` covers Application Default Credentials in the same step, so no separate `gcloud auth application-default login` is needed.

Then a **Fallback: browser flow** subsection — for the case where the code exchange is ever rejected: `gcloud auth login --update-adc` from a session with a browser (the xfce desktop on this host, reached via Jump Desktop), which completes the handoff locally. Note that because Claude Code and the desktop session are the same box and same user, credentials written from either are immediately live for both.

Then a **Cluster coordinates** subsection with the literal table (project `trakrf-494211`, zone `us-central1-a`, cluster `gke-trakrf-demo-usc1`, context `gke_trakrf-494211_us-central1-a_gke-trakrf-demo-usc1`), and a note that these are hardcoded in the justfile on purpose so nothing on the incident path needs tofu or R2, plus how to re-derive them (`tofu -chdir=terraform/gcp output`) if the cluster is rebuilt.

**2. Preflight.**

```sh
just ops-check
```

Show sample healthy output (five ✅ lines) and state that every ❌ line prints its own fix.

**3. Triage: something is broken.** A short numbered path, each step naming the recipe and what a bad answer looks like:

1. `just pods <env>` — anything not `Running`/`Completed`?
2. `just logs <env>` — errors in the last 10m?
3. `just db-status <env>` — is the CNPG cluster `Cluster in healthy state`?
4. `just argo-status` — is the env's app `Synced`/`Healthy`? (`argocd` itself showing `OutOfSync` is cosmetic and expected.)
5. `just mqtt-logs <env>` — only if the symptom is ingestion-related.

**4. Environments.** Table: `preview` → ns `trakrf-preview`, CNPG `trakrf-db-preview`, ArgoCD apps `*-preview`; same row for `prod`. State the guard rule: read-only recipes run unguarded against both; mutating recipes prompt for prod, fail closed without a tty, and honor `YES=1`.

**5. Database**, **6. Backend**, **7. ArgoCD**, **8. Broker.** One subsection per recipe. **Each one shows the recipe and the raw kubectl command it runs.** Use the exact commands from Tasks 4-8. For `psql`, explain that the primary is resolved by the `cnpg.io/instanceRole=primary` label so it survives a failover, and give the hand-typeable form:

```sh
kubectl -n trakrf-prod exec -it \
  "$(kubectl -n trakrf-prod get pod -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')" \
  -c postgres -- psql -U postgres -d trakrf
```

In the Backend section, give `set-log-level` its own **⚠️ EPHEMERAL** callout: ArgoCD reverts it on the next sync because `LOG_LEVEL` comes from a chart-rendered ConfigMap (`config.runtimeLogLevel`); the durable path is the per-env `inlineValues` in `argocd/root/templates/` followed by `scripts/apply-root-app.sh gke`.

**9. Existing recipes.** Point at, without duplicating: `argocd-ui`, `argocd-password`, `grafana-ui`, `grafana-password`, `prometheus-ui`, `db-restore-test`, `smoke-gke`.

**10. Troubleshooting.** At minimum:

- **`dial tcp 146.148.95.135:443: connect: network is unreachable`** — intermittent, hit on roughly half of attempts on 2026-07-27, clears on retry within seconds with no credential change. `146.148.95.135` is the GKE control-plane endpoint. **Retry two or three times before treating it as an auth problem** — mid-incident it reads like a credential failure and will send you down the wrong path. Root cause undiagnosed.
- **`Recipe \`psql\` got 0 arguments but takes 1`** — ENV is required by design; name the environment explicitly.
- **`error: You must be logged in to the server (Unauthorized)`** — credentials expired; run `just gcp-auth`.
- **Wrong kubectl context** — this box also holds AKS and EKS contexts; `just ops-check` catches it, `just gke-creds` fixes it.

**Cross-references.** Link `docs/backups.md`, `docs/db-migration.md`, `docs/prod-cutover.md`.

Per the repo convention, keep `TRA-####` refs out of published-docs prose. This file is internal, so a single reference line at the bottom is fine.

- [ ] **Step 2: Verify every command in the doc is real**

Extract and eyeball every fenced command:

```bash
grep -nE '^\s*(just|kubectl|gcloud|tofu) ' docs/ops.md
```

For each `just` line, confirm the recipe exists: `just --list`. For each `kubectl`/`gcloud` line, confirm the resource names match Task 2-8 bodies exactly. Fix any drift.

- [ ] **Step 3: Commit**

```bash
git add docs/ops.md
git commit -m "docs(tra-1037): add preview/prod ops runbook"
```

---

### Task 10: End-to-end walkthrough from an unauthenticated start

The spec's success criterion is that the runbook works from "you are not authenticated." Tasks 2-8 were all verified from an already-authenticated shell, so that entry condition is still unproven. This task proves it.

**Files:**
- Modify: `docs/ops.md` (corrections found during the walkthrough)

- [ ] **Step 1: Confirm the whole recipe surface is present**

Run: `just --list`
Expected: all 13 new recipes present with doc comments — `gcp-auth`, `ops-check`, `psql`, `db-status`, `pods`, `logs`, `rollout`, `backend-restart`, `set-log-level`, `argo-status`, `argo-sync`, `mqtt-logs`, `mqtt-sub`.

- [ ] **Step 2: Re-run the helper tests**

Run: `./scripts/test-ops-lib.sh`
Expected: `failed: 0`.

- [ ] **Step 3: Genuinely revoke credentials**

This is the point of the task — do not skip or simulate it.

```bash
cp ~/.config/gcloud/application_default_credentials.json /tmp/adc-backup.json
gcloud auth revoke --all
rm -f ~/.config/gcloud/application_default_credentials.json
```

Run: `just ops-check; echo "rc=$?"`
Expected: ❌ on gcloud auth, ❌ on ADC, and `rc=1` — the state a real operator starts from.

- [ ] **Step 4: Follow the runbook from the top, typing only what it says**

Work strictly from `docs/ops.md` §1. Run `just gcp-auth`, open the printed URL in a browser, paste the verification code.

Expected: `Application Default Credentials (ADC) were updated.`, login as `mike@devopstoai.com`, then `kubeconfig entry generated`, then the context line.

Run: `just ops-check; echo "rc=$?"`
Expected: five ✅ and `rc=0`.

**If any instruction in §1 was wrong, incomplete, or assumed knowledge the doc does not give — fix `docs/ops.md` now.** That is the deliverable failing its success criterion, and this is the only step that can catch it.

- [ ] **Step 5: Walk the remaining sections**

Execute every read-only command in §3 through §8, both the `just` form and the raw `kubectl` form, against both `preview` and `prod`. Fix any that do not work as written.

Recovery if needed: `cp /tmp/adc-backup.json ~/.config/gcloud/application_default_credentials.json`. Remove the backup once §1 has succeeded: `rm -f /tmp/adc-backup.json`.

- [ ] **Step 6: Confirm no live drift was left behind**

```bash
kubectl -n trakrf-preview get deploy trakrf-backend -o jsonpath='{.spec.template.spec.containers[0].env}'; echo
just argo-status
```
Expected: no `LOG_LEVEL` override remains from Task 6; all apps `Synced`/`Healthy` except the cosmetic `argocd` self-app.

- [ ] **Step 7: Commit any fixes**

```bash
git add docs/ops.md
git commit -m "docs(tra-1037): corrections from unauthenticated walkthrough"
```

- [ ] **Step 8: Open the PR**

```bash
git push -u origin feat/tra-1037-ops-runbook
gh pr create --title "feat(tra-1037): ops runbook + GCP auth/kubectl recipes" --body "$(cat <<'EOF'
Adds `docs/ops.md` — a runbook followable with no Claude Code, starting
from "you are not authenticated" — plus 13 `just` recipes covering DB,
backend, ArgoCD, and broker operations against preview and prod.

Notable:

- **Browserless GCP auth confirmed working.** `gcloud auth login
  --no-launch-browser --update-adc` completes the code exchange and
  refreshes ADC in one command, removing Jump Desktop and the 1Password
  workspace-password lookup from the critical path. The browser flow
  stays documented as the fallback.
- **`gke-creds` no longer calls tofu.** Cluster coordinates are literal
  justfile variables, so R2 state never sits between an operator and
  prod during an incident.
- **Prod mutations are guarded** by a single shared `confirm_prod` helper:
  typed confirmation, fails closed without a tty, `YES=1` escape.
  Read-only recipes are unguarded for both envs.
- Every runbook entry shows the raw `kubectl` command next to the recipe,
  so the recipe is a convenience and never the only way.

Verified by walking the runbook end-to-end from genuinely revoked
credentials.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Per repo convention: never merge to main locally. Merge the PR with `--merge`.
