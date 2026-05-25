# TRA-829 — `gke.trakrf.id` DNS + cert-manager foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `gke.trakrf.id` as a Cloud DNS zone delegated from Cloudflare, extend the cert-manager Workload Identity SA to write it, refactor `helm/cert-manager-config` to support multiple zones/certs, and issue a `*.gke.trakrf.id` wildcard Cert as the acceptance test.

**Architecture:** Additive on top of the existing TRA-461 GKE Cloud DNS WI solver — one new managed zone, one zone-scoped IAM binding on the existing cert-manager SA, one new Cloudflare NS delegation block. The helm chart `cert-manager-config` is refactored from singular `cloudDNS.{hostedZoneName,dnsZoneName}` + singular `certificate.*` fields to `cloudDNS.zones` and `certificates` lists, so the ClusterIssuer renders N solver entries and N Certificates. AKS and EKS branches unchanged in behavior (lists with 1 entry).

**Tech Stack:** OpenTofu (Cloudflare + Google providers), Helm 3, ArgoCD Application templates, cert-manager v1, Let's Encrypt (Cloud DNS DNS-01 via GKE Workload Identity).

**Reference spec:** `docs/superpowers/specs/2026-05-25-tra-829-gke-trakrf-id-foundation-design.md`

---

## File Structure

**Modified — Terraform:**
- `terraform/gcp/dns.tf` — add `gke_trakrf_id` zone + apex/wildcard A records
- `terraform/gcp/cert_manager.tf` — add second zone-scoped IAM binding
- `terraform/gcp/outputs.tf` — add `dns_zone_name_id`, `dns_nameservers_id`, `cloud_dns_zone_name_id`
- `terraform/cloudflare/gcp-delegation.tf` — add `gke_subdomain_ns_id` NS delegation

**Modified — Helm chart (`helm/cert-manager-config/`):**
- `templates/clusterissuer.yaml` — `cloudDNS` branch `range`s over `cloudDNS.zones`
- `templates/certificate.yaml` — wrap body in `range .Values.certificates`, `---`-separated
- `values.yaml` — list-shape defaults
- `values-gke.yaml` — two zones, two certs
- `values-aks.yaml` — list-shape (1-cert list), singular `azureDNS` stays

**Modified — ArgoCD root chart:**
- `argocd/root/templates/cert-manager-config.yaml` — GKE branch emits `cloudDNS.zones` list (two entries)
- `argocd/root/values.yaml` — rename `cloudDnsZoneName` → `cloudDnsZoneNameApp`, add `cloudDnsZoneNameId: ""`

**Modified — scripts:**
- `scripts/apply-root-app.sh` — GKE branch reads two outputs, passes two `--set` flags

---

## Branch setup

- [ ] **Step 1: Create the feature branch**

Run:
```bash
git checkout main
git pull
git checkout -b miks2u/tra-829-gke-trakrf-id-foundation
```
Expected: branch created, clean working tree.

---

## Task 1: Terraform GCP — new Cloud DNS zone + IAM + outputs

**Files:**
- Modify: `terraform/gcp/dns.tf` (append after the existing `gke_wildcard` block)
- Modify: `terraform/gcp/cert_manager.tf` (append after `cert_manager_dns_admin`)
- Modify: `terraform/gcp/outputs.tf` (append after `cloud_dns_zone_name`)

- [ ] **Step 1: Add the managed zone and A records**

Append to `terraform/gcp/dns.tf`:

