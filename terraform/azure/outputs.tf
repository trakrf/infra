output "resource_group_name" {
  description = "Azure resource group name for AKS demo infra"
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region"
  value       = azurerm_resource_group.main.location
}

output "vnet_id" {
  description = "VNet ID for downstream AKS attachment"
  value       = azurerm_virtual_network.main.id
}

output "aks_nodes_subnet_id" {
  description = "Node subnet ID for the AKS system pool"
  value       = azurerm_subnet.aks_nodes.id
}
