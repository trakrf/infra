# TRA-894 Grafana rename + Prometheus scoping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Grafana to `grafana.trakrf.id` (orange/edge-TLS) and stop prod Prometheus from discovering `trakrf-preview` targets.

**Architecture:** Mirror the `app.trakrf.id` orange pattern (CF proxied + Universal SSL edge + CF Origin CA cert origin) for Grafana, retiring the `.gke.` LE cert. Scope Prometheus discovery via `NotIn trakrf-preview` namespace selectors on the Prometheus CR.

**Tech Stack:** OpenTofu (Cloudflare provider), Helm (kube-prometheus-stack overrides), Traefik IngressRoute CRD, cert-manager Certificate CRD, emberstack/reflector, `just`.

**Validation note:** No unit-test harness for IaC. "Verify" = `tofu fmt -check` + `tofu validate` + `tofu plan`, `helm template`, and `kubectl apply --dry-run=client`. The live apply is operator-run post-merge (monitoring is Helm-bootstrapped, not Argo-synced); see spec "Manual apply steps".

---

### Task 1: Cloudflare DNS record for `grafana.trakrf.id`

**Files:**
- Modify: `terraform/cloudflare/main.tf` (append after `cloudflare_record.app`, ~line 35)

- [ ] **Step 1: Add the orange A record**

```hcl
# grafana.trakrf.id — internal ops Grafana on GKE, orange-clouded (TRA-894).
# Replaces the retired grafana.gke.trakrf.id (.gke. was a pre-ACM workaround).
# A → Traefik LB, CF-proxied: edge TLS via Universal SSL (single-label
# *.trakrf.id is covered — no ACM advanced cert needed) + WAF + DDoS. CF→origin
# leg (SSL strict) presents the CF Origin CA cert trakrf-id-origin-tls
# (SAN *.trakrf.id) at Traefik — same pattern as app.trakrf.id. No origin
# IP-lock yet (Grafana is internal/single-user); deferred hardening.
resource "cloudflare_record" "grafana" {
  zone_id = cloudflare_zone.domain.id
  name    = "grafana"
  content = var.gke_traefik_lb_ip
  type    = "A"
  proxied = true
  comment = "TRA-894 — Grafana orange origin via CF edge (Universal SSL + CF Origin CA cert)"
}
```

- [ ] **Step 2: Format + validate**

Run: `tofu -chdir=terraform/cloudflare fmt && tofu -chdir=terraform/cloudflare validate`
Expected: `Success! The configuration is valid.` (init may be required first; see Task 7 for the plan run.)

---

### Task 2: Grafana IngressRoute → orange origin cert; retire LE Certificate

**Files:**
- Modify: `helm/monitoring/manifests-gke/grafana-id-ingressroute.yaml`
- Delete: `helm/monitoring/manifests-gke/grafana-id-certificate.yaml`

- [ ] **Step 1: Rewrite the IngressRoute** (full new file contents)

```yaml
# Public ingress for Grafana at grafana.trakrf.id on GKE (TRA-894).
# Orange-clouded: Cloudflare owns edge TLS (Universal SSL, single-label
# *.trakrf.id) + WAF + DDoS. The CF→origin leg (SSL "strict") presents the
# CF Origin CA cert trakrf-id-origin-tls (origin-cert.tf: 15yr, SAN *.trakrf.id),
# reflected into the monitoring namespace by emberstack/reflector — same pattern
# as the app.trakrf.id route. NOT a Let's Encrypt cert (the retired
# grafana.gke.trakrf.id used LE via the Cloud DNS solver). Resource name kept as
# `grafana-id` to avoid a delete+recreate blip (monitoring is kubectl-applied,
# not Argo-synced).
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana-id
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: kube-prometheus-stack
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`grafana.trakrf.id`)
      kind: Rule
      middlewares:
        - name: default-chain
          namespace: traefik
      services:
        - name: kube-prometheus-stack-grafana
          port: 80
  tls:
    secretName: trakrf-id-origin-tls
```

- [ ] **Step 2: Delete the LE Certificate manifest**

Run: `git rm helm/monitoring/manifests-gke/grafana-id-certificate.yaml`
Expected: file staged for deletion.

- [ ] **Step 3: Dry-run render the IngressRoute** (schema sanity; no cluster mutation)

Run: `kubectl apply --dry-run=client -f helm/monitoring/manifests-gke/grafana-id-ingressroute.yaml -o name 2>&1 | head`
Expected: `ingressroute.traefik.io/grafana-id` (or an offline parse OK). If no cluster/CRD access, a `kubectl --dry-run=client` parse of the YAML still validates structure; a YAML lint is an acceptable fallback.

---

### Task 3: Grafana root URL → grafana.trakrf.id

**Files:**
- Modify: `helm/monitoring/values-gke.yaml:35-36`

- [ ] **Step 1: Update domain + root_url**

Replace:
```yaml
      domain: grafana.gke.trakrf.id
      root_url: https://grafana.gke.trakrf.id
```
with:
```yaml
      domain: grafana.trakrf.id
      root_url: https://grafana.trakrf.id
```

- [ ] **Step 2: Verify the only remaining `grafana.gke.trakrf.id` refs are intentional**