```hcl
# Public DNS zone for GKE-served `.id` hosts that need a GKE-issued public ACME
# cert — i.e. hosts that can't ride the Cloudflare edge cert. Two consumers
# queued behind this: the Mosquitto broker (TRA-828, device-facing) and the
# Grafana hostname move (browser-facing). Cloudflare delegates gke.trakrf.id
# here via terraform/cloudflare/gcp-delegation.tf.
resource "google_dns_managed_zone" "gke_trakrf_id" {
  name        = "gke-trakrf-id"
  dns_name    = "gke.trakrf.id."
  description = "Public DNS zone for GKE-issued-cert .id hosts (TRA-829)"

  labels = local.common_labels

  # Mirrors the prevent_destroy pattern on gke_trakrf_app and on the Route53/
  # Azure zones — GCP assigns random nameservers at create time, so destroying
  # the zone forces CF NS rotation on every rebuild.
  lifecycle {
    prevent_destroy = true
  }
}

# Apex A record: gke.trakrf.id -> static Traefik LB IP. Future Traefik-routed
# .id hosts (Grafana first) resolve here via the wildcard below; the broker
# (TRA-828) uses its own host-specific A record on its own LB IP.
resource "google_dns_record_set" "gke_id_apex" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = google_dns_managed_zone.gke_trakrf_id.dns_name # "gke.trakrf.id."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.traefik.address]
}

# Wildcard A record: *.gke.trakrf.id -> same IP. Traefik IngressRoute hostname
# matching handles per-subdomain routing server-side.
resource "google_dns_record_set" "gke_id_wildcard" {
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  name         = "*.${google_dns_managed_zone.gke_trakrf_id.dns_name}" # "*.gke.trakrf.id."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.traefik.address]
}
```

- [ ] **Step 2: Add the second zone-scoped IAM binding**

Append to `terraform/gcp/cert_manager.tf`:

```hcl
# Second zone-scoped binding for the gke.trakrf.id zone (TRA-829). Same SA,
# same role, distinct zone — keeps blast radius tight (no project-level grant).
# The Workload Identity binding above is reused; one SA, two zone bindings.
resource "google_dns_managed_zone_iam_member" "cert_manager_dns_admin_id" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.gke_trakrf_id.name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${google_service_account.cert_manager.email}"
}
```

- [ ] **Step 3: Add the three outputs**

Append to `terraform/gcp/outputs.tf`:

```hcl
# TRA-829 — gke.trakrf.id zone outputs (parallel to dns_zone_name / dns_nameservers /
# cloud_dns_zone_name above for gke.trakrf.app).

output "dns_zone_name_id" {
  description = "Cloud DNS zone DNS name for gke.trakrf.id (trailing dot stripped)"
  value       = trimsuffix(google_dns_managed_zone.gke_trakrf_id.dns_name, ".")
}

output "dns_nameservers_id" {
  description = "Cloud DNS nameservers for gke.trakrf.id — consumed by Cloudflare for NS delegation"
  value       = google_dns_managed_zone.gke_trakrf_id.name_servers
}

output "cloud_dns_zone_name_id" {
  description = "Cloud DNS managed-zone resource name for gke.trakrf.id. Consumed by cert-manager cloudDNS solver."
  value       = google_dns_managed_zone.gke_trakrf_id.name
}
```

- [ ] **Step 4: tofu plan and verify expected diff**

Run:
```bash
tofu -chdir=terraform/gcp init -upgrade
tofu -chdir=terraform/gcp plan
```
Expected (5 resources to add):
- `google_dns_managed_zone.gke_trakrf_id`
- `google_dns_record_set.gke_id_apex`
- `google_dns_record_set.gke_id_wildcard`
- `google_dns_managed_zone_iam_member.cert_manager_dns_admin_id`
- (3 new outputs visible in the plan summary)

No deletions, no replacements, no `prevent_destroy` violations. If the plan shows anything else, stop and investigate.

- [ ] **Step 5: tofu apply**

Run:
```bash
tofu -chdir=terraform/gcp apply
```
Confirm with `yes` after re-reading the plan.

Verify nameservers were assigned:
```bash
tofu -chdir=terraform/gcp output dns_nameservers_id
```
Expected: 4 `ns-cloud-*.googledomains.com.` entries.

- [ ] **Step 6: Commit**

```bash
git add terraform/gcp/dns.tf terraform/gcp/cert_manager.tf terraform/gcp/outputs.tf
git commit -m "feat(tra-829): add gke.trakrf.id Cloud DNS zone + cert-manager IAM"
```

---

## Task 2: Terraform Cloudflare — NS delegation

**Files:**
- Modify: `terraform/cloudflare/gcp-delegation.tf` (append after existing `gke_subdomain_ns` block)

- [ ] **Step 1: Append the second delegation block**

