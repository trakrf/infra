# TRA-829 — `gke.trakrf.id` DNS + cert-manager foundation

**Status:** Design
**Date:** 2026-05-25
**Related:** TRA-828 (Mosquitto broker — consumer, blocked by this), TRA-461 (GKE cert-manager Cloud DNS solver pattern this extends), TRA-368 (CF DNS-01 token pattern — not used here), TRA-825 (GKE preview cutover)

## Context

GKE-served hosts that need a GKE-issued public ACME cert — i.e. hosts that can't ride the Cloudflare edge cert because they're direct-served or device-facing — currently only have `gke.trakrf.app` to land in. Two consumers are queued behind a `.id` foundation: the Mosquitto broker (TRA-828, device-facing, can't go through Cloudflare proxy) and the Grafana hostname move (browser-facing, direct-served via Traefik on GKE). The `.id` consolidation is the forward direction for these hosts.

Web stays Cloudflare-proxied (CF edge cert), so this foundation is only for GKE-issued-cert hosts — not the marketing site or `app.*`. No Cloudflare DNS-01 token: the existing GKE Cloud DNS Workload Identity solver (TRA-461) extends to a second zone with a one-line zone-scoped IAM binding and a second solver entry in the ClusterIssuer.

This ticket is pure infra: no real consumer depends on it. The acceptance test is a `*.gke.trakrf.id` wildcard Cert that issues clean, proving delegation, IAM binding, and solver are all correct before TRA-828 or the Grafana ticket builds on it.

## Decision

Stand up `gke.trakrf.id` as a Cloud DNS managed zone delegated from Cloudflare, extend the existing GKE Workload Identity cert-manager SA to write the new zone (zone-scoped IAM, mirroring the `.app` binding), and refactor `helm/cert-manager-config` so its ClusterIssuer renders one DNS-01 solver entry per zone and its Certificate template renders one cert per entry in a `certificates` list.

Ship a `*.gke.trakrf.id` wildcard Certificate (apex + wildcard SAN) mirroring the existing `*.gke.trakrf.app` pattern. Apex + wildcard A records both point at the existing static Traefik LB IP, so any future Traefik-routed `.id` host (Grafana first) resolves with no additional DNS work. The broker (TRA-828) is device-facing on its own LoadBalancer with its own host-specific A record and host-specific Cert — it does not consume the wildcard.

The chart refactor (singular fields → lists) generalizes the existing shape rather than adding a parallel hardcoded branch. Adding a third zone later (whitelabel, ephemeral env, etc.) becomes a values-file edit, not a template edit. The `cloudflare` and `azureDNS` solver branches stay untouched.

## Out of scope

- Grafana hostname move — separate ticket; will consume `trakrf-gke-id-wildcard-tls` via its own IngressRoute (and Reflector-mirrored Secret if cross-namespace).
- Broker host-specific cert (`mqtt.*.gke.trakrf.id`) — TRA-828.
- AKS chart cleanup beyond adopting the new list shape (`certificates` as a 1-item list, no `cloudDNS.zones`).
- EKS — burned down (TRA-381 era); the EKS branch of `apply-root-app.sh` keeps passing blanks.
- Cloudflare `trakrf.id` zone creation — already exists as `cloudflare_zone.domain`.
- `gke.trakrf.app` retirement (apex/wildcard A records, wildcard cert) — left in place. Removal is a follow-up once all `.app` consumers have migrated.

## DNS architecture

```
Cloudflare zone trakrf.id (cloudflare_zone.domain)
  NS gke → [google-cloud-dns-ns-1..4]      (new cloudflare_record block)
                          │
                          ▼
GCP Cloud DNS managed zone "gke-trakrf-id"
  gke.trakrf.id.       A   <traefik LB IP>
  *.gke.trakrf.id.     A   <traefik LB IP>
                          │
                          ▼
cert-manager-gke SA (existing, from TRA-461)
  roles/dns.admin on gke-trakrf-app     (existing)
  roles/dns.admin on gke-trakrf-id      (new, zone-scoped binding)
                          │
                          ▼
ClusterIssuer letsencrypt-prod (singular issuer, TWO solver entries)
  - dns01.cloudDNS{ project, hostedZoneName: gke-trakrf-app }  selector.dnsZones=[gke.trakrf.app]
  - dns01.cloudDNS{ project, hostedZoneName: gke-trakrf-id  }  selector.dnsZones=[gke.trakrf.id]
                          │
                          ▼
Two Certificates in namespace cert-manager:
  trakrf-gke-wildcard     → Secret trakrf-gke-wildcard-tls
    dnsNames: gke.trakrf.app, *.gke.trakrf.app   (existing — name preserved)
  trakrf-gke-id-wildcard  → Secret trakrf-gke-id-wildcard-tls
    dnsNames: gke.trakrf.id,  *.gke.trakrf.id    (new)
```

Key properties:

- One `cert-manager-gke` GCP SA, two zone-scoped IAM bindings (one per zone). Blast radius stays tight: solver can't touch other zones or project resources.
- One `letsencrypt-prod` ClusterIssuer, two solver entries. `selector.dnsZones` routes challenges to the correct zone.
- Wildcard Certificate per zone. `.app` keeps serving existing Traefik hosts; `.id` serves Grafana and any future Traefik-routed `.id` host.
- Public ACME (Let's Encrypt) — GL-S10 and standard browsers trust ISRG Root X1 out of the box.

## Component changes

### Terraform — `terraform/gcp/`

**`dns.tf`** — additions (existing `gke_trakrf_app` block untouched):

- `google_dns_managed_zone "gke_trakrf_id"` — name `gke-trakrf-id`, dns_name `gke.trakrf.id.`, `prevent_destroy = true`, `labels = local.common_labels`. Description references TRA-829.
- `google_dns_record_set "gke_id_apex"` — A, `gke.trakrf.id.`, rrdatas `[google_compute_address.traefik.address]`, ttl 300.
- `google_dns_record_set "gke_id_wildcard"` — A, `*.gke.trakrf.id.`, same rrdatas, ttl 300.

**`cert_manager.tf`** — addition: `google_dns_managed_zone_iam_member "cert_manager_dns_admin_id"`, zone-scoped to `gke-trakrf-id`, same SA, role `roles/dns.admin`. The Workload Identity binding stays as-is (one SA, two zone bindings).

**`outputs.tf`** — three new outputs mirroring the existing trio:

- `dns_zone_name_id` — `trimsuffix(google_dns_managed_zone.gke_trakrf_id.dns_name, ".")`
- `dns_nameservers_id` — `google_dns_managed_zone.gke_trakrf_id.name_servers`
- `cloud_dns_zone_name_id` — `google_dns_managed_zone.gke_trakrf_id.name`

### Terraform — `terraform/cloudflare/`

**`gcp-delegation.tf`** — addition: second `cloudflare_record` block (`gke_subdomain_ns_id`) delegating `gke.trakrf.id` NS to the new GCP zone's nameservers.

- `zone_id = cloudflare_zone.domain.id` (the `trakrf.id` apex zone — distinct from `cloudflare_zone.trakrf_app` used for the `.app` delegation).
- `name = "gke"`, type `NS`, `count = length(data.terraform_remote_state.gcp.outputs.dns_nameservers_id)`.
- `content = data.terraform_remote_state.gcp.outputs.dns_nameservers_id[count.index]`, ttl 3600.
- Comment: `"Delegate gke.trakrf.id to GCP Cloud DNS"`.

The existing `data "terraform_remote_state" "gcp"` block is reused — no second remote-state lookup.

### Helm — `helm/cert-manager-config/templates/clusterissuer.yaml`

The `cloudDNS` branch becomes a `range` over `cloudDNS.zones`, emitting one solver entry per item. The `cloudflare` and `azureDNS` branches stay untouched.

```yaml
{{- else if eq .Values.solver "cloudDNS" }}
# GKE Workload Identity — no token/secret in spec; cert-manager pod SA is
# annotated with iam.gke.io/gcp-service-account (set by argocd/root/
# templates/cert-manager.yaml). Each entry in cloudDNS.zones renders one
# solver block. hostedZoneName is the Cloud DNS managed-zone RESOURCE NAME
# (e.g. "gke-trakrf-app"), dnsZoneName is the DNS name used in the selector.
{{- range .Values.cloudDNS.zones }}
- dns01:
    cloudDNS:
      project: {{ $.Values.cloudDNS.project }}
      hostedZoneName: {{ .hostedZoneName }}
  selector:
    dnsZones:
      - {{ .dnsZoneName }}
{{- end }}
```

### Helm — `helm/cert-manager-config/templates/certificate.yaml`

Wrap the existing single-Certificate body in `{{- range .Values.certificates }}`, separated by `---`. Loop fields: `.name`, `.namespace`, `.secretName`, `.commonName`, `.dnsNames`. Keep the `privateKey` block (ECDSA P-256, `rotationPolicy: Always`) as-is. Removes the singular `certificate.*` fields.

### Helm — `helm/cert-manager-config/values-gke.yaml`

Restructure to lists:

```yaml
solver: cloudDNS

cloudDNS:
  project: REPLACE_ME           # injected by scripts/apply-root-app.sh
  zones:
    - hostedZoneName: REPLACE_ME_APP   # gke-trakrf-app, injected
      dnsZoneName: gke.trakrf.app
    - hostedZoneName: REPLACE_ME_ID    # gke-trakrf-id, injected
      dnsZoneName: gke.trakrf.id

certificates:
  # Name kept as-is to avoid a destructive rename (cert-manager doesn't follow
  # renames — it deletes and re-issues). Asymmetric vs the new .id entry, but
  # the cost of renaming (issuance churn, consumer Secret-name references)
  # outweighs cosmetic symmetry.
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

### Helm — `helm/cert-manager-config/values.yaml` and `values-aks.yaml`

Adopt the same list shape so the template stays consistent across solvers. AKS sets `certificates:` as a 1-item list and does not set `cloudDNS.zones` (its solver is `azureDNS`, which still uses singular `azureDNS.hostedZoneName`). `values.yaml` (default / fallback) follows the same shape.

### ArgoCD root — `argocd/root/templates/cert-manager-config.yaml`

The GKE branch's `printf` becomes a multi-line render that emits the `cloudDNS.zones` list:

```yaml
cloudDNS:
  project: {{ .Values.gcpProjectId }}
  zones:
    - hostedZoneName: {{ .Values.cloudDnsZoneNameApp }}
      dnsZoneName: gke.trakrf.app
    - hostedZoneName: {{ .Values.cloudDnsZoneNameId }}
      dnsZoneName: gke.trakrf.id
```

Two values feed in instead of one. AKS branch unchanged.

### ArgoCD root — `argocd/root/values.yaml`

Rename `cloudDnsZoneName` → `cloudDnsZoneNameApp`, add `cloudDnsZoneNameId: ""`.

### Scripts — `scripts/apply-root-app.sh`

GKE branch reads a second tofu output and renames the existing one:

```bash
GCP_DNS_ZONE_NAME_APP=$(tofu -chdir="$TF_DIR" output -raw cloud_dns_zone_name)
GCP_DNS_ZONE_NAME_ID=$(tofu  -chdir="$TF_DIR" output -raw cloud_dns_zone_name_id)
```

AKS / EKS / default branches export both as empty strings. The `helm upgrade --install` invocation replaces `--set cloudDnsZoneName=...` with two `--set` flags: `cloudDnsZoneNameApp=...` and `cloudDnsZoneNameId=...`.

## Apply ordering (load-bearing)

The first DNS-01 challenge for the new zone fails if the zone isn't publicly resolvable when cert-manager attempts it.

1. `tofu -chdir=terraform/gcp plan` then `apply` — creates zone, A records, IAM binding.
2. `tofu -chdir=terraform/cloudflare plan` then `apply` — delegates `gke.trakrf.id` NS to Cloud DNS.
3. `dig +trace NS gke.trakrf.id` — confirm the NS chain reaches Cloud DNS (not Cloudflare). Wait until this resolves before proceeding.
4. `scripts/apply-root-app.sh gke` — re-templates root chart with the two zone values; ArgoCD picks up the new `cert-manager-config` Application values.
5. ArgoCD reconciles `cert-manager-config`: ClusterIssuer updates to two solver entries → both Certificate resources reconcile → DNS-01 succeeds on each zone → `trakrf-gke-wildcard-tls` (existing, may renew clean as a side effect) and `trakrf-gke-id-wildcard-tls` (new) Secrets land.

## Acceptance

```bash
kubectl -n cert-manager get certificate
# expected: trakrf-gke-wildcard and trakrf-gke-id-wildcard both READY=True

kubectl -n cert-manager get secret trakrf-gke-id-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -subject -issuer -ext subjectAltName
# expected:
#   subject = CN=gke.trakrf.id
#   issuer  = C=US, O=Let's Encrypt, CN=R10 (or R11)
#   X509v3 Subject Alternative Name:
#     DNS:gke.trakrf.id, DNS:*.gke.trakrf.id
```

A `dig` smoke test confirms public resolution:

```bash
dig +short A gke.trakrf.id          # expect the Traefik LB IP
dig +short A test.gke.trakrf.id     # expect the same IP via wildcard
```

## Rollback

- **Cluster (Helm/Argo):** revert the PR commit. ArgoCD reconciles the ClusterIssuer back to a single solver entry, the `.id` Certificate is GC'd, the new Secret is removed. The existing `.app` Cert is unaffected (the loop still emits its entry).
- **Cloudflare:** revert `gcp-delegation.tf` to remove the NS records. Tear down only if the rollback is permanent — otherwise leaving delegation intact is harmless.
- **GCP:** prefer to leave the new zone, A records, and IAM in place even on a code revert (additive, $0 idle). Tear down only if the rollback is permanent.

## Constraints (carry into the build)

- DNS-01 needs the new zone publicly resolvable before cert-manager runs the first challenge. Skipping the post-`tofu apply` `dig +trace` check makes the first issuance fail; cert-manager retries, but each retry burns Let's Encrypt rate limit against the staging or prod issuer.
- The chart's `cloudDNS.zones` is a list, not a map — order doesn't matter, but each entry must have both `hostedZoneName` and `dnsZoneName`. Validate in plan that the rendered YAML is well-formed (`helm template` locally before pushing).
- `certificates` is a list in `values.yaml` / `values-aks.yaml` even on solvers that only need one cert. Keep the shape uniform.
- Don't rename the existing `.app` wildcard Cert (`trakrf-gke-wildcard`). Renaming is destructive in cert-manager (deletes + recreates the Cert resource and forces fresh issuance, with a Secret gap).
- Cloudflare zone for `trakrf.id` already exists as `cloudflare_zone.domain`. Don't create a duplicate; reference `.domain.id`.

## File inventory

**New:**

- `docs/superpowers/specs/2026-05-25-tra-829-gke-trakrf-id-foundation-design.md` (this file)

**Modified:**

- `terraform/gcp/dns.tf`
- `terraform/gcp/cert_manager.tf`
- `terraform/gcp/outputs.tf`
- `terraform/cloudflare/gcp-delegation.tf`
- `helm/cert-manager-config/templates/clusterissuer.yaml`
- `helm/cert-manager-config/templates/certificate.yaml`
- `helm/cert-manager-config/values.yaml`
- `helm/cert-manager-config/values-gke.yaml`
- `helm/cert-manager-config/values-aks.yaml`
- `argocd/root/templates/cert-manager-config.yaml`
- `argocd/root/values.yaml`
- `scripts/apply-root-app.sh`