Run: `grep -rn "grafana.gke.trakrf.id" helm/ terraform/`
Expected: no matches (the cert file is deleted, values updated). Comments may mention the retired host historically — acceptable, but the live `domain`/`root_url`/`Host()` must all be `grafana.trakrf.id`.

---

### Task 4: Scope Prometheus discovery to exclude `trakrf-preview`

**Files:**
- Modify: `helm/monitoring/values-gke.yaml` (under `prometheus.prometheusSpec`)

- [ ] **Step 1: Add namespace selectors**

Inside the existing `prometheus.prometheusSpec:` block (alongside `storageSpec`/`tolerations`), add:

```yaml
    # TRA-894: prod + preview share this GKE cluster and one kube-prometheus-stack.
    # trakrf-backend/trakrf-ingester emit a ServiceMonitor into every env namespace,
    # so default cluster-wide discovery would scrape the intentionally-unmonitored
    # trakrf-preview targets. Restrict target discovery to every namespace EXCEPT
    # trakrf-preview (exclude-list is robust against future infra namespaces).
    # kubernetes.io/metadata.name is auto-set by k8s on every namespace (GA).
    serviceMonitorNamespaceSelector: &notPreview
      matchExpressions:
        - { key: kubernetes.io/metadata.name, operator: NotIn, values: [trakrf-preview] }
    podMonitorNamespaceSelector: *notPreview
    probeNamespaceSelector: *notPreview
    scrapeConfigNamespaceSelector: *notPreview
```

- [ ] **Step 2: YAML validity check**

Run: `kubectl create --dry-run=client -f /dev/stdin <<'EOF'` is overkill here; instead parse the values file:
`python3 -c "import yaml,sys; yaml.safe_load(open('helm/monitoring/values-gke.yaml')); print('ok')"`
Expected: `ok` (anchors/aliases resolve).

- [ ] **Step 3: Render the chart with the overlay** (confirms operator accepts the keys)

Run (best-effort; needs the repo chart pinned — see Task 7 note):
`helm template kps prometheus-community/kube-prometheus-stack -f helm/monitoring/values.yaml -f helm/monitoring/values-gke.yaml 2>/dev/null | grep -A6 "namespaceSelector" | head -20`
Expected: the Prometheus CR shows the `NotIn trakrf-preview` selectors. If the chart repo isn't added locally, skip — the keys are standard kube-prometheus-stack passthrough to the Prometheus CR.

---

### Task 5: Reflect the origin cert into the `monitoring` namespace

**Files:**
- Modify: `justfile` (the `origin-cert-secret` recipe, ~lines 56-58)

- [ ] **Step 1: Add `monitoring` to both reflector namespace annotations**

Replace:
```
          'reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=trakrf-preview,trakrf-prod' \
```
with:
```
          'reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=trakrf-preview,trakrf-prod,monitoring' \
```
and replace:
```
          'reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-preview,trakrf-prod' \
```
with:
```
          'reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=trakrf-preview,trakrf-prod,monitoring' \
```

- [ ] **Step 2: Update the recipe's trailing echo to mention monitoring**

Replace the final `echo` line:
```
    echo "trakrf-id-origin-tls applied in trakrf-system; reflector will mirror to trakrf-preview/trakrf-prod."
```
with:
```
    echo "trakrf-id-origin-tls applied in trakrf-system; reflector will mirror to trakrf-preview/trakrf-prod/monitoring."
```

- [ ] **Step 3: Lint the justfile**

Run: `just --summary >/dev/null && echo ok` (or `just --list >/dev/null`)
Expected: `ok` — no parse error.

---

### Task 6: Update README access reference

**Files:**
- Modify: `helm/monitoring/README.md:24`

- [ ] **Step 1: Point the Access section at the current prod host**

Replace:
```
Grafana is exposed publicly at <https://grafana.eks.trakrf.app> (TRA-386).
```
with:
```
Grafana is exposed publicly at <https://grafana.trakrf.id> on GKE prod
(TRA-894; orange-clouded via Cloudflare). The retired EKS host was
grafana.eks.trakrf.app.
```

---

### Task 7: Full validation + commit

- [ ] **Step 1: tofu fmt + validate + plan (Cloudflare)**

Run:
```
just _backend-conf terraform/cloudflare 2>/dev/null || true
tofu -chdir=terraform/cloudflare init -backend-config=backend.conf -input=false >/dev/null
tofu -chdir=terraform/cloudflare fmt -check
tofu -chdir=terraform/cloudflare validate
tofu -chdir=terraform/cloudflare plan
```
Expected: `validate` succeeds; `plan` shows exactly one add — `cloudflare_record.grafana` — and no unintended changes. If credentials/state are unavailable in this environment, capture `validate` + `fmt` success and note that `plan` is operator-run (report honestly — do not claim a plan you couldn't run).

- [ ] **Step 2: Confirm no stray live references to the old host**

Run: `grep -rn "grafana.gke.trakrf.id" helm/ terraform/ | grep -v "retired\|historically\|TRA-894"`
Expected: no matches.

- [ ] **Step 3: Commit**

```bash
git add terraform/cloudflare/main.tf helm/monitoring/manifests-gke/ \
        helm/monitoring/values-gke.yaml justfile helm/monitoring/README.md
git commit -m "feat(monitoring): grafana.trakrf.id orange rename + scope prod Prometheus off preview (TRA-894)"
```
