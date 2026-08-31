#!/usr/bin/env bash
# Verify that repo-relative paths named in the docs actually exist.
#
# CONTRIBUTING.md rotted in every trakrf repo for one reason: nothing read it.
# No gate, no session, no CI, and no human between the day an env sample was
# renamed and the day someone tried to follow the quickstart. This is the
# consumer. It does not check that the prose is good — only that every file it
# points at is still there, which is the failure that actually stranded people.
#
# Usage: scripts/check-doc-paths.sh [file...]
#        DOC_ROOT=/some/dir scripts/check-doc-paths.sh DOC.md
#
# Exits 0 when every referenced path resolves, 1 when any does not.
set -uo pipefail

ROOT="${DOC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  # Everything that tells a human or an agent how to work here.
  mapfile -t files < <(
    cd "$ROOT" || exit 1
    ls README.md CONTRIBUTING.md AGENTS.md CLAUDE.md SECURITY.md 2>/dev/null
    ls docs/*.md 2>/dev/null
  )
fi

# Deciding what counts as a path is the whole difficulty. "Contains a slash" is
# the obvious rule and it is useless: on this repo it flagged 86 tokens, nearly
# all prose or Kubernetes shorthand — N/A, preview/prod, deploy/trakrf-backend,
# ghcr.io/clevyr/..., roles/storage.objectAdmin. A gate that noisy gets ignored,
# which is how the file being checked rotted in the first place.
#
# So a token is checkable only when both hold:
#
#   1. its last segment carries a file extension — so `docs/superpowers/` and
#      `deploy/trakrf-backend` are out, and README.md is in. Directory-shaped
#      references are usually illustrative or, in AGENTS.md, ignore patterns
#      naming paths that deliberately do not exist.
#   2. its first segment is a real top-level entry of this repo — so terraform/,
#      helm/ and docs/ are in, while backend/..., tmp/... and cnpg.io/... are
#      out. Read from the tree at run time, so adding a directory needs no edit
#      here.
#
# Plus one slash-free case: a sample file (.env.local.sample). Narrow on
# purpose — in `cp X.sample X` the source must exist and the destination must
# not, so matching every `.env*` token would fail the very line it validates.
#
# Rejected outright: anything carrying a glob, brace expansion or placeholder.
# Those are patterns, not paths, and probing the literal text would report a
# file nobody claimed existed.
mapfile -t top_level < <(cd "$ROOT" && ls -A 2>/dev/null)

is_top_level() {
  local seg="$1" t
  for t in "${top_level[@]}"; do [ "$seg" = "$t" ] && return 0; done
  return 1
}

is_checkable() {
  local tok="$1"
  case "$tok" in
    *'*'*|*'?'*|*'{'*|*'}'*|*'<'*|*'>'*|*'$'*) return 1 ;;
  esac
  case "$tok" in
    */*)
      local last="${tok##*/}" first="${tok%%/*}"
      [ -n "$last" ] || return 1          # trailing slash: directory-shaped
      case "$last" in *.*) ;; *) return 1 ;; esac
      is_top_level "$first"
      ;;
    *.example|*.sample|*.template|*.dist) return 0 ;;
    *) return 1 ;;
  esac
}

missing=0
for f in "${files[@]}"; do
  [ -f "$ROOT/$f" ] || continue
  # Strip URLs first — their path components are not repo paths.
  # Then pull out token-shaped runs, keeping the glob and brace characters so
  # a pattern arrives intact and can be rejected rather than silently trimmed
  # into a plausible-looking path.
  while read -r tok; do
    tok="${tok%"${tok##*[!.,;:)]}"}"   # drop trailing punctuation
    [ -n "$tok" ] || continue
    is_checkable "$tok" || continue
    [ -e "$ROOT/${tok%/}" ] && continue
    printf '  %s: %s\n' "$f" "$tok"
    missing=$((missing + 1))
  done < <(
    sed -E 's#[a-z]+://[^ )"`<>]*##g' "$ROOT/$f" \
      | grep -oE '[A-Za-z0-9_.][A-Za-z0-9_./*?{}-]*' \
      | sort -u
  )
done

if [ "$missing" -gt 0 ]; then
  echo "check-doc-paths: $missing referenced path(s) do not exist" >&2
  exit 1
fi

echo "check-doc-paths: all referenced paths exist"
