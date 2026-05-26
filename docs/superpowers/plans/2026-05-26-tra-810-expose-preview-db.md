# TRA-810 — Expose preview CNPG primary for external psql — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the preview CNPG primary reachable over the public internet from a single allowlisted source CIDR (the breakglass home `/32`) so the platform Claude Code instance can iterate on the M3 FDW pull-migration with direct psql access. Preview-only, GKE-only.

**Architecture:** Tofu provisions one static EXTERNAL regional IP and one Cloud DNS A record. The trakrf-db helm chart gains an external LoadBalancer Service template gated on `externalPreview.enabled`; the root chart enables it on GKE and wires the IP + sourceRanges from the apply script (which reads the new tofu output and reuses the existing breakglass CIDR resolution).

**Reference spec:** `docs/superpowers/specs/2026-05-26-tra-810-expose-preview-db-design.md`

---

## File Structure

**New — Terraform:**
- `terraform/gcp/db.tf` — `google_compute_address.db_preview`.

**Modified — Terraform:**
- `terraform/gcp/dns.tf` — `google_dns_record_set.db_preview` A record under `gke.trakrf.id`.
- `terraform/gcp/outputs.tf` — `db_preview_ip` output.

**New — Helm:**
- `helm/trakrf-db/templates/external-service-preview.yaml` — Service type=LoadBalancer.

**Modified — Helm:**
- `helm/trakrf-db/values.yaml` — `externalPreview.{enabled,loadBalancerIP,sourceRanges}` defaults (all empty/false).

**Modified — Root chart:**
- `argocd/root/values.yaml` — `dbPreviewIp` placeholder.
- `argocd/root/templates/trakrf-db.yaml` — pass `externalPreview` inlineValues on GKE.

**Modified — Scripts:**
- `scripts/apply-root-app.sh` — read `db_preview_ip` output, pass `--set dbPreviewIp` to helm.

**New — Docs:**
- `docs/superpowers/specs/2026-05-26-tra-810-expose-preview-db-design.md`.
- `docs/superpowers/plans/2026-05-26-tra-810-expose-preview-db.md` (this file).

---

## Task 1: Tofu — static IP, DNS A, output

- [ ] **Step 1:** Add `google_compute_address.db_preview` to a new `terraform/gcp/db.tf`. Mirror `mqtt_preview`: regional EXTERNAL, PREMIUM tier, `prevent_destroy = true`, `name = "db-preview-${local.name_prefix}"`, labels include `ticket = "tra-810"`.

- [ ] **Step 2:** Append A record `db_preview` to `terraform/gcp/dns.tf` (in the `gke_trakrf_id` zone block, after `mqtt_prod`). Name `db.preview.${gke_trakrf_id.dns_name}`, rrdata `[google_compute_address.db_preview.address]`.

- [ ] **Step 3:** Add `db_preview_ip` output to `terraform/gcp/outputs.tf` after the `mqtt_*_ip` block.

- [ ] **Step 4:** `tofu -chdir=terraform/gcp init -backend-config=backend.conf && tofu -chdir=terraform/gcp validate && tofu -chdir=terraform/gcp plan`. Expected: 2 to add, 0 to change, 0 to destroy.

---

## Task 2: Helm chart — external Service template

- [ ] **Step 1:** Add `externalPreview` defaults to `helm/trakrf-db/values.yaml` (enabled=false, loadBalancerIP="", sourceRanges=[]).

- [ ] **Step 2:** Create `helm/trakrf-db/templates/external-service-preview.yaml`:

  - Guard: `{{- if and .Values.externalPreview.enabled .Values.externalPreview.loadBalancerIP }}`.
  - Service `type: LoadBalancer`, `loadBalancerIP` set, `loadBalancerSourceRanges` from `externalPreview.sourceRanges`, `externalTrafficPolicy: Local`.
  - Port 5432/TCP `postgres`.
  - Selector `cnpg.io/cluster: <fullnameOverride>` + `cnpg.io/instanceRole: primary` (matches the operator-managed `-rw` Service).