Append to `terraform/cloudflare/gcp-delegation.tf`:

```hcl
# Create NS records in Cloudflare to delegate gke.trakrf.id to Cloud DNS.
# Delegation lives on the trakrf.id zone (cloudflare_zone.domain), distinct
# from the .app delegation above on cloudflare_zone.trakrf_app. Mirrors the
# aws-delegation.tf pattern (also on .domain).
resource "cloudflare_record" "gke_subdomain_ns_id" {
  count = length(data.terraform_remote_state.gcp.outputs.dns_nameservers_id)

  zone_id = cloudflare_zone.domain.id
  name    = "gke"
  type    = "NS"
  content = data.terraform_remote_state.gcp.outputs.dns_nameservers_id[count.index]
  ttl     = 3600

  comment = "Delegate gke.trakrf.id to GCP Cloud DNS"
}
```

- [ ] **Step 2: tofu plan**

Run:
```bash
tofu -chdir=terraform/cloudflare plan
```
Expected: 4 `cloudflare_record.gke_subdomain_ns_id[N]` resources to add (one per nameserver). No other changes.

If the plan shows `Read complete after Xs` for `data.terraform_remote_state.gcp` followed by 4 adds, you're good. If it errors with `output dns_nameservers_id not found`, Task 1 step 5 wasn't applied — go back.

- [ ] **Step 3: tofu apply**

Run:
```bash
tofu -chdir=terraform/cloudflare apply
```
Confirm with `yes`.

- [ ] **Step 4: Verify public NS resolution**

