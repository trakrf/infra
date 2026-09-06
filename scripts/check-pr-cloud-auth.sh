#!/usr/bin/env bash
# Fails if a job that authenticates to a cloud provider can be reached by a
# pull_request event without an explicit enable switch.
#
# This is the mechanism TRA-1220 was missing. terraform-azure.yml's `plan` job
# ran azure/login on every PR touching terraform/azure/ and had been red since
# the AKS burn-down deleted the app registration it logs in as — for a month,
# unnoticed, because the check is not required. A red non-required check is
# worse than no check: it trains everyone to skim past the check list, and the
# next real failure beside it is invisible.
#
# A cloud login is the one step that fails for reasons wholly outside the repo
# — an identity destroyed, a subscription cancelled, a secret rotated — so it
# is the step that can strand a check red with no commit to blame. Requiring an
# enable switch means deprovisioning a cloud is a repository-variable flip, not
# a PR, and never leaves a check red to be ignored.
#
# Usage: check-pr-cloud-auth.sh [workflow.yml ...]   (default: .github/workflows/*.yml)
# Exit:  0 clean, 1 an ungated cloud-auth job is PR-reachable, 2 unreadable input.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(ls .github/workflows/*.yml 2>/dev/null)
fi

[ "${#files[@]}" -gt 0 ] || { echo "no workflow files to check"; exit 2; }

python3 - "${files[@]}" <<'PY'
import re
import sys

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

# Actions whose whole job is to exchange a token with a cloud provider.
CLOUD_AUTH = (
    "azure/login",
    "aws-actions/configure-aws-credentials",
    "google-github-actions/auth",
)
PR_EVENTS = ("pull_request", "pull_request_target")

findings = []
hard_error = False

for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            wf = yaml.safe_load(fh)
    except Exception as err:
        print(f"error: cannot parse {path}: {err}", file=sys.stderr)
        hard_error = True
        continue

    if not isinstance(wf, dict):
        print(f"error: {path} is not a YAML mapping", file=sys.stderr)
        hard_error = True
        continue

    # YAML 1.1 resolves a bare `on:` key to the boolean True, so a workflow's
    # trigger block arrives under True rather than "on". Both spellings occur.
    triggers = wf.get("on", wf.get(True))
    if isinstance(triggers, str):
        events = [triggers]
    elif isinstance(triggers, list):
        events = [e for e in triggers if isinstance(e, str)]
    elif isinstance(triggers, dict):
        events = [e for e in triggers if isinstance(e, str)]
    else:
        events = []

    if not any(e in PR_EVENTS for e in events):
        continue  # unreachable from a PR; a dispatched failure has someone to answer it

    jobs = wf.get("jobs") or {}
    if not isinstance(jobs, dict):
        continue

    for name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        cond = str(job.get("if", ""))
        # A job pinned to a non-PR event cannot be reached by a PR however the
        # workflow is triggered, so it needs no enable switch — a dispatched
        # failure has a human already waiting on it.
        pinned = re.findall(r"github\.event_name\s*==\s*['\"]([\w-]+)['\"]", cond)
        if pinned and not any(e in PR_EVENTS for e in pinned):
            continue
        steps = job.get("steps") or []
        used = [
            s["uses"]
            for s in steps
            if isinstance(s, dict)
            and isinstance(s.get("uses"), str)
            and s["uses"].split("@", 1)[0] in CLOUD_AUTH
        ]
        if not used:
            continue
        # `vars.` is the enable switch: a repository variable can be flipped
        # without a PR, which is what makes turning a stack off honest rather
        # than leaving its check red or deleting the workflow outright.
        if "vars." in cond:
            continue
        findings.append((path, name, used[0]))

if findings:
    print("PR-reachable jobs authenticate to a cloud with no enable switch:\n")
    for path, name, action in findings:
        print(f"  {path}: job '{name}' runs {action}")
    print(
        "\nGate each on a repository variable, e.g.:\n"
        "    if: github.event_name == 'pull_request' && vars.AZURE_STACK_ACTIVE == 'true'\n"
        "so the check skips (neutral) instead of standing red when the cloud is gone."
    )
    sys.exit(1)

if hard_error:
    sys.exit(2)

print(f"check-pr-cloud-auth: OK ({len(sys.argv) - 1} workflow(s))")
PY
rc=$?
# A parse failure alongside a real finding still reports the finding (rc 1);
# rc 2 means the checker could not see enough to make a claim either way.
exit $rc