- [ ] **Step 3:** Render and confirm.

```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  --set externalPreview.enabled=true \
  --set externalPreview.loadBalancerIP=9.9.9.10 \
  --set-json 'externalPreview.sourceRanges=["10.0.0.1/32"]' \
  | grep -A 25 'preview-external'
```

Expected: Service with `loadBalancerIP: "9.9.9.10"`, `loadBalancerSourceRanges: [10.0.0.1/32]`, selector `cnpg.io/cluster: trakrf-db, cnpg.io/instanceRole: primary`.

Then confirm the default render emits NOTHING:

```bash
helm template tdb helm/trakrf-db -f helm/trakrf-db/values.yaml -f helm/trakrf-db/values-gke.yaml \
  | grep -c 'preview-external'
```

Expected: `0`.

---

## Task 3: Root chart + apply script wiring

- [ ] **Step 1:** `argocd/root/values.yaml` — add `dbPreviewIp: ""` placeholder near the `mqtt*` block.

- [ ] **Step 2:** `argocd/root/templates/trakrf-db.yaml` — compute `$values` only when `cluster=gke`, sourcing from `.Values.dbPreviewIp` and `.Values.breakglassSourceCidr`. Pass as `inlineValues` to the `trakrf.application` helper.

- [ ] **Step 3:** `scripts/apply-root-app.sh` — in the `gke)` case, read `db_preview_ip` tofu output into `DB_PREVIEW_IP`. Zero it out in the `aks)`, `eks)`, and default branches. Add `--set dbPreviewIp="$DB_PREVIEW_IP"` to the helm upgrade invocation.

- [ ] **Step 4:** Render the root chart for both clusters and confirm GKE wires the value, AKS does not:

```bash
# GKE
helm template trakrf-root argocd/root --set cluster=gke \
  --set gcpProjectId=test --set certManagerGcpServiceAccountEmail=test \
  --set cloudDnsZoneNameApp=test --set cloudDnsZoneNameId=test \
  --set mqttPreviewIp=1.2.3.4 --set mqttProdIp=5.6.7.8 \
  --set dbPreviewIp=9.9.9.10 \
  --set traefikLbIp=9.9.9.9 \
  --set breakglassSourceCidr=10.0.0.1/32 \
  --set-json 'cloudflareIpv4Cidrs=["1.1.1.0/24"]' \
  --set-json 'cloudflareIpv6Cidrs=["2606::/48"]' \
  | grep -A 6 'externalPreview'

# AKS
helm template trakrf-root argocd/root --set cluster=aks \
  --set certManagerIdentityClientId=test --set tenantId=test \
  --set subscriptionId=test --set dnsZoneResourceGroup=test \
  --set traefikLbIp=9.9.9.9 --set mainResourceGroupName=test \
  | grep -c 'externalPreview'
```

Expected: GKE shows the inlineValues block; AKS prints `0`.

---

## Task 4: Documentation + PR

- [ ] **Step 1:** Spec doc covers context, decision, out-of-scope, architecture, verification, risks.

- [ ] **Step 2:** This plan covers the file structure, per-task implementation steps, and verification commands.

- [ ] **Step 3:** Commit groups (one per layer): tofu (1 commit), helm chart (1), root chart + apply script (1), docs (1).

- [ ] **Step 4:** PR title + body must NOT reference Linear ticket numbers (per memory `feedback_no_ticket_refs_in_public_docs`).

- [ ] **Step 5:** Post-merge: `just gcp` to apply tofu, then `scripts/apply-root-app.sh gke` to push the new Service into the cluster. Verification steps in the spec.

---

## Out of scope

- Cert-manager-issued Postgres server cert under `db.preview.gke.trakrf.id` (follow-up if `verify-full` ergonomics matter).
- Dedicated `trakrf-dev-preview` role (the platform CC instance gets the CNPG superuser for preview).
- Prod or non-GKE external endpoint.