Run (may take 1–2 minutes for CF edge propagation):
```bash
dig +trace NS gke.trakrf.id
```
Expected: trace ends with the 4 `ns-cloud-*.googledomains.com.` nameservers (not Cloudflare's). If the trace still ends at Cloudflare's nameservers, wait 60s and retry. Do NOT proceed until this returns Cloud DNS.

Smoke-test the A records resolve via the new chain:
```bash
dig +short A gke.trakrf.id @ns-cloud-a1.googledomains.com
dig +short A test.gke.trakrf.id @ns-cloud-a1.googledomains.com
```
Expected: both return the Traefik LB IP.

- [ ] **Step 5: Commit**

```bash
git add terraform/cloudflare/gcp-delegation.tf
git commit -m "feat(tra-829): delegate gke.trakrf.id to GCP Cloud DNS"
```

---

## Task 3: Helm chart — values restructure

**Files:**
- Modify: `helm/cert-manager-config/values.yaml`
- Modify: `helm/cert-manager-config/values-gke.yaml`
- Modify: `helm/cert-manager-config/values-aks.yaml`

Doing values first, templates next — the chart will be temporarily inconsistent between these two tasks, but no consumer reads it until Task 5 runs the apply script. Don't deploy mid-task.

- [ ] **Step 1: Rewrite `helm/cert-manager-config/values.yaml`**

Replace the entire file contents with:

```yaml
# Common ACME config — cluster-specific solver and SANs go in values-<cluster>.yaml

acme:
  email: admin@trakrf.id
  server: https://acme-v02.api.letsencrypt.org/directory
  privateKeySecretRef: letsencrypt-prod-account-key

issuer:
  name: letsencrypt-prod

# Solver type: "cloudflare", "azureDNS", or "cloudDNS" — overridden per cluster
solver: ""

# Certificates — overridden per cluster. List shape so a single chart instance
# can render multiple Certificates (e.g. one per managed zone on GKE).
certificates: []
```

The singular `certificate:` block is removed. Default `certificates: []` means a cluster overlay that forgets to set this renders zero Certificates — safe.

- [ ] **Step 2: Rewrite `helm/cert-manager-config/values-gke.yaml`**

Replace the entire file contents with:

```yaml
# GKE uses the Cloud DNS solver via GKE Workload Identity.
# Real values for cloudDNS.project + cloudDNS.zones[*].hostedZoneName come from
# scripts/apply-root-app.sh (tofu outputs) injected into the root-app
# Application's inline helm.values at install time. The placeholders below
# are docs only.

solver: cloudDNS

cloudDNS:
  # Injected at install time — GCP project ID.
  project: REPLACE_ME
  # Injected at install time — one entry per zone. hostedZoneName is the Cloud
  # DNS managed-zone RESOURCE NAME (e.g. "gke-trakrf-app"), not the DNS name.
  # dnsZoneName is the DNS name used in the ClusterIssuer solver selector.
  zones:
    - hostedZoneName: REPLACE_ME_APP
      dnsZoneName: gke.trakrf.app
    - hostedZoneName: REPLACE_ME_ID
      dnsZoneName: gke.trakrf.id

certificates:
  # Name kept as-is to avoid a destructive rename (cert-manager doesn't follow
  # renames — it deletes and re-issues, leaving a momentary Secret gap).
  # Asymmetric vs the new .id entry, but the cost of renaming outweighs the
  # cosmetic symmetry.
  - name: trakrf-gke-wildcard
    namespace: cert-manager
    secretName: trakrf-gke-wildcard-tls
    commonName: gke.trakrf.app
    dnsNames:
      - gke.trakrf.app
      - "*.gke.trakrf.app"
  - name: trakrf-gke-id-wildcard
    namespace: cert-manager
    secretName: trakrf-gke-id-wildcard-tls
    commonName: gke.trakrf.id
    dnsNames:
      - gke.trakrf.id
      - "*.gke.trakrf.id"
```

- [ ] **Step 3: Rewrite `helm/cert-manager-config/values-aks.yaml`**

Replace the entire file contents with:

```yaml
# AKS uses Azure DNS solver via workload identity.
# Real values come from scripts/apply-root-app.sh (tofu outputs) injected
# into the root-app Application's inline helm.values at install time.
# The placeholders below are docs only.

solver: azureDNS

azureDNS:
  hostedZoneName: aks.trakrf.app
  resourceGroupName: REPLACE_ME
  subscriptionID: REPLACE_ME
  managedIdentity:
    clientID: REPLACE_ME

certificates:
  - name: trakrf-aks-wildcard
    namespace: cert-manager
    secretName: trakrf-aks-wildcard-tls
    commonName: aks.trakrf.app
    dnsNames:
      - aks.trakrf.app
      - "*.aks.trakrf.app"
```

Note: AKS gets `secretName: trakrf-aks-wildcard-tls` added explicitly (was missing in the old singular shape because the chart's `certificate.yaml` template referenced `.Values.certificate.secretName` from `values.yaml` default `trakrf-wildcard-tls` — which was wrong for AKS but never noticed because nothing consumed it by name there). Setting it explicitly here is correct and harmless.

- [ ] **Step 4: Commit**

```bash
git add helm/cert-manager-config/values.yaml helm/cert-manager-config/values-gke.yaml helm/cert-manager-config/values-aks.yaml
git commit -m "feat(tra-829): cert-manager-config values use certificates + cloudDNS.zones lists"
```

---

## Task 4: Helm chart — template refactor

**Files:**
- Modify: `helm/cert-manager-config/templates/clusterissuer.yaml`
- Modify: `helm/cert-manager-config/templates/certificate.yaml`

- [ ] **Step 1: Rewrite `clusterissuer.yaml` cloudDNS branch as a range**

Replace the entire file with:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: {{ .Values.issuer.name }}
spec:
  acme:
    server: {{ .Values.acme.server }}
    email: {{ .Values.acme.email }}
    privateKeySecretRef:
      name: {{ .Values.acme.privateKeySecretRef }}
    solvers:
      {{- if eq .Values.solver "cloudflare" }}
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: {{ .Values.cloudflare.apiTokenSecretName }}
              key: {{ .Values.cloudflare.apiTokenSecretKey }}
        selector:
          dnsZones:
            {{- range .Values.cloudflare.zones }}
            - {{ . }}
            {{- end }}
      {{- else if eq .Values.solver "azureDNS" }}
      # Workload-identity auth: only managedIdentity.clientID in the auth section.
      # cert-manager's webhook rejects the schema if top-level tenantID/clientID/
      # clientSecretSecretRef appear alongside managedIdentity.
      - dns01:
          azureDNS:
            hostedZoneName: {{ .Values.azureDNS.hostedZoneName }}
            resourceGroupName: {{ .Values.azureDNS.resourceGroupName }}
            subscriptionID: {{ .Values.azureDNS.subscriptionID }}
            managedIdentity:
              clientID: {{ .Values.azureDNS.managedIdentity.clientID }}
        selector:
          dnsZones:
            - {{ .Values.azureDNS.hostedZoneName }}
      {{- else if eq .Values.solver "cloudDNS" }}
      # GKE Workload Identity — no token/secret in spec; cert-manager pod SA
      # is annotated with iam.gke.io/gcp-service-account (set by
      # argocd/root/templates/cert-manager.yaml).
      # Each entry in cloudDNS.zones renders one solver block. hostedZoneName
      # is the Cloud DNS managed-zone RESOURCE NAME (e.g. "gke-trakrf-app"),
      # dnsZoneName is the DNS name used in the selector.
      {{- range .Values.cloudDNS.zones }}
      - dns01:
          cloudDNS:
            project: {{ $.Values.cloudDNS.project }}
            hostedZoneName: {{ .hostedZoneName }}
        selector:
          dnsZones:
            - {{ .dnsZoneName }}
      {{- end }}
      {{- else }}
      {{- fail (printf "Unknown solver type: %q (expected 'cloudflare', 'azureDNS', or 'cloudDNS')" .Values.solver) }}
      {{- end }}
```

Note: inside the `range`, use `$.Values` (the dollar) to reach back to the root context — `.Values.cloudDNS.project` would resolve against the loop variable and fail.

- [ ] **Step 2: Rewrite `certificate.yaml` as a range**

Replace the entire file with:

```yaml
{{- range .Values.certificates }}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
spec:
  secretName: {{ .secretName }}
  issuerRef:
    name: {{ $.Values.issuer.name }}
    kind: ClusterIssuer
  commonName: {{ .commonName }}
  dnsNames:
    {{- range .dnsNames }}
    - {{ . | quote }}
    {{- end }}
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
{{- end }}
```

Same `$.Values.issuer.name` pattern to reach root context from inside the range.

- [ ] **Step 3: Verify the chart renders cleanly for GKE**

Run:
```bash
helm template cert-manager-config helm/cert-manager-config \
  -f helm/cert-manager-config/values.yaml \
  -f helm/cert-manager-config/values-gke.yaml \
  --set cloudDNS.project=test-project \
  --set cloudDNS.zones[0].hostedZoneName=gke-trakrf-app \
  --set cloudDNS.zones[0].dnsZoneName=gke.trakrf.app \
  --set cloudDNS.zones[1].hostedZoneName=gke-trakrf-id \
  --set cloudDNS.zones[1].dnsZoneName=gke.trakrf.id
```
Expected output contains:
- One `ClusterIssuer letsencrypt-prod` with TWO `dns01.cloudDNS` solver entries
- Two `Certificate` resources: `trakrf-gke-wildcard` and `trakrf-gke-id-wildcard`
- Each Certificate has the correct `dnsNames` SAN list

If the output shows `<no value>` anywhere or only one solver/cert, stop and check the template.

- [ ] **Step 4: Verify AKS still renders**

Run:
```bash
helm template cert-manager-config helm/cert-manager-config \
  -f helm/cert-manager-config/values.yaml \
  -f helm/cert-manager-config/values-aks.yaml \
  --set azureDNS.resourceGroupName=test-rg \
  --set azureDNS.subscriptionID=00000000-0000-0000-0000-000000000000 \
  --set azureDNS.managedIdentity.clientID=00000000-0000-0000-0000-000000000000
```
Expected: One `ClusterIssuer` with one `azureDNS` solver, one `Certificate trakrf-aks-wildcard` with `aks.trakrf.app` + `*.aks.trakrf.app` SAN.

- [ ] **Step 5: Commit**

```bash
git add helm/cert-manager-config/templates/clusterissuer.yaml helm/cert-manager-config/templates/certificate.yaml
git commit -m "feat(tra-829): cert-manager-config templates iterate over zones + certificates"
```

---

## Task 5: ArgoCD root chart + apply script

**Files:**
- Modify: `argocd/root/templates/cert-manager-config.yaml`
- Modify: `argocd/root/values.yaml`
- Modify: `scripts/apply-root-app.sh`

- [ ] **Step 1: Update `argocd/root/templates/cert-manager-config.yaml`**

Replace the GKE branch's `printf` block. Replace:

```yaml
{{- else if eq .Values.cluster "gke" -}}
{{- /* Cloud DNS solver via GKE Workload Identity — no secret/token in spec;
       the K8s SA annotation (argocd/root/templates/cert-manager.yaml) does auth.
       hostedZoneName is the Cloud DNS managed-zone RESOURCE NAME, not DNS name. */ -}}
{{- $inlineValues = printf "cloudDNS:\n  project: %s\n  hostedZoneName: %s\n"
    .Values.gcpProjectId
    .Values.cloudDnsZoneName
-}}
```

With:

```yaml
{{- else if eq .Values.cluster "gke" -}}
{{- /* Cloud DNS solver via GKE Workload Identity — no secret/token in spec;
       the K8s SA annotation (argocd/root/templates/cert-manager.yaml) does auth.
       hostedZoneName values are Cloud DNS managed-zone RESOURCE NAMES, not DNS
       names. One entry per managed zone (TRA-829 added .id alongside .app). */ -}}
{{- $inlineValues = printf "cloudDNS:\n  project: %s\n  zones:\n    - hostedZoneName: %s\n      dnsZoneName: gke.trakrf.app\n    - hostedZoneName: %s\n      dnsZoneName: gke.trakrf.id\n"
    .Values.gcpProjectId
    .Values.cloudDnsZoneNameApp
    .Values.cloudDnsZoneNameId
-}}
```

The AKS branch and the `include "trakrf.application"` block stay unchanged.

- [ ] **Step 2: Update `argocd/root/values.yaml`**

Edit the GKE placeholders block. Replace:

```yaml
# GKE tofu output placeholders (populated by scripts/apply-root-app.sh at install time)
gcpProjectId: ""
certManagerGcpServiceAccountEmail: ""
cloudDnsZoneName: ""
```

With:

```yaml
# GKE tofu output placeholders (populated by scripts/apply-root-app.sh at install time)
gcpProjectId: ""
certManagerGcpServiceAccountEmail: ""
cloudDnsZoneNameApp: ""
cloudDnsZoneNameId: ""
```

- [ ] **Step 3: Update `scripts/apply-root-app.sh` — GKE branch reads two outputs**

In the `gke)` case of the `case "$CLUSTER" in` block, replace:

```bash
    GCP_DNS_ZONE_NAME=$(tofu -chdir="$TF_DIR" output -raw cloud_dns_zone_name)
```

With:

```bash
    GCP_DNS_ZONE_NAME_APP=$(tofu -chdir="$TF_DIR" output -raw cloud_dns_zone_name)
    GCP_DNS_ZONE_NAME_ID=$(tofu  -chdir="$TF_DIR" output -raw cloud_dns_zone_name_id)
```

- [ ] **Step 4: Update other branches' blanks**

In the `aks)`, `eks)`, and default `*)` cases, replace:

```bash
    GCP_DNS_ZONE_NAME=""
