#!/usr/bin/env bash
# Tests for scripts/check-doc-paths.sh. Run: ./scripts/test-check-doc-paths.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CHECKER="$PWD/scripts/check-doc-paths.sh"

pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected rc=$3, got rc=$2)"; fi; }

# Each case builds a throwaway repo root, writes a doc, and runs the checker
# against it. rc 0 = every referenced path exists, rc 1 = at least one does not.
run_case() {
  local doc_body="$1"; shift
  local root; root="$(mktemp -d)"
  mkdir -p "$root"
  printf '%s\n' "$doc_body" > "$root/DOC.md"
  for f in "$@"; do
    mkdir -p "$root/$(dirname "$f")"
    [ "${f%/}" = "$f" ] && : > "$root/$f" || mkdir -p "$root/$f"
  done
  ( cd "$root" && DOC_ROOT="$root" "$CHECKER" DOC.md >/dev/null 2>&1 )
  local rc=$?
  rm -rf "$root"
  return $rc
}

echo "detects real rot:"
# The tree exists and the file is gone — how infra#165's dangling refs looked.
run_case 'See `helm/cnpg/README.md` for details.' helm/
check "missing path under an existing tree fails" $? 1

run_case 'See `helm/cnpg/README.md` for details.' helm/cnpg/README.md
check "existing path with a slash passes" $? 0

# The actual TRA-1219 bug: a dead cp in a fenced block, not inline code.
run_case '```bash
cp .env.local.example .env.local
```'
check "missing .env sample in a fenced block fails" $? 1

run_case '```bash
cp .env.local.sample .env.local
```' .env.local.sample
check "existing .env sample in a fenced block passes" $? 0

# A path that vanished with a deleted tree — the infra#165 dangling-ref class.
run_case 'Design: `docs/superpowers/specs/2026-04-12-design.md`.' docs/
check "dangling reference into a deleted tree fails" $? 1

echo "stays quiet on things that are not broken:"
# No fixture created for the glob and brace cases on purpose: if the checker
# stripped the pattern and probed the literal prefix instead of rejecting the
# token, these would fail. Pre-creating the target would hide that.
run_case 'Templates live in `argocd/root/templates/*`.'
check "glob is not treated as a path" $? 0

run_case 'See `scripts/smoke-{aks,gke}.sh` for checks.'
check "brace expansion is not treated as a path" $? 0

# Here the fixture IS created: the script path is real and only the argument is
# a placeholder, so the correct behaviour is to check the path and ignore <arg>.
run_case 'Run `scripts/apply-root-app.sh <cluster>` to install.' scripts/apply-root-app.sh
check "placeholder argument is not treated as a path" $? 0

# A copy destination legitimately does not exist yet; only the source must.
run_case '```bash
cp .env.local.sample .env.local
```' .env.local.sample
check "copy destination is not required to exist" $? 0

run_case 'Override with `values-aks.yaml` in the chart dir.'
check "chart-relative bare filename is skipped" $? 0

run_case 'Read <https://github.com/trakrf/infra/blob/main/nope.md> for more.'
check "URL path component is not treated as a repo path" $? 0

run_case 'Set `CLOUDFLARE_ACCOUNT_ID` and `TF_VAR_subscription_id`.'
check "env var names are not treated as paths" $? 0

run_case 'Use the `--merge` flag, never `--squash`.'
check "command flags are not treated as paths" $? 0

# The 86 false positives the naive slash rule produced on this repo.
run_case 'Restart with `deploy/trakrf-backend` in `trakrf-prod/`.'
check "kubernetes resource shorthand is not a path" $? 0

run_case 'Image is `ghcr.io/clevyr/cloudnativepg-timescale` and role `roles/storage.objectAdmin`.'
check "image refs and IAM roles are not paths" $? 0

run_case 'Applies to `preview/prod`, `N/A` for others, see `web/API`.'
check "prose containing slashes is not a path" $? 0

run_case 'Branch from `fix/dns-record-drift` off `origin/main`.'
check "branch names are not paths" $? 0

run_case 'Ignored: `docs/superpowers/`, `docs/notes/`, `.superpowers/`.' docs/
check "directory-shaped ignore patterns are not checked" $? 0

# A path under a real top-level dir but outside this repo (a platform path
# quoted in a runbook) must not fire: first segment is not a top-level entry.
run_case 'See `backend/internal/cmd/migrate/ownership.go` in platform.'
check "another repo's path is not checked" $? 0

echo "reports usefully:"
root="$(mktemp -d)"
mkdir -p "$root/helm"
printf 'Missing: `helm/nope/README.md`\n' > "$root/DOC.md"
out="$( cd "$root" && DOC_ROOT="$root" "$CHECKER" DOC.md 2>&1 )"
rm -rf "$root"
case "$out" in *helm/nope/README.md*) ok "names the missing path in its output";;
  *) bad "names the missing path in its output (got: $out)";; esac
case "$out" in *DOC.md*) ok "names the file the reference came from";;
  *) bad "names the file the reference came from (got: $out)";; esac

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
