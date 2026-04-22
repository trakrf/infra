locals {
  region = "us-east-2"
  azs    = ["us-east-2a", "us-east-2b"]

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Ticket      = "TRA-352"
  }
}

resource "aws_route53_zone" "aws_subdomain" {
  name = "aws.trakrf.id"

  tags = merge(local.common_tags, {
    Purpose = "aws-service-dns"
  })

  # Zone holds the delegation that Cloudflare NS records point at. Destroying it
  # forces a manual re-import + CF NS record rotation on every EKS rebuild.
  # Removed from state during the 2026-04-21 EKS burndown, re-imported via
  # targeted apply on 2026-04-22 (TRA-437 side-cleanup). Kept in state going
  # forward so burn-downs of EKS never touch the zone.
  lifecycle {
    prevent_destroy = true
  }
}
