# AKS cluster — single on-demand primary node runs everything (DB + app + platform)
# Spot burst pool deferred to TRA-438. See project_aks_demo_topology memory.
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aks-${local.name_prefix}"
  kubernetes_version  = var.kubernetes_version

  # Primary (system) pool — on-demand ARM, single-AZ for CNPG PV stability
  default_node_pool {
    name            = "primary"
    vm_size         = "Standard_D4ps_v6"
    vnet_subnet_id  = azurerm_subnet.aks_nodes.id
    node_count      = 1
    zones           = [var.primary_pool_zone]
    os_disk_size_gb = 50

    # Match Azure's auto-defaults so plan stays clean. Without these declared,
    # the provider keeps trying to remove the inferred upgrade_settings block.
    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }

    tags = local.common_tags
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure CNI Overlay — pods get IPs from pod_cidr, not subnet IPs
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.245.0.0/16"
    dns_service_ip      = "10.245.0.10"
    load_balancer_sku   = "standard"
  }

  # AAD-RBAC — Entra group holds cluster-admin; local accounts kept as escape hatch
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = [azuread_group.aks_admins.object_id]
  }

  local_account_disabled = false

  tags = local.common_tags
}

# AcrPull on the kubelet identity — lets AKS nodes pull private images from ACR.
# skip_service_principal_aad_check avoids first-apply PrincipalNotFound from Entra
# replication lag (the kubelet identity was created seconds ago in the same apply).
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.main.id
  skip_service_principal_aad_check = true
}
