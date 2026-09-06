#!/usr/bin/env bash
# Tests for scripts/check-pr-cloud-auth.sh. Run: ./scripts/test-check-pr-cloud-auth.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CHECKER="$PWD/scripts/check-pr-cloud-auth.sh"

pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected rc=$3, got rc=$2)"; fi; }

# Each case writes one throwaway workflow file and runs the checker against it.
# rc 0 = no PR-reachable job needs cloud credentials without an enable switch,
# rc 1 = at least one does, rc 2 = the checker could not read a workflow.
run_case() {
  local body="$1"
  local d; d="$(mktemp -d)"
  printf '%s\n' "$body" > "$d/wf.yml"
  "$CHECKER" "$d/wf.yml" >/dev/null 2>&1
  local rc=$?
  rm -rf "$d"
  return $rc
}

echo "detects the TRA-1220 shape:"

# Exactly terraform-azure.yml as it stood: PR-triggered, azure/login, no gate.
run_case "on:
  pull_request:
    branches: [main]
jobs:
  plan:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2"
check "PR-triggered azure/login with no enable switch fails" $? 1

run_case "on:
  pull_request:
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2"
check "PR-triggered azure/login with no 'if' at all fails" $? 1

echo "accepts a job that cannot strand a red check:"

run_case "on:
  pull_request:
    branches: [main]
jobs:
  plan:
    if: github.event_name == 'pull_request' && vars.AZURE_STACK_ACTIVE == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2"
check "enable switch via vars. passes" $? 0

# Dispatch-only: a human asked for it, so a failure is answerable, not ambient.
run_case "on:
  workflow_dispatch:
jobs:
  apply:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2"
check "workflow with no PR trigger passes" $? 0

# terraform-azure.yml's apply job: the workflow has a PR trigger, but this job
# is pinned to workflow_dispatch, so no PR can ever reach it. Flagging it would
# demand a pointless gate — and a checker with false positives gets skimmed
# past, which is the exact disease it exists to treat.
run_case "on:
  pull_request:
  workflow_dispatch:
jobs:
  apply:
    if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2"
check "job pinned to workflow_dispatch is not PR-reachable" $? 0

# ci.yml's shape — PR-triggered but credential-free.
run_case "on:
  pull_request:
jobs:
  tofu-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: opentofu/setup-opentofu@v1
      - run: tofu validate"
check "PR-triggered job with no cloud auth passes" $? 0

echo "covers the other two providers and pull_request_target:"

run_case "on:
  pull_request:
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4"
check "aws-actions/configure-aws-credentials is detected" $? 1

run_case "on:
  pull_request:
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: google-github-actions/auth@v2"
check "google-github-actions/auth is detected" $? 1

run_case "on:
  pull_request_target:
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2"
check "pull_request_target counts as a PR trigger" $? 1

echo "does not pass silently on input it cannot read:"

# A checker that returns 0 on a file it failed to parse is the same class of
# rot as the check it exists to catch: green, and proving nothing.
run_case "on: [pull_request
jobs: ["
check "unparseable YAML is a hard error, not a pass" $? 2

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
