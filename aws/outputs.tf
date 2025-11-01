output "zone_id" {
  description = "Route53 hosted zone ID for aws.trakrf.id"
  value       = aws_route53_zone.aws_subdomain.zone_id
}

output "nameservers" {
  description = "Route53 nameservers for delegation"
  value       = aws_route53_zone.aws_subdomain.name_servers
}

output "zone_name" {
  description = "Zone name"
  value       = aws_route53_zone.aws_subdomain.name
}
