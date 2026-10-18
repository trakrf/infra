#!/usr/bin/env bash
# Tests for the grants SQL rendered by helm/trakrf-db's init-grants Job.
# Run: ./scripts/test-db-grants.sh
#
# The Job is the only durable owner of the app role's privileges in-cluster,
# and it re-runs only on a trakrf-db chart upgrade. A privilege silently
# dropped from it is invisible until something in the cluster asks for it —
# which is exactly how the app role went a month without read on the
# migration ledger (TRA-1218), leaving the TRA-1190 schema-drift check inert
# in preview and prod while /health went on reporting a healthy 200.
#
# These assert the rendered SQL, not a live database. Semantics are pinned by
# trakrf/platform's scripts/test-db-init.sh against a real Postgres; what can
# regress *here* is a statement going missing from the template, or reaching
# only some of the overlays.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

# has "<name>" "<extended regex>" — asserts $sql matches.
has() {
  if printf '%s' "$sql" | grep -Eq "$2"; then ok "$1"; else bad "$1"; fi
}

if ! command -v helm >/dev/null 2>&1; then
  echo "helm not found — cannot render the chart" >&2
  exit 1
fi

# Every overlay, including gke. CI's helm matrix covers eks and aks only, so
# gke — the cluster preview and prod actually run on — is asserted nowhere
# else. Its cluster.yaml `fail`s without these two backup values; they are
# placeholders and touch nothing the grants SQL renders.
render() {
  case "$1" in
    gke) helm template helm/trakrf-db \
           -f helm/trakrf-db/values.yaml -f "helm/trakrf-db/values-$1.yaml" \
           --set backups.gcpServiceAccountEmail=fake@example.iam.gserviceaccount.com \
           --set backups.bucket=gs://fake ;;
    *)   helm template helm/trakrf-db \
           -f helm/trakrf-db/values.yaml -f "helm/trakrf-db/values-$1.yaml" ;;
  esac
}

# Reads the render file named by $1; prints "ok|<name>" or "bad|<name>" per check.
#
# Kubernetes rewrites a container's command and args before the process sees
# them: `$(NAME)` becomes that env var's value and `$$` becomes a literal `$`.
# A quoted heredoc stops only the shell from expanding — by then the kubelet
# has already turned `DO $$` into `DO $`, and psql rejects it. `helm template`
# shows the text before that rewrite, so grepping the render cannot see this;
# these checks apply a port of the kubelet's expansion
# (k8s.io/kubernetes third_party/forked/golang/expansion) and assert on what
# psql would actually be handed.
kube_expanded_checks() {
  python3 - "$1" <<'PY'
import re
import sys

try:
    import yaml
except ImportError:
    print("bad|PyYAML is required (pip install pyyaml)")
    sys.exit(0)


def expand(text, defined):
    """Kubernetes' command/args expansion. An undefined $(NAME) is left as
    written, and a `$` followed by anything other than `$` or `(` passes
    through, which is why shell `$(seq 1 30)` and `$i` survive it."""
    out, i = [], 0
    while i < len(text):
        if text[i] == "$" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "$":
                out.append("$")
                i += 2
                continue
            if nxt == "(":
                close = text.find(")", i + 2)
                if close != -1:
                    name = text[i + 2:close]
                    out.append(defined.get(name, "$(" + name + ")"))
                    i = close + 1
                    continue
            out.append("$" + nxt)
            i += 2
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


job = next(
    (d for d in yaml.safe_load_all(open(sys.argv[1]))
     if d and d.get("kind") == "Job"
     and d["metadata"]["name"].endswith("-init-grants")),
    None,
)
if job is None:
    print("bad|renders the init-grants Job")
    sys.exit(0)

container = job["spec"]["template"]["spec"]["containers"][0]
script = container["command"][-1]
# The values are irrelevant; only whether a name is defined changes the result.
defined = {e["name"]: "<" + e["name"] + ">" for e in container.get("env", [])}
expanded = expand(script, defined)

# Nothing in this script is meant for the kubelet, so any rewrite is a bug.
print(("ok" if expanded == script else "bad")
      + "|Kubernetes leaves the init-grants command unchanged")

body = re.search(r"<<'SQL'\n(.*?)^SQL$", expanded, re.S | re.M)
tags = re.findall(r"\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$", body.group(1) if body else "")
balanced = (len(tags) >= 2 and len(tags) % 2 == 0
            and tags[0::2] == tags[1::2])
print(("ok" if balanced else "bad")
      + "|psql receives balanced dollar-quotes (" + " ".join(tags) + ")")
PY
}

for cluster in eks aks gke; do
  echo "init-grants SQL (${cluster}):"

  if ! sql=$(render "$cluster" 2>&1); then
    bad "renders at all — $sql"
    continue
  fi

  # The point of the ticket: without this the backend's schema-state reader
  # gets "permission denied for table schema_migrations", and /health reports
  # a healthy 200 with the schema block omitted — "I cannot tell" wearing the
  # same payload as "everything is fine".
  has "grants SELECT on trakrf.schema_migrations" \
      'GRANT SELECT ON trakrf\.schema_migrations TO'

  # The ledger is bookkeeping, not application data. The blanket ON ALL
  # TABLES grant below hands out INSERT/UPDATE/DELETE indiscriminately; this
  # narrows it back down, so "SELECT only" is enforced and not merely meant.
  has "revokes INSERT, UPDATE, DELETE on the ledger" \
      'REVOKE INSERT, UPDATE, DELETE ON trakrf\.schema_migrations FROM'

  # The ledger belongs to the trakrf-backend release's migrate Job, which
  # this chart is not ordered against — on a fresh install it does not exist
  # yet. Unguarded, the GRANT aborts the Job under ON_ERROR_STOP=1 and takes
  # every grant after it down too.
  has "guards both on the ledger existing" \
      "to_regclass\('trakrf\.schema_migrations'\) IS NOT NULL"

  # Regression guard on the grants that were already there. The ledger
  # statements sit in the same heredoc; a bad edit takes these with them.
  has "grants CONNECT on the database" 'GRANT CONNECT ON DATABASE'
  has "grants USAGE on schema trakrf"  'GRANT USAGE ON SCHEMA trakrf TO'
  has "grants CRUD on all tables" \
      'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA trakrf'
  has "sets default privileges"        'ALTER DEFAULT PRIVILEGES FOR ROLE'

  # What psql receives is not what helm renders: the kubelet expands the
  # container command first. Checked separately below.
  while IFS='|' read -r verdict name; do
    if [ "$verdict" = ok ]; then ok "$name"; else bad "$name"; fi
  done < <(kube_expanded_checks <(printf '%s' "$sql"))
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