```

With:

```bash
    GCP_DNS_ZONE_NAME_APP=""
    GCP_DNS_ZONE_NAME_ID=""
```

(Three occurrences total — one per case.)

- [ ] **Step 5: Update the `helm upgrade --install` invocation**

Replace the line:

```bash
  --set cloudDnsZoneName="$GCP_DNS_ZONE_NAME" \
```

With:

```bash
  --set cloudDnsZoneNameApp="$GCP_DNS_ZONE_NAME_APP" \
  --set cloudDnsZoneNameId="$GCP_DNS_ZONE_NAME_ID" \
```

- [ ] **Step 6: Dry-run the helm template the root chart will produce**

Run:
```bash
helm template trakrf-root argocd/root \
  -f argocd/root/values.yaml \
  --set cluster=gke \
  --set gcpProjectId=test-project \
  --set cloudDnsZoneNameApp=gke-trakrf-app \
  --set cloudDnsZoneNameId=gke-trakrf-id \
  --set traefikLbIp=10.0.0.1 \
  --set certManagerGcpServiceAccountEmail=test@example.iam.gserviceaccount.com
```
Expected output contains a `cert-manager-config` Application whose `helm.values` block has:
```yaml
cloudDNS:
  project: test-project
  zones:
    - hostedZoneName: gke-trakrf-app
      dnsZoneName: gke.trakrf.app
    - hostedZoneName: gke-trakrf-id
      dnsZoneName: gke.trakrf.id
