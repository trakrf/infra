# Container registry — trakrf.azurecr.io
# Admin disabled; auth is via AKS kubelet managed identity (role assignment in aks.tf)
resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false

  tags = local.common_tags
}
