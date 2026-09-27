#!/usr/bin/env bash
# Asserts the trakrf-backend IngressRoute never publishes /metrics. The backend
# serves Prometheus metrics on the same router as the API; Prometheus scrapes the
# Service in-cluster, so the public host must not route that path.
# Run: ./scripts/test-backend-ingress.sh
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

for k in eks aks gke; do
  [ -f "helm/trakrf-backend/values-$k.yaml" ] || continue
  out="$(helm template helm/trakrf-backend \
    -f helm/trakrf-backend/values.yaml -f "helm/trakrf-backend/values-$k.yaml" \
    --set ingress.enabled=true \
    --set 'ingress.routes[0].name=public' \
    --set 'ingress.routes[0].host=app.example.test' \
    --set 'ingress.routes[0].secretName=app-example-test-tls' 2>&1)" || { bad "$k: helm template failed: $out"; continue; }

  matches="$(printf '%s\n' "$out" | grep -E '^\s*- match:')"
  if [ -z "$matches" ]; then
    bad "$k: no IngressRoute match rendered"
    continue
  fi
  if printf '%s\n' "$matches" | grep -v -q '!Path(`/metrics`)'; then
    bad "$k: an IngressRoute match routes /metrics publicly: $(printf '%s' "$matches" | tr -s ' ')"
  else
    ok "$k: every IngressRoute match excludes /metrics"
  fi
  if printf '%s\n' "$matches" | grep -q 'Host(`app.example.test`)'; then
    ok "$k: host still matched"
  else
    bad "$k: host missing from match"
  fi
done

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
