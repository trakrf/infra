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
    GCP_DNS_ZONE_NAME=""
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
    GCP_DNS_ZONE_NAME=$(tofu -chdir="$TF_DIR" output -raw cloud_dns_zone_name)
    LB_IP=$(tofu -chdir="$TF_DIR" output -raw traefik_lb_ip)
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
    GCP_DNS_ZONE_NAME=""
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
    GCP_DNS_ZONE_NAME=""
    ;;
esac

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
  --set cloudDnsZoneName="$GCP_DNS_ZONE_NAME" \
  "${EXTRA_ARGS[@]}"

echo
echo "Root app installed. Watch sync with:"
echo "  kubectl -n argocd get applications -w"