```

If the indentation is wrong (cert-manager will reject the values), it'll show here.

- [ ] **Step 7: Commit**

```bash
git add argocd/root/templates/cert-manager-config.yaml argocd/root/values.yaml scripts/apply-root-app.sh
git commit -m "feat(tra-829): root chart + apply-root-app.sh wire two cloudDNS zones"
```

---

## Task 6: Deploy + acceptance verification

This task runs against the live GKE cluster. Ensure your kubeconfig points at the right cluster before starting:

```bash
kubectl config current-context
# expected: gke_<project>_<zone>_<cluster> matching the GKE TRA-461 cluster
```

- [ ] **Step 1: Apply the updated root chart**

Run:
```bash
scripts/apply-root-app.sh gke
```
Expected output: `Root app installed.` with no helm errors. The cert-manager-config Application annotation/values now include the new zone.

- [ ] **Step 2: Watch the cert-manager-config Application reconcile**

Run (Ctrl+C when it goes Healthy + Synced):
```bash
kubectl -n argocd get application cert-manager-config -w
```
Expected: status transitions to `Synced` / `Healthy`. If it stays `OutOfSync`, force a refresh:
```bash
kubectl -n argocd patch application cert-manager-config --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

- [ ] **Step 3: Verify ClusterIssuer has two solver entries**

