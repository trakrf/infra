resource "aws_route53_zone" "aws_subdomain" {
  name = "aws.trakrf.id"

  tags = {
    ManagedBy = "terraform"
    Project   = "trakrf-infra"
    Purpose   = "aws-service-dns"
  }
}
