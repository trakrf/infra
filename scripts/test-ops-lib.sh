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
