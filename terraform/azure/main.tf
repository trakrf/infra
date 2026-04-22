locals {
  region      = var.region
  name_prefix = "${var.project}-${var.environment}-${var.location}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Ticket      = "TRA-436"
  }
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = local.region

  tags = local.common_tags
}
