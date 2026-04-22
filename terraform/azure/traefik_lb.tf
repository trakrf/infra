# Static public IP for Traefik's LoadBalancer Service. Lives in the main RG
# (not the auto-created MC_ RG) so it survives cluster rebuilds. prevent_destroy
# guards against accidental rotation — TF-managed A records in dns.tf depend on
# this IP being stable.
resource "azurerm_public_ip" "traefik" {
  name                = "pip-traefik-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = [var.primary_pool_zone]

  tags = merge(local.common_tags, { Ticket = "TRA-438" })

  lifecycle {
    prevent_destroy = true
  }
}

# AKS cluster identity needs Network Contributor on main RG so cloud-controller
# can bind the PIP to the LB when the Traefik Service comes up. Required because
# the PIP is OUTSIDE the auto-created MC_ resource group.
resource "azurerm_role_assignment" "aks_network_contributor_main_rg" {
  principal_id                     = azurerm_kubernetes_cluster.main.identity[0].principal_id
  role_definition_name             = "Network Contributor"
  scope                            = azurerm_resource_group.main.id
  skip_service_principal_aad_check = true
}
