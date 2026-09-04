#!/usr/bin/env bash
# Local mirror of .github/workflows/ci.yml — run before opening a PR so CI
# failures surface here instead of on the PR. Lives in .claude/ beside csw.json,
# which references it; only .claude/worktrees/, settings.local.json and *.lock are
# ignored, so this file is tracked. Promoting it to a `just validate` recipe
# (matching trakrf/platform) would need its own PR.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
run() { printf '\n\033[1m==> %s\033[0m\n' "$*"; "$@" || { fail=1; printf '\033[31mFAILED: %s\033[0m\n' "$*"; }; }

# --- ops-lib unit tests (job: ops-lib) ---
run ./scripts/test-ops-lib.sh

# --- init-grants SQL (job: db-grants) ---
run ./scripts/test-db-grants.sh

# --- doc path references (job: doc-paths) ---
run ./scripts/test-check-doc-paths.sh
run ./scripts/check-doc-paths.sh

# --- tofu fmt (job: tofu-fmt) ---
run tofu fmt -check -recursive terraform

# --- tofu validate (job: tofu-validate, matrix dir) ---
#
# `tofu init` records provider hashes for the current platform into the
# tracked .terraform.lock.hcl files. CI does this in a throwaway checkout and
# never notices; run locally it leaves unrelated lockfile churn staged into
# whatever you commit next. Validation must not mutate the repo, so note
# which lockfiles are clean going in and restore exactly those afterwards —
# a lockfile you had already edited on purpose is left alone.
clean_locks=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  git diff --quiet -- "$f" 2>/dev/null && clean_locks+=("$f")
done < <(git ls-files 'terraform/*/.terraform.lock.hcl')

for d in aws azure cloudflare bootstrap gcp; do
  run tofu -chdir="terraform/$d" init -backend=false -input=false
  run tofu -chdir="terraform/$d" validate
done

if [ "${#clean_locks[@]}" -gt 0 ]; then
  git checkout -- "${clean_locks[@]}"
fi

# --- helm lint + template (job: helm, matrix chart x cluster) ---
for c in cert-manager-config traefik-config trakrf-backend trakrf-db; do
  for k in eks aks; do
    run helm lint "helm/$c" -f "helm/$c/values.yaml" -f "helm/$c/values-$k.yaml"
    run helm template "helm/$c" -f "helm/$c/values.yaml" -f "helm/$c/values-$k.yaml"
  done
done

# --- helm-mosquitto (job: helm-mosquitto, GKE-only) ---
run helm lint helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml
run helm template helm/trakrf-mosquitto -f helm/trakrf-mosquitto/values.yaml -f helm/trakrf-mosquitto/values-gke.yaml \
  --set hostname=mqtt.preview.gke.trakrf.id --set loadBalancerIP=1.2.3.4

# --- argocd-root (job: argocd-root, matrix cluster) ---
for k in eks aks; do
  run helm template trakrf-root argocd/root --set cluster="$k" \
    --set certManagerIdentityClientId=fake --set tenantId=fake --set subscriptionId=fake \
    --set dnsZoneResourceGroup=fake --set traefikLbIp=1.2.3.4 --set mainResourceGroupName=fake
done

printf '\n'
if [ "$fail" -ne 0 ]; then printf '\033[31mvalidate: FAILED\033[0m\n'; exit 1; fi
printf '\033[32mvalidate: OK\033[0m\n'
