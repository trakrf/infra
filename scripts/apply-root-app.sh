#!/usr/bin/env bash
# Template argocd/root/values.yaml with tofu outputs and install the
# trakrf-root app-of-apps helm release.
#
# Usage: scripts/apply-root-app.sh <cluster>
#   <cluster>  cluster profile. Must match helm chart overlays
#              (values-<cluster>.yaml across helm/* charts).
#              Supported: aks, eks (future: homelab, etc.)
#
# For AKS reads tofu outputs from terraform/azure/. For GKE reads from
# terraform/gcp/. For EKS cluster is burned down (TRA-381) so tofu outputs
# don't exist — pass blanks, the EKS overlay doesn't need tofu-sourced values
# (Cloudflare DNS solver + no workload identity).

set -euo pipefail

CLUSTER="${1:-}"
if [[ -z "$CLUSTER" ]]; then
  echo "usage: $0 <cluster>" >&2
  exit 1
fi

case "$CLUSTER" in
  aks)
    TF_DIR="terraform/azure"
    CLIENT_ID=$(tofu -chdir="$TF_DIR" output -raw cert_manager_identity_client_id)
    TENANT_ID=$(tofu -chdir="$TF_DIR" output -raw tenant_id)
    SUB_ID=$(tofu -chdir="$TF_DIR" output -raw subscription_id)
    # resource_group_name doubles as dns_zone_resource_group + main_resource_group_name
    # (same value today — see terraform/azure/outputs.tf comment).
    MAIN_RG=$(tofu -chdir="$TF_DIR" output -raw resource_group_name)
    DNS_RG="$MAIN_RG"
    LB_IP=$(tofu -chdir="$TF_DIR" output -raw traefik_lb_ip)
    GCP_PROJECT_ID=""
    GCP_CM_SA_EMAIL=""
    GCP_DNS_ZONE_NAME_APP=""
    GCP_DNS_ZONE_NAME_ID=""
    MQTT_PREVIEW_IP=""
    MQTT_PROD_IP=""
    CNPG_BACKUP_BUCKET=""
    CNPG_BACKUPS_GSA_EMAIL=""
    DB_PREVIEW_IP=""
    ;;
  gke)
    TF_DIR="terraform/gcp"
    # Azure fields — zero out, cluster=gke means the root templates skip them.
    CLIENT_ID=""
    TENANT_ID=""
    SUB_ID=""
    DNS_RG=""
    MAIN_RG=""
    # GCP-specific outputs.
    GCP_PROJECT_ID=$(tofu -chdir="$TF_DIR" output -raw project_id)
    GCP_CM_SA_EMAIL=$(tofu -chdir="$TF_DIR" output -raw cert_manager_service_account_email)
    GCP_DNS_ZONE_NAME_APP=$(tofu -chdir="$TF_DIR" output -raw cloud_dns_zone_name)
    GCP_DNS_ZONE_NAME_ID=$(tofu  -chdir="$TF_DIR" output -raw cloud_dns_zone_name_id)
    LB_IP=$(tofu -chdir="$TF_DIR" output -raw traefik_lb_ip)
    MQTT_PREVIEW_IP=$(tofu -chdir="$TF_DIR" output -raw mqtt_preview_ip)
    MQTT_PROD_IP=$(tofu -chdir="$TF_DIR" output -raw mqtt_prod_ip)
    CNPG_BACKUP_BUCKET=$(tofu -chdir="$TF_DIR" output -raw cnpg_backup_bucket)
    CNPG_BACKUPS_GSA_EMAIL=$(tofu -chdir="$TF_DIR" output -raw cnpg_backups_service_account_email)
    DB_PREVIEW_IP=$(tofu -chdir="$TF_DIR" output -raw db_preview_ip)
    ;;
  eks)
    CLIENT_ID=""
    TENANT_ID=""
    SUB_ID=""
    DNS_RG=""
    LB_IP=""
    MAIN_RG=""
    GCP_PROJECT_ID=""
    GCP_CM_SA_EMAIL=""
    GCP_DNS_ZONE_NAME_APP=""
    GCP_DNS_ZONE_NAME_ID=""
    MQTT_PREVIEW_IP=""
    MQTT_PROD_IP=""
    CNPG_BACKUP_BUCKET=""
    CNPG_BACKUPS_GSA_EMAIL=""
    DB_PREVIEW_IP=""
    ;;
  *)
    echo "warning: no tofu output wiring for cluster '$CLUSTER'; passing blank values" >&2
    CLIENT_ID=""
    TENANT_ID=""
    SUB_ID=""
    DNS_RG=""
    LB_IP=""
    MAIN_RG=""
    GCP_PROJECT_ID=""
    GCP_CM_SA_EMAIL=""
    GCP_DNS_ZONE_NAME_APP=""
    GCP_DNS_ZONE_NAME_ID=""
    MQTT_PREVIEW_IP=""
    MQTT_PROD_IP=""
    CNPG_BACKUP_BUCKET=""
    CNPG_BACKUPS_GSA_EMAIL=""
    DB_PREVIEW_IP=""
    ;;
