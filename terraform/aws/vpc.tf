module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = ["10.142.1.0/24", "10.142.2.0/24"]
  private_subnets = ["10.142.10.0/24", "10.142.11.0/24"]

  # NAT handled by fck-nat instance instead of managed NAT gateway
  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS subnet discovery tags
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = local.common_tags
}

# fck-nat: cheap NAT instance replacing managed NAT gateway (~$3/mo vs ~$35/mo)
# https://fck-nat.dev
module "fck_nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "1.3.0"

  name      = "${var.cluster_name}-nat"
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.public_subnets[0]

  instance_type = "t4g.nano"
  ha_mode       = true

  # Automatically route private subnets through this NAT instance
  update_route_tables = true
  route_tables_ids = {
    for idx, rt_id in module.vpc.private_route_table_ids :
    "private-${idx}" => rt_id
  }

  tags = local.common_tags
}
