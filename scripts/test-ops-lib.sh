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

echo "cnpg_primary_pod:"

# Stub kubectl: a shell function shadows the real binary for the callee.
kubectl() { echo "trakrf-db-preview-1"; }
out=$(cnpg_primary_pod trakrf-preview 2>/dev/null); rc=$?
check "returns rc=0 when a primary exists" $rc 0
if [ "$out" = "trakrf-db-preview-1" ]; then
  ok "echoes the pod name"
else
  bad "echoes the pod name (got '$out')"
fi

# Empty stdout is how kubectl reports "no pods matched" for this jsonpath.
kubectl() { echo -n ""; }
cnpg_primary_pod trakrf-preview >/dev/null 2>&1
check "rejects an empty result" $? 1

# A hard kubectl failure (bad ns, auth expired) must not be swallowed.
kubectl() { return 1; }
cnpg_primary_pod trakrf-preview >/dev/null 2>&1
check "rejects a kubectl failure" $? 1

cnpg_primary_pod >/dev/null 2>&1
check "rejects a missing namespace arg" $? 1

unset -f kubectl

echo "db_psql:"

# Stub kubectl to print the argv it was handed, one arg per line, so the
# assertions below pin the exact command that reaches the primary.
kubectl() { printf '%s\n' "$@"; }

# --- non-superuser interactive (the default path) ---
out=$(db_psql trakrf-preview trakrf-db-preview-1 trakrf-migrate 2>/dev/null)
case "$out" in
  *"PGOPTIONS=-c role=trakrf-migrate"*) ok "interactive sets the role via PGOPTIONS" ;;
  *) bad "interactive sets the role via PGOPTIONS (got: $(echo "$out" | tr '\n' ' '))" ;;
esac
case "$out" in
  *"-it"*) ok "interactive allocates a tty" ;;
  *)       bad "interactive allocates a tty" ;;
esac
if ! printf '%s' "$out" | grep -q -- "ON_ERROR_STOP"; then
  ok "interactive does not pass a query"
else
  bad "interactive does not pass a query"
fi

# --- non-superuser one-shot query ---
out=$(db_psql trakrf-prod trakrf-db-prod-1 trakrf-migrate "SELECT 1" 2>/dev/null)
case "$out" in
  *"PGOPTIONS=-c role=trakrf-migrate"*) ok "query mode sets the role via PGOPTIONS" ;;
  *) bad "query mode sets the role via PGOPTIONS" ;;
esac
if printf '%s' "$out" | grep -qx "SELECT 1"; then
  ok "query mode forwards the query verbatim"
else
  bad "query mode forwards the query verbatim"
fi
if printf '%s' "$out" | grep -qx "ON_ERROR_STOP=1"; then
  ok "query mode stops on error"
else
  bad "query mode stops on error"
fi
# -i, not -it: a tty on a piped/scripted call makes psql emit control
# characters into the captured output.
if printf '%s' "$out" | grep -qx -- "-i"; then
  ok "query mode uses -i (no tty)"
else
  bad "query mode uses -i (no tty)"
fi

# --- superuser opt-in ---
out=$(db_psql trakrf-preview trakrf-db-preview-1 postgres 2>/dev/null)
if printf '%s' "$out" | grep -q "PGOPTIONS"; then
  bad "superuser mode sets no role (raw postgres session)"
else
  ok "superuser mode sets no role (raw postgres session)"
fi

# A query containing spaces, a semicolon and quotes must survive as ONE
# argument — word-splitting it would send psql a truncated statement, or
# execute the tail as a separate one.
metaquery="SELECT 'a b'; -- ; drop"
out=$(db_psql trakrf-preview p trakrf-migrate "$metaquery" 2>/dev/null)
if printf '%s' "$out" | grep -qxF "$metaquery"; then
  ok "query with spaces/quotes stays a single argument"
else
  bad "query with spaces/quotes stays a single argument (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

db_psql "" pod trakrf-migrate >/dev/null 2>&1
check "rejects a missing namespace" $? 1
db_psql ns "" trakrf-migrate >/dev/null 2>&1
check "rejects a missing pod" $? 1
db_psql ns pod "" >/dev/null 2>&1
check "rejects a missing role" $? 1

unset -f kubectl

# The psql/psql-super recipes assemble their QUERY argument in the justfile,
# not here, so ops-lib stubs cannot reach that logic. `just --dry-run` renders
# the recipe body (to stderr) without running it, which is enough to assert
# the assembled script is well-formed.
#
# Regression: an interpolation of QUERY written inside a COMMENT in the recipe
# body is expanded by just like any other, so a multi-line query spilled past
# the leading # and its remaining lines executed as shell ("SELECT: command
# not found"). Single-line queries hid it completely.
echo "justfile psql recipes:"
if command -v just >/dev/null 2>&1; then
  mq=$'SELECT \'a\', "B"\nFROM t\nWHERE x IN (\'r\',\'p\'); -- $notavar `notacmd`'
  for recipe in psql psql-super; do
    body=$(just --dry-run "$recipe" preview "$mq" 2>&1 >/dev/null) || body=""
    if [ -z "$body" ]; then
      bad "$recipe: --dry-run produced a body"
      continue
    fi
    if printf '%s\n' "$body" | bash -n 2>/dev/null; then
      ok "$recipe: multi-line query renders a syntactically valid script"
    else
      bad "$recipe: multi-line query renders a syntactically valid script"
    fi
    # End-to-end: run the real recipe with a stub kubectl first on PATH, and
    # confirm the query reaches psql as ONE argument, byte-for-byte.
    stubdir=$(mktemp -d)
    {
      echo '#!/usr/bin/env bash'
      # `get pod` is cnpg_primary_pod resolving the primary; anything else is
      # the exec, whose argv we print one-per-line for inspection.
      echo 'case " $* " in *" get "*) echo fakepod ;; *) printf "%s\n" "$@" ;; esac'
    } > "$stubdir/kubectl"
    chmod +x "$stubdir/kubectl"

    argv=$(PATH="$stubdir:$PATH" YES=1 just "$recipe" preview "$mq" 2>/dev/null)
    rm -rf "$stubdir"

    # The query is the final argument, so compare the tail of the argv dump.
    got=$(printf '%s\n' "$argv" | tail -n "$(printf '%s\n' "$mq" | wc -l)")
    if [ "$got" = "$mq" ]; then
      ok "$recipe: query reaches psql as one intact argument"
    else
      bad "$recipe: query reaches psql as one intact argument (got '$got')"
    fi
  done
else
  echo "  ⏭  skipped (just not found)"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