esac

# --- Preview ingress origin-lock values (GKE-only) ------------------
# Only the GKE root chart consumes these. Skip on dormant clusters so
# `apply-root-app.sh aks` doesn't suddenly require the Cloudflare tofu
# workspace to be initialized locally.
BREAKGLASS_CIDR=""
CF_IPV4_JSON="[]"
CF_IPV6_JSON="[]"
if [[ "$CLUSTER" == "gke" ]]; then
  # Break-glass CIDR: resolve home dyn DNS at apply time. Fail loud rather
  # than deploy an empty allowlist (which would still pass schema validation
  # but render the IngressRoute open to nobody).
  BREAKGLASS_HOSTNAME="${BREAKGLASS_HOSTNAME:-opsumo-austin.asuscomm.com}"
  BREAKGLASS_IP=$(dig +short "$BREAKGLASS_HOSTNAME" A | tail -1)
  if [[ -z "$BREAKGLASS_IP" ]]; then
    echo "FATAL: could not resolve $BREAKGLASS_HOSTNAME — refusing to apply." >&2
    exit 1
  fi
  BREAKGLASS_CIDR="${BREAKGLASS_IP}/32"

  # Cloudflare IP ranges — pulled from the cloudflare tofu workspace that owns
  # the Origin Cert. JSON arrays get spliced into helm --set-json below.
  CF_IPV4_JSON=$(tofu -chdir=terraform/cloudflare output -json cloudflare_ipv4_cidrs)
  CF_IPV6_JSON=$(tofu -chdir=terraform/cloudflare output -json cloudflare_ipv6_cidrs)
fi
# --------------------------------------------------------------------

EXTRA_ARGS=()
if [[ -n "${TARGET_REVISION:-}" ]]; then
  echo "TARGET_REVISION override: $TARGET_REVISION"
  EXTRA_ARGS+=(--set "targetRevision=$TARGET_REVISION")
fi

echo "Installing trakrf-root chart (cluster=$CLUSTER)..."
helm upgrade --install trakrf-root argocd/root \
  --namespace argocd \
  --create-namespace \
  -f argocd/root/values.yaml \
  --set cluster="$CLUSTER" \
  --set certManagerIdentityClientId="$CLIENT_ID" \
  --set tenantId="$TENANT_ID" \
  --set subscriptionId="$SUB_ID" \
  --set dnsZoneResourceGroup="$DNS_RG" \
  --set traefikLbIp="$LB_IP" \
  --set mainResourceGroupName="$MAIN_RG" \
  --set gcpProjectId="$GCP_PROJECT_ID" \
  --set certManagerGcpServiceAccountEmail="$GCP_CM_SA_EMAIL" \
  --set cloudDnsZoneNameApp="$GCP_DNS_ZONE_NAME_APP" \
  --set cloudDnsZoneNameId="$GCP_DNS_ZONE_NAME_ID" \
  --set envs.preview.mqttIp="$MQTT_PREVIEW_IP" \
  --set envs.prod.mqttIp="$MQTT_PROD_IP" \
  --set cnpgBackupBucket="$CNPG_BACKUP_BUCKET" \
  --set cnpgBackupsGcpServiceAccountEmail="$CNPG_BACKUPS_GSA_EMAIL" \
  --set dbPreviewIp="$DB_PREVIEW_IP" \
  --set breakglassSourceCidr="$BREAKGLASS_CIDR" \
  --set-json cloudflareIpv4Cidrs="$CF_IPV4_JSON" \
  --set-json cloudflareIpv6Cidrs="$CF_IPV6_JSON" \
  "${EXTRA_ARGS[@]}"

echo
echo "Root app installed. Watch sync with:"
echo "  kubectl -n argocd get applications -w"
