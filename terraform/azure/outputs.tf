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

# AKS
output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "kubectl_config_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}

# ACR
output "acr_login_server" {
  description = "ACR login server for docker push/pull"
  value       = azurerm_container_registry.main.login_server
}

# DNS
output "dns_zone_name" {
  description = "Azure DNS zone name"
  value       = azurerm_dns_zone.aks_trakrf_app.name
}

output "dns_nameservers" {
  description = "Azure DNS nameservers — consumed by Cloudflare for NS delegation"
  value       = azurerm_dns_zone.aks_trakrf_app.name_servers
}
