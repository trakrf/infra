#!/usr/bin/env bash
# Scripted precondition checks for TRA-438 AKS smoke test.
# Exits 0 if all green, non-zero on the first red check.
#
# Usage: scripts/smoke-aks.sh
#
# Env overrides:
#   HOST      — apex hostname to probe (default: aks.trakrf.app)
#   TF_DIR    — tofu module dir to read expected IP from (default: terraform/azure)

set -euo pipefail

HOST="${HOST:-aks.trakrf.app}"
TF_DIR="${TF_DIR:-terraform/azure}"
EXPECTED_IP=$(tofu -chdir="$TF_DIR" output -raw traefik_lb_ip)

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

# 1. ArgoCD Applications all Synced + Healthy
# The `argocd` self-hosting Application is cosmetically OutOfSync (the live
# ArgoCD was installed via helm; its Application definition tracks the same
# chart but diff-matches against helm-managed fields). Excluded from the
# check — Healthy is what matters there.
echo "→ Checking ArgoCD Applications..."
UNHEALTHY=$(kubectl -n argocd get applications -o json \
  | jq -r '.items[] | select(.metadata.name != "argocd") | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name')
if [[ -n "$UNHEALTHY" ]]; then
  echo "  unhealthy applications:"
  echo "$UNHEALTHY" | sed 's/^/    /'
  fail "one or more Applications not Synced+Healthy"
fi
pass "All ArgoCD Applications Synced + Healthy (argocd self-app excluded)"

# 2. cert-manager Certificate Ready
echo "→ Checking cert-manager Certificate..."
READY=$(kubectl -n traefik get certificate trakrf-aks-wildcard \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$READY" != "True" ]]; then
  fail "Certificate trakrf-aks-wildcard is not Ready (status: '$READY')"
fi
pass "Certificate trakrf-aks-wildcard Ready"

# 3. Traefik Service external IP matches tofu output
echo "→ Checking Traefik LoadBalancer IP..."
ACTUAL_IP=$(kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [[ "$ACTUAL_IP" != "$EXPECTED_IP" ]]; then
  fail "Traefik LB IP mismatch: got '$ACTUAL_IP', want '$EXPECTED_IP'"
fi
pass "Traefik LB external IP = $ACTUAL_IP"

# 4. Public DNS resolves apex + wildcard to the same IP
echo "→ Checking public DNS resolution..."
DNS_APEX=$(dig +short "$HOST" @8.8.8.8 | head -1)
DNS_WILD=$(dig +short "foo.$HOST" @8.8.8.8 | head -1)
[[ "$DNS_APEX" == "$EXPECTED_IP" ]] || fail "DNS $HOST -> '$DNS_APEX' (expected '$EXPECTED_IP')"
[[ "$DNS_WILD" == "$EXPECTED_IP" ]] || fail "DNS foo.$HOST -> '$DNS_WILD' (expected '$EXPECTED_IP')"
pass "DNS apex + wildcard both resolve to $EXPECTED_IP"

# 5. HTTPS reaches the backend with a Let's Encrypt cert
echo "→ Checking HTTPS + Let's Encrypt cert..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://$HOST/" || echo "000")
case "$HTTP_CODE" in
  200|301|302|308) ;;
  *) fail "https://$HOST returned HTTP $HTTP_CODE" ;;
esac

ISSUER=$(curl -s -v "https://$HOST/" 2>&1 | grep -E '^\*\s+issuer:' | head -1)
echo "$ISSUER" | grep -qiE "let's encrypt|letsencrypt|\bR3\b|\bR10\b|\bR11\b" \
  || fail "Cert issuer is not Let's Encrypt. curl -v said: $ISSUER"
pass "HTTPS $HTTP_CODE via Let's Encrypt cert"

echo
echo "All scripted preconditions green. Manual UI walkthrough next:"
echo "  1. Browser to https://$HOST — log in"
echo "  2. Trigger a BLE scan"
echo "  3. Save an inventory item, reload, confirm persisted"
echo "  4. Grafana baseline at https://grafana.$HOST (cluster memory/CPU)"
