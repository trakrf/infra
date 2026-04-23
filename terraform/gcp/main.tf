locals {
  region      = var.region
  name_prefix = "${var.project}-${var.environment}-${var.location}"

  common_labels = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
    ticket      = "tra-460"
  }
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}
