# User-assigned identity that cert-manager pods federate into via the AKS OIDC issuer.
# Scoped to DNS Zone Contributor on aks.trakrf.app ONLY — the solver needs TXT
# record create/delete for _acme-challenge.* during DNS-01 validation.
resource "azurerm_user_assigned_identity" "cert_manager" {
  name                = "id-cert-manager-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = merge(local.common_tags, { Ticket = "TRA-438" })
}

# Federated credential binds the cert-manager Kubernetes SA to the UAI.
# Subject MUST exactly match the actual SA namespace/name — the cert-manager
# Helm chart's default SA is `cert-manager` in the `cert-manager` namespace.
resource "azurerm_federated_identity_credential" "cert_manager" {
  name      = "fc-cert-manager-${local.name_prefix}"
  audience  = ["api://AzureADTokenExchange"]
  issuer    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  user_assigned_identity_id = azurerm_user_assigned_identity.cert_manager.id
  subject   = "system:serviceaccount:cert-manager:cert-manager"
}

# Tight scope: only the aks.trakrf.app DNS zone resource. Does NOT grant
# access to other zones, the resource group, or the subscription.
resource "azurerm_role_assignment" "cert_manager_dns" {
  principal_id                     = azurerm_user_assigned_identity.cert_manager.principal_id
  role_definition_name             = "DNS Zone Contributor"
  scope                            = azurerm_dns_zone.aks_trakrf_app.id
  skip_service_principal_aad_check = true
}
