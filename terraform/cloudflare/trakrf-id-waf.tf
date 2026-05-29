# WAF — Cloudflare on the trakrf.id zone for the orange-clouded preview API
# (TRA-856). Two rulesets:
#   1. Managed Free Ruleset (OWASP-style: SQLi/XSS/…) — block/log, always on.
#   2. Action-scoped challenge-skip on the public API/spec paths.
# Mirrors the trakrf.app pattern (trakrf-app.tf, TRA-381).

# 1. Managed WAF — block/log layer the orange-cloud stance calls for. These
#    rules block or log malformed/malicious requests; they do NOT issue
#    interactive challenges, so they're safe for non-browser API clients.
resource "cloudflare_ruleset" "trakrf_id_managed_waf" {
  zone_id     = cloudflare_zone.domain.id
  name        = "Managed WAF entrypoint"
  description = "Executes Cloudflare Free Managed Ruleset on trakrf.id traffic"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules {
    action      = "execute"
    description = "Free Managed Ruleset"
    expression  = "true"
    enabled     = true
    action_parameters {
      id = "77454fe2d30c4220b5701f6fdfb893ba"
    }
  }

  # Leg 3 ("managed-ruleset Challenge-action rules → override Challenge->Block on
  # /api/*") is N/A by enumeration: the enabled Free Managed Ruleset
  # (77454fe2d30c4220b5701f6fdfb893ba) was queried at design time and has 26
  # rules, ZERO with a challenge/managed_challenge/js_challenge action — they
  # block/log only. So there is no challenge to override and no scoped second
  # execute rule is added (avoids two-execute precedence risk for a class that
  # doesn't exist here). APPLY-TIME RE-CHECK: re-enumerate this ruleset and
  # assert challenge-action count is still 0; if Cloudflare ever adds a
  # challenge-action rule, add the override then as a SINGLE execute with a
  # scoped override expression (not stacked executes).
}

# 2. Challenge-skip on the public API + OpenAPI spec paths.
#
# CORRECTNESS, not a bot-fight workaround: an interactive (JS/managed) challenge
# on a pure-API path is ALWAYS a defect — the clients that hit /api/* (the docs
# build's redocusaurus fetch, integrator codegen, curl, SDKs) are non-browser by
# construction and can NEVER solve a challenge. There is no "retry in a browser"
# for an API consumer. So we skip the CHALLENGE triggers on these paths only:
#   - products ["securityLevel"]: the reputation-based challenge from
#     security_level=medium (fires for flagged IPs — shared cloud egress, VPNs,
#     CI runners — independent of Bot Fight Mode; a good-reputation probe would
#     never surface this).
#   - phases ["http_request_sbfm"]: the (Super) Bot Fight Mode phase.
# Managed WAF (ruleset above) is NOT skipped — block/log stays fully active; a
# malformed-request block is correct behavior. Bot Fight Mode also confirmed OFF
# in the cutover runbook as belt-and-suspenders.
#
# Scope is exactly the canonical /api/openapi.* + /api/v1/* surface plus the two
# ROOT aliases /openapi.{json,yaml} (router.go registers these at root; they 301
# to /api/openapi.*, but a header-less GET hits the edge before the redirect).
#
# NOTE: the exact skip product/phase keys are verified against the live zone at
# apply time (cannot dry-run the skip without ACM + the orange flip in place).
resource "cloudflare_ruleset" "trakrf_id_api_challenge_skip" {
  zone_id     = cloudflare_zone.domain.id
  name        = "Skip interactive challenge on public API/spec"
  description = "Non-browser API clients cannot answer challenges — never challenge /api/* or /openapi.*"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "skip"
    description = "app.preview.trakrf.id: /api/* and root /openapi.* are non-interactive"
    expression  = "(http.host eq \"app.preview.trakrf.id\" and (starts_with(http.request.uri.path, \"/api/\") or http.request.uri.path in {\"/openapi.json\" \"/openapi.yaml\"}))"
    enabled     = true
    action_parameters {
      products = ["securityLevel"]
      phases   = ["http_request_sbfm"]
    }
    logging {
      enabled = true
    }
  }
}
