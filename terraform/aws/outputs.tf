# Route53
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

# EKS
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority" {
  description = "EKS cluster CA certificate (base64 encoded)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "kubectl_config_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}"
}

# ECR
output "ecr_repository_url" {
  description = "ECR repository URL for docker push"
  value       = aws_ecr_repository.backend.repository_url
}

# IRSA
output "irsa_role_arns" {
  description = "IRSA role ARNs for Helm values"
  value = {
    ebs_csi  = module.ebs_csi_irsa.iam_role_arn
    crunchy  = module.crunchy_irsa.iam_role_arn
    argocd   = module.argocd_irsa.iam_role_arn
  }
}
