# Public DNS zone for AKS demo workloads
# Cloudflare delegates aks.trakrf.app here via terraform/cloudflare/azure-delegation.tf
resource "azurerm_dns_zone" "aks_trakrf_app" {
  name                = "aks.trakrf.app"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags

  # Zone holds the delegation that Cloudflare NS records point at. Azure assigns
  # random nameservers at create time, so destroying it forces CF NS rotation on
  # every rebuild. Mirrors the prevent_destroy pattern on aws_route53_zone.
  lifecycle {
    prevent_destroy = true
  }
}

# Apex A record — browser hits https://aks.trakrf.app
resource "azurerm_dns_a_record" "aks_apex" {
  name                = "@"
  zone_name           = azurerm_dns_zone.aks_trakrf_app.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.traefik.ip_address]

  tags = merge(local.common_tags, { Ticket = "TRA-438" })
}

# Wildcard — grafana.aks.trakrf.app, anything.aks.trakrf.app
resource "azurerm_dns_a_record" "aks_wildcard" {
  name                = "*"
  zone_name           = azurerm_dns_zone.aks_trakrf_app.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.traefik.ip_address]

  tags = merge(local.common_tags, { Ticket = "TRA-438" })
}
