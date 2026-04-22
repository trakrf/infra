# Public DNS zone for AKS demo workloads
# Cloudflare delegates aks.trakrf.app here via terraform/cloudflare/azure-delegation.tf
resource "azurerm_dns_zone" "aks_trakrf_app" {
  name                = "aks.trakrf.app"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}
