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
}
