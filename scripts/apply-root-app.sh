#!/usr/bin/env bash
# Template argocd/root/values.yaml with tofu outputs and install the
# trakrf-root app-of-apps helm release.
#
# Usage: scripts/apply-root-app.sh <cluster>
#   <cluster>  cluster profile. Must match helm chart overlays
#              (values-<cluster>.yaml across helm/* charts).
#              Supported: aks, eks (future: homelab, etc.)
#
# For AKS reads tofu outputs from terraform/azure/. For EKS cluster is
# burned down (TRA-381) so tofu outputs don't exist — pass blanks, the
# EKS overlay doesn't need tofu-sourced values anyway (Cloudflare DNS
# solver + no workload identity).

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
    ;;
  eks)
    CLIENT_ID=""
    TENANT_ID=""
    SUB_ID=""
    DNS_RG=""
    LB_IP=""
    MAIN_RG=""
    ;;
  *)
    echo "warning: no tofu output wiring for cluster '$CLUSTER'; passing blank values" >&2
    CLIENT_ID=""
    TENANT_ID=""
    SUB_ID=""
    DNS_RG=""
    LB_IP=""
    MAIN_RG=""
    ;;
esac

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
  --set mainResourceGroupName="$MAIN_RG"

echo
echo "Root app installed. Watch sync with:"
echo "  kubectl -n argocd get applications -w"
