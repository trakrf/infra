module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint for kubectl from dev machines, private for node comms
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Core addons (EBS CSI defined separately to avoid circular IRSA dependency)
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    general = {
      instance_types = ["t3.xlarge"]
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 3
      desired_size = 1

      disk_size = 50
    }
  }

  # Allow current IAM user to manage cluster
  enable_cluster_creator_admin_permissions = true

  tags = local.common_tags
}