Run:
```bash
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.spec.acme.solvers}' | jq
```
Expected: a JSON array of length 2. Each entry has a `dns01.cloudDNS` block and a `selector.dnsZones` of `["gke.trakrf.app"]` and `["gke.trakrf.id"]` respectively.

- [ ] **Step 4: Watch the Certificates issue**

Run:
```bash
kubectl -n cert-manager get certificate -w
```
Expected within 1–3 minutes: both `trakrf-gke-wildcard` and `trakrf-gke-id-wildcard` show `READY=True`. The `.app` cert may or may not re-issue (it's already healthy); the `.id` cert is brand-new and runs a fresh DNS-01 challenge against the new zone.

If `READY=False` persists past 5 minutes for the `.id` cert, investigate:
```bash
kubectl -n cert-manager describe certificate trakrf-gke-id-wildcard
kubectl -n cert-manager get challenges
kubectl -n cert-manager get order
```
Common failures: DNS still propagating (re-check `dig +trace NS gke.trakrf.id` resolves to Cloud DNS), missing IAM binding on the new zone (Task 1 step 2), solver selector mismatch (Task 4 step 1).

- [ ] **Step 5: Verify the issued cert covers both SANs**

Run:
```bash
kubectl -n cert-manager get secret trakrf-gke-id-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -subject -issuer -ext subjectAltName
```
Expected:
- `subject=CN = gke.trakrf.id`
- `issuer=C = US, O = Let's Encrypt, CN = R10` (or `R11`)
- `X509v3 Subject Alternative Name:` line containing `DNS:gke.trakrf.id, DNS:*.gke.trakrf.id`

- [ ] **Step 6: Public DNS smoke test**

Run:
```bash
dig +short A gke.trakrf.id
dig +short A test.gke.trakrf.id
```
Both expected: the Traefik LB IP from `tofu -chdir=terraform/gcp output -raw traefik_lb_ip`.

- [ ] **Step 7: Nothing to commit (deploy artifacts are runtime state)**

If you needed to tweak any file during this task (unlikely), make those edits, commit them, and re-run the apply script. Otherwise skip ahead to Task 7.

---

## Task 7: Open PR

- [ ] **Step 1: Push the branch**

Run:
```bash
git push -u origin miks2u/tra-829-gke-trakrf-id-foundation
```

- [ ] **Step 2: Open the PR**

Run:
```bash
gh pr create --title "feat(tra-829): gke.trakrf.id DNS + cert-manager foundation" --body "$(cat <<'EOF'
## Summary
- Add Cloud DNS managed zone `gke.trakrf.id` (apex + wildcard A → existing Traefik LB IP), zone-scoped IAM binding on the existing cert-manager Workload Identity SA, and a Cloudflare NS delegation block on `trakrf.id`.
- Refactor `helm/cert-manager-config` from singular `cloudDNS.{hostedZoneName,dnsZoneName}` + singular `certificate.*` fields to `cloudDNS.zones` and `certificates` lists. ClusterIssuer renders N solver entries; Certificate template renders N Certs.
- Wire two `--set` flags through `scripts/apply-root-app.sh` and the root chart so both `.app` and `.id` zones populate from tofu outputs.

Acceptance: `kubectl -n cert-manager get certificate` shows both `trakrf-gke-wildcard` and `trakrf-gke-id-wildcard` `READY=True`; the `.id` wildcard cert's SAN list contains `gke.trakrf.id` and `*.gke.trakrf.id`.

Foundation for TRA-828 (Mosquitto broker) and the Grafana hostname move. No real consumer in this PR — broker uses its own host-specific Cert; Grafana will consume the wildcard Secret via its own IngressRoute.

## Test plan
- [x] `tofu -chdir=terraform/gcp plan` shows 5 adds (zone + 2 A + IAM binding + outputs), no deletions
- [x] `tofu -chdir=terraform/cloudflare plan` shows 4 NS adds, no other changes
- [x] `dig +trace NS gke.trakrf.id` resolves to Cloud DNS (not Cloudflare)
- [x] `helm template` for both GKE and AKS overlays renders cleanly with the new list shape
- [x] Both wildcard Certificates `READY=True` post-deploy
- [x] `openssl x509` on the `.id` Secret shows the expected SAN list

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Paste it into the conversation for the user.

---

## Self-Review

**Spec coverage:**
- Decision section → Tasks 1–5 implement the full chart + IaC refactor; Task 6 verifies the acceptance criteria
- DNS architecture diagram → Task 1 (GCP zone + IAM), Task 2 (CF delegation), Task 4/5 (chart + root templates)
- Component changes (every bullet in the spec's "Component changes" section) → mapped one-to-one to a step in Tasks 1, 3, 4, or 5
- Apply ordering (load-bearing) → Tasks 1 → 2 → (3+4) → 5 → 6 enforce the sequence: GCP apply, CF apply, DNS resolution check, chart updates, scripts apply, ArgoCD reconcile, cert issuance
- Acceptance section → Task 6 steps 4, 5, and 6 run the exact commands from the spec's Acceptance section
- Rollback → not a task; documented in the spec for runtime use if needed
- Constraints (DNS resolution before issuance, no rename, etc.) → enforced by Task 2 step 4 (`dig +trace` gate) and Task 3 step 2 comments

**Placeholder scan:** No "TBD", "TODO", or "add appropriate X" — every step has the actual code or command. The `REPLACE_ME*` strings in `values-gke.yaml` are documented placeholders the apply script overwrites at install time, not plan placeholders.

**Type/name consistency:**
- Output names: `cloud_dns_zone_name_id` consistent in Task 1 (defined), Task 2 (not used), Task 5 step 3 (consumed via `tofu output -raw`)
- Output `dns_nameservers_id`: defined Task 1 step 3, consumed Task 2 step 1
- Helm value paths: `cloudDNS.zones[*].{hostedZoneName,dnsZoneName}` and `certificates[*].{name,namespace,secretName,commonName,dnsNames}` consistent across Tasks 3, 4, 5
- Secret names: `trakrf-gke-wildcard-tls` (existing, preserved) and `trakrf-gke-id-wildcard-tls` (new) used consistently
- Root chart values: `cloudDnsZoneNameApp` / `cloudDnsZoneNameId` consistent in Tasks 5 steps 1, 2, 3, 4, 5, 6
- ClusterIssuer name `letsencrypt-prod` matches across template and Task 6 verification command
