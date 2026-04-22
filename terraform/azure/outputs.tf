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

# TRA-438 — wiring for helm values (cert-manager, Traefik)

output "cert_manager_identity_client_id" {
  description = "Client ID of the cert-manager user-assigned identity (SA annotation + solver config)"
  value       = azurerm_user_assigned_identity.cert_manager.client_id
}

output "tenant_id" {
  description = "Entra tenant ID (Azure DNS solver config)"
  value       = data.azuread_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Subscription the DNS zone + LB resources live in (Azure DNS solver config, LB annotation)"
  value       = data.azurerm_client_config.current.subscription_id
}

output "traefik_lb_ip" {
  description = "Static IP for Traefik LoadBalancer Service — passed as helm loadBalancerIP"
  value       = azurerm_public_ip.traefik.ip_address
}

# Note: `resource_group_name` (above) is used for BOTH dns_zone_resource_group
# (cert-manager Azure DNS solver) and main_resource_group_name (Traefik Service
# azure-load-balancer-resource-group annotation). Same value today; if prod ever
# splits them, add separate outputs at that point.
