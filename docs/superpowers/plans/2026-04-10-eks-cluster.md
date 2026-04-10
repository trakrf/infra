# EKS Cluster Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision an EKS cluster in us-east-2 with VPC, managed node group, IRSA stubs, and ECR, using community Terraform modules.

**Architecture:** VPC with public/private subnets across 2 AZs feeds into an EKS cluster running a single spot t3.xlarge managed node group. IRSA roles are stubbed for future CrunchyData and ArgoCD workloads. EBS CSI driver addon is configured separately to avoid circular module dependencies. State lives in the existing R2 backend.

**Tech Stack:** OpenTofu, terraform-aws-modules/vpc/aws, terraform-aws-modules/eks/aws, terraform-aws-modules/iam/aws (IRSA submodule), AWS provider ~> 5.0

**Spec:** `docs/superpowers/specs/2026-04-10-eks-cluster-design.md`

**Pre-requisite (already completed):** Credential cleanup — R2 keys moved to `[cloudflare-r2]` AWS CLI profile, `AWS_*` env vars removed from `.env.local`, backend configs updated with `profile = "cloudflare-r2"`, AWS provider set to `us-east-2` with `profile = "default"`.

---

### Task 1: Variables and Common Tags

**Files:**
- Create: `terraform/aws/variables.tf`
- Modify: `terraform/aws/main.tf` (add locals block for common tags)

- [ ] **Step 1: Create variables.tf**

```hcl
variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
  default     = "trakrf-demo"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for the EKS cluster"
  default     = "1.31"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.142.0.0/16"
}

variable "environment" {
  type        = string
  description = "Environment name for tagging"
  default     = "demo"
}

variable "project" {
  type        = string
  description = "Project name for tagging"
  default     = "trakrf"
}
```

- [ ] **Step 2: Add locals block to main.tf**

Add at the top of `terraform/aws/main.tf`, before the Route53 zone resource:

```hcl
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
```

- [ ] **Step 3: Add common tags to existing Route53 zone**

Update the `aws_route53_zone.aws_subdomain` resource in `terraform/aws/main.tf` to merge common tags:

```hcl
resource "aws_route53_zone" "aws_subdomain" {
  name = "aws.trakrf.id"

  tags = merge(local.common_tags, {
    Purpose = "aws-service-dns"
  })
}
```

- [ ] **Step 4: Run tofu plan to validate**

Run: `tofu -chdir=terraform/aws plan`

Expected: Plan shows Route53 zone tag changes only (in-place update). No errors.

- [ ] **Step 5: Commit**

```bash
git add terraform/aws/variables.tf terraform/aws/main.tf
git commit -m "feat(aws): add variables and common tags for EKS provisioning"
```

---

### Task 2: VPC

**Files:**
- Create: `terraform/aws/vpc.tf`

- [ ] **Step 1: Create vpc.tf**

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = ["10.142.1.0/24", "10.142.2.0/24"]
  private_subnets = ["10.142.10.0/24", "10.142.11.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
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
```

- [ ] **Step 2: Run tofu init to download VPC module**

Run: `just _backend-conf terraform/aws && tofu -chdir=terraform/aws init -backend-config=backend.conf -upgrade`

Expected: Downloads `terraform-aws-modules/vpc/aws`. No errors.

- [ ] **Step 3: Run tofu plan to validate VPC**

Run: `tofu -chdir=terraform/aws plan`

Expected: Plan shows ~20-25 resources to create (VPC, subnets, NAT gateway, internet gateway, route tables, EIPs). No errors.

- [ ] **Step 4: Commit**

```bash
git add terraform/aws/vpc.tf terraform/aws/.terraform.lock.hcl
git commit -m "feat(aws): add VPC with public/private subnets for EKS"
```

---

### Task 3: EKS Cluster and Node Group

**Files:**
- Create: `terraform/aws/eks.tf`

- [ ] **Step 1: Create eks.tf with cluster and managed node group**

```hcl
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
```

- [ ] **Step 2: Run tofu init to download EKS module**

Run: `tofu -chdir=terraform/aws init -backend-config=backend.conf -upgrade`

Expected: Downloads `terraform-aws-modules/eks/aws`. No errors.

- [ ] **Step 3: Run tofu plan to validate EKS**

Run: `tofu -chdir=terraform/aws plan`

Expected: Plan shows EKS cluster, node group, security groups, OIDC provider, IAM roles. ~40+ resources total. No errors.

- [ ] **Step 4: Commit**

```bash
git add terraform/aws/eks.tf terraform/aws/.terraform.lock.hcl
git commit -m "feat(aws): add EKS cluster with spot managed node group"
```

---

### Task 4: IRSA Roles and EBS CSI Addon

**Files:**
- Create: `terraform/aws/iam.tf`
- Modify: `terraform/aws/eks.tf` (add EBS CSI addon resource)

- [ ] **Step 1: Create iam.tf with IRSA roles**

```hcl
# EBS CSI Driver — functional role needed for persistent volumes
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi-controller"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}

# CrunchyData operator — stub role, policies added when operator is deployed
module "crunchy_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-crunchy-operator"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["crunchy-system:crunchy-operator"]
    }
  }

  tags = local.common_tags
}

