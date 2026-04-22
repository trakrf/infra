# GitHub Actions OIDC — federated identity for terraform/azure/ CI (TRA-439)
# Dedicated app registration (not shared with hashsphere). See
# docs/superpowers/specs/2026-04-22-tra-439-azure-ci-oidc-design.md.

resource "azuread_application" "trakrf_infra_ci" {
  display_name = "trakrf-infra-ci"
  owners       = [data.azuread_client_config.current.object_id]

  lifecycle {
    ignore_changes = [owners]
  }
}

resource "azuread_service_principal" "trakrf_infra_ci" {
  client_id = azuread_application.trakrf_infra_ci.client_id
  owners    = [data.azuread_client_config.current.object_id]

  lifecycle {
    ignore_changes = [owners]
  }
}

resource "azuread_application_federated_identity_credential" "gha_pr" {
  application_id = azuread_application.trakrf_infra_ci.id
  display_name   = "github-pull-request"
  description    = "GitHub Actions PR plan jobs"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:trakrf/infra:pull_request"
}

resource "azuread_application_federated_identity_credential" "gha_main" {
  application_id = azuread_application.trakrf_infra_ci.id
  display_name   = "github-main-branch"
  description    = "GitHub Actions apply jobs (workflow_dispatch on main)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:trakrf/infra:ref:refs/heads/main"
}

resource "azurerm_role_assignment" "trakrf_infra_ci_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.trakrf_infra_ci.object_id
}
