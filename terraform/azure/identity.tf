# Current az CLI principal — used as group owner + first member
data "azuread_client_config" "current" {}

# azurerm client config — exposes the subscription the TF session is authed against.
# Consumed by outputs.tf for the cert-manager Azure DNS solver config.
data "azurerm_client_config" "current" {}

# Entra group that grants AKS cluster-admin via AAD-RBAC
resource "azuread_group" "aks_admins" {
  display_name     = "trakrf-aks-admins"
  description      = "Cluster admins for AKS (trakrf) — TRA-437"
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]
}

# Self-membership so the operator who ran 'just azure' has immediate admin access
resource "azuread_group_member" "aks_admin_self" {
  group_object_id  = azuread_group.aks_admins.object_id
  member_object_id = data.azuread_client_config.current.object_id
}
