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

# require_tf_env
# Validate that the tofu/R2-backed environment variables are present before
# a recipe touches terraform state or the R2 backend. The justfile loads
# these lazily (env_var_or_default) so that recipes with no tofu dependency
# work with no .env.local at all; this is the explicit, clear-message check
# for the recipes that do need them, instead of a raw `env_var` failure at
# justfile-load time or tofu silently running with empty TF_VAR_* values.
require_tf_env() {
    local missing=() v
    for v in CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_TF_STATE_BUCKET DOMAIN_NAME EKS_NLB_HOSTNAME; do
        [ -n "${!v:-}" ] || missing+=("$v")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        local joined
        joined=$(printf ", %s" "${missing[@]}")
        joined=${joined#, }
        echo "ERROR: this recipe needs .env.local (${joined}). Run from the main checkout, or \`direnv allow\`." >&2
        return 1
    fi
    return 0
}

# cnpg_primary_pod <namespace>
# Echo the name of the CNPG primary pod in <namespace>.
#
# Selects on cnpg.io/instanceRole=primary rather than the older
# cnpg.io/cluster=<name>,role=primary pair: instanceRole is maintained by the
# operator across a failover, so this keeps resolving after the primary moves,
# and it does not need the cluster name threaded in.
cnpg_primary_pod() {
    local ns="${1:-}" pod
    if [ -z "$ns" ]; then
        echo "ERROR: cnpg_primary_pod requires a namespace" >&2
        return 1
    fi
    pod=$(kubectl -n "$ns" get pod -l cnpg.io/instanceRole=primary \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$pod" ]; then
        echo "ERROR: no CNPG primary found in $ns" >&2
        return 1
    fi
    echo "$pod"
}

# db_psql <namespace> <pod> <role> [query]
# Run psql against the CNPG primary's `trakrf` database.
#
# Auth is always in-pod peer auth as the `postgres` superuser over the unix
# socket — that is the only credential available without threading a password
# in. What <role> controls is the role the SESSION then runs as:
#
#   trakrf-migrate  ->  PGOPTIONS='-c role=trakrf-migrate' makes the backend
#                       apply the equivalent of SET ROLE at connect time, so
#                       DDL typed in the session is owned by trakrf-migrate —
#                       the role migrations run as, and therefore the only
#                       owner that keeps an object replaceable by a later
#                       migration (TRA-1105, after the TRA-1104 wedge).
#   postgres        ->  no PGOPTIONS; a raw superuser session.
#
# This is a guardrail, not a security boundary: session_user is still the
# postgres superuser, so `SET ROLE postgres` escapes it. Note that plain
# `RESET ROLE` does NOT — the role arrived in the startup packet, so it is
# the session default that RESET returns to. The point is that the DEFAULT
# stops silently minting postgres-owned objects, not that escape is
# impossible.
#
# An empty <query> opens an interactive shell (-it). A non-empty one runs
# `psql -c` with ON_ERROR_STOP=1 and no tty (-i), so the output is clean
# enough to pipe and a failing statement sets a non-zero exit status.
db_psql() {
    local ns="${1:-}" pod="${2:-}" role="${3:-}" query="${4:-}"

    if [ -z "$ns" ]; then
        echo "ERROR: db_psql requires a namespace" >&2
        return 1
    fi
    if [ -z "$pod" ]; then
        echo "ERROR: db_psql requires a pod" >&2
        return 1
    fi
    if [ -z "$role" ]; then
        echo "ERROR: db_psql requires a role" >&2
        return 1
    fi

    # kubectl exec cannot set an environment variable on the remote process,
    # so PGOPTIONS is applied by exec'ing through env(1) inside the container.
    local -a role_env=()
    if [ "$role" != "postgres" ]; then
        role_env=(env "PGOPTIONS=-c role=$role")
    fi

    # ${arr[@]+"${arr[@]}"} — expanding an empty array as plain "${arr[@]}"
    # is an unbound-variable error under `set -u` on bash before 4.4.
    if [ -n "$query" ]; then
        kubectl -n "$ns" exec -i "$pod" -c postgres -- \
            ${role_env[@]+"${role_env[@]}"} \
            psql -U postgres -d trakrf -v ON_ERROR_STOP=1 -c "$query"
    else
        kubectl -n "$ns" exec -it "$pod" -c postgres -- \
            ${role_env[@]+"${role_env[@]}"} \
            psql -U postgres -d trakrf
    fi
}

# argocd_automated_get <app>
# Echo the Application's spec.syncPolicy.automated as JSON, or nothing when
# automated sync is not configured. An unset policy is a real state, not an
# error — a caller restoring it must put back exactly what it found, rather
# than a policy the Application never had.
#
# Locals here are prefixed `_ac_` deliberately. Bash `local` is DYNAMICALLY
# scoped: while this function runs, its locals shadow same-named variables in
# every caller and in anything it calls — including a trap handler that fires
# mid-call. A plain `local policy` cost an afternoon: a caller saving the old
# policy in `$policy`, interrupted during `argocd_automated_set "$app" null`,
# ran its restore trap and read `policy=null` from THIS function's frame,
# then dutifully restored null and left automated sync switched off.
argocd_automated_get() {
    local _ac_app="${1:-}"
    if [ -z "$_ac_app" ]; then
        echo "ERROR: argocd_automated_get requires an application name" >&2
        return 1
    fi
    kubectl -n argocd get application "$_ac_app" \
        -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null
}

# argocd_automated_set <app> <policy-json|null|"">
# Patch spec.syncPolicy.automated. Pass a JSON object to restore a policy, or
# `null` — or the empty string, which is how an unset policy reads back — to
# suspend automated sync.
#
# Suspending is what makes a deliberately-broken environment safe to leave
# broken for a few seconds: with automated sync off, no ArgoCD-driven deploy,
# and therefore no migrate Job, can land in the middle of the window.
argocd_automated_set() {
    local _ac_app="${1:-}" _ac_policy="${2-}"
    if [ -z "$_ac_app" ]; then
        echo "ERROR: argocd_automated_set requires an application name" >&2
        return 1
    fi
    [ -n "$_ac_policy" ] || _ac_policy=null
    kubectl -n argocd patch application "$_ac_app" --type merge \
        -p "{\"spec\":{\"syncPolicy\":{\"automated\":${_ac_policy}}}}"
}