# ArgoCD — stub role, policies added when ArgoCD is deployed
module "argocd_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-argocd"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["argocd:argocd-server"]
    }
  }

  tags = local.common_tags
}
```

- [ ] **Step 2: Add standalone EBS CSI addon to eks.tf**

Append to the bottom of `terraform/aws/eks.tf`:

```hcl
# EBS CSI driver defined outside the EKS module to avoid circular dependency
# (addon needs IRSA role ARN, IRSA role needs OIDC provider ARN from EKS module)
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"

  tags = local.common_tags
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}
```

- [ ] **Step 3: Run tofu init to download IAM module**

Run: `tofu -chdir=terraform/aws init -backend-config=backend.conf -upgrade`

Expected: Downloads `terraform-aws-modules/iam/aws` IRSA submodule. No errors.

- [ ] **Step 4: Run tofu plan to validate IRSA + EBS CSI**

Run: `tofu -chdir=terraform/aws plan`

Expected: Plan shows 3 IRSA roles + EBS CSI addon in addition to previous resources. No errors.

- [ ] **Step 5: Commit**

```bash
git add terraform/aws/iam.tf terraform/aws/eks.tf terraform/aws/.terraform.lock.hcl
git commit -m "feat(aws): add IRSA roles and EBS CSI driver addon"
```

---

### Task 5: ECR Repository

**Files:**
- Create: `terraform/aws/ecr.tf`

- [ ] **Step 1: Create ecr.tf**

```hcl
resource "aws_ecr_repository" "backend" {
  name                 = "trakrf-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v"]
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
```

- [ ] **Step 2: Run tofu plan to validate ECR**

Run: `tofu -chdir=terraform/aws plan`

Expected: Plan shows ECR repository + lifecycle policy in addition to previous resources. No errors.

- [ ] **Step 3: Commit**

```bash
git add terraform/aws/ecr.tf
git commit -m "feat(aws): add ECR repository for trakrf-backend"
```

---

### Task 6: Outputs

**Files:**
- Modify: `terraform/aws/outputs.tf`

- [ ] **Step 1: Update outputs.tf**

Replace the entire file. Keep existing Route53 outputs and add EKS, ECR, and IRSA outputs:

```hcl
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
  value       = "aws eks update-kubeconfig --region us-east-2 --name ${module.eks.cluster_name}"
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
```

- [ ] **Step 2: Run tofu plan to validate full config**

Run: `tofu -chdir=terraform/aws plan -out=tfplan`

Expected: Complete plan with all resources. Save plan to tfplan for apply. Note the total resource count. No errors.

- [ ] **Step 3: Commit**

```bash
git add terraform/aws/outputs.tf
git commit -m "feat(aws): add EKS, ECR, and IRSA outputs"
```

---

### Task 7: Apply and Verify

**Files:** None (operational steps)

- [ ] **Step 1: Review the saved plan**

Run: `tofu -chdir=terraform/aws show tfplan`

Review the plan output. Confirm it includes: VPC, subnets, NAT gateway, EKS cluster, managed node group, OIDC provider, 3 IRSA roles, EBS CSI addon, ECR repository. All resources tagged.

- [ ] **Step 2: Apply**

Run: `tofu -chdir=terraform/aws apply tfplan`

Expected: All resources created successfully. EKS cluster creation takes ~10-15 minutes. The apply will output cluster endpoint, ECR URL, and IRSA role ARNs.

- [ ] **Step 3: Configure kubectl**

Run: `aws eks update-kubeconfig --region us-east-2 --name trakrf-demo`

Expected: `Added new context arn:aws:eks:us-east-2:252374924199:cluster/trakrf-demo to ...`

- [ ] **Step 4: Verify cluster health**

Run: `kubectl get nodes`

Expected: One node in `Ready` status (may take 2-3 minutes after apply for node to join).

Run: `kubectl get pods -A`

Expected: CoreDNS, kube-proxy, vpc-cni, and ebs-csi pods running in `kube-system`.

- [ ] **Step 5: Verify ECR access from cluster**

Run: `aws ecr describe-repositories --region us-east-2 --repository-names trakrf-backend`

Expected: Repository exists with `imageScanningConfiguration.scanOnPush = true` and `imageTagMutability = IMMUTABLE`.

- [ ] **Step 6: Verify IRSA roles**

Run: `aws iam list-roles --region us-east-2 | grep -E "trakrf-demo-(ebs-csi|crunchy|argocd)"`

Expected: Three roles listed: `trakrf-demo-ebs-csi-controller`, `trakrf-demo-crunchy-operator`, `trakrf-demo-argocd`.

- [ ] **Step 7: Verify cost tags**

Run: `aws eks describe-cluster --name trakrf-demo --region us-east-2 --query 'cluster.tags'`

Expected: Tags include `Project=trakrf`, `Environment=demo`, `ManagedBy=terraform`, `Ticket=TRA-352`.

- [ ] **Step 8: Commit lock file and plan state**

```bash
git add terraform/aws/.terraform.lock.hcl
git commit -m "chore(aws): update lock file after EKS apply"
```

---

### Rollback

If the apply fails partway through or costs need to be contained:

```bash
tofu -chdir=terraform/aws destroy
```

This tears down everything created by this plan. State in R2 is updated automatically. The Route53 zone (pre-existing) is not affected because it was already in state before this plan.
