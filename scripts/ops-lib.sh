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
