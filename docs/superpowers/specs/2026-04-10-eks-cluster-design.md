# EKS Cluster Provisioning — Design Spec

**Linear issue:** [TRA-352](https://linear.app/trakrf/issue/TRA-352)
**Date:** 2026-04-10
**Author:** Mike Stankavich
**Status:** Draft

## Goal

Provision an EKS cluster in AWS us-east-2 as the Kubernetes foundation for TrakRF + Voreas portfolio workloads. This is Milestone 1 of the platform build (TRA-351).

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Region | us-east-2 (Ohio) | User preference |
| State backend | Cloudflare R2 (existing) | Consistent with repo, already wired up. No locking — acceptable for small team. Migrate to S3+DynamoDB later if needed. |
| IaC tool | OpenTofu | Existing repo standard |
| EKS modules | `terraform-aws-modules/eks/aws`, `terraform-aws-modules/vpc/aws` | Community standard, not a shortcut |
| Node type | Managed node group (not Fargate) | Need full node access for CrunchyData operator + persistent volumes |
| Instance | t3.xlarge spot | Enough for PG operator + app + monitoring. Spot for cost. Document on-demand for prod. |
| Node count | min 1 / max 3 / desired 1 | Single node for demo |
| K8s version | 1.31 | Latest stable |
| IRSA | Stub roles upfront | OIDC provider is cluster-level, easier now than retrofit |
| Load balancer | None (port-forward for demo) | AWS LB Controller is out of scope |
| Auth | Static IAM credentials | Authentik/OIDC for human access is a separate project |

## Credential & Backend Cleanup

The repo currently sets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `.env.local` for R2 backend access. This conflicts with real AWS credentials in `~/.aws/credentials`.

**Changes:**

1. Add `[cloudflare-r2]` profile to `~/.aws/credentials` with R2 access keys
2. Remove `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from `.env.local`
3. Add `profile = "cloudflare-r2"` to S3 backend config in both terraform roots
4. AWS provider in `terraform/aws/` uses `profile = "default"` targeting `us-east-2`
5. Update justfile to remove `AWS_DEFAULT_REGION` export (no longer needed globally)
6. Remove stale `fabric-sandbox` SSO profile from `~/.aws/config`

## Architecture

### Networking — `vpc.tf`

Uses `terraform-aws-modules/vpc/aws`:

- CIDR: `10.142.0.0/16` (non-default second octet to avoid collisions)
- 2 AZs: `us-east-2a`, `us-east-2b`
- Public subnets: `10.142.1.0/24`, `10.142.2.0/24` (NAT gateway, future LB)
- Private subnets: `10.142.10.0/24`, `10.142.11.0/24` (EKS nodes)
- Single NAT gateway (cost savings, acceptable for demo)
- Subnet tags for EKS discovery:
  - Public: `kubernetes.io/role/elb = 1`
  - Private: `kubernetes.io/role/internal-elb = 1`
  - Both: `kubernetes.io/cluster/<name> = shared`

### Cluster — `eks.tf`

Uses `terraform-aws-modules/eks/aws`:

- Cluster name: `trakrf-demo`
- K8s version: `1.31`
- Endpoint access: public + private (public for kubectl from dev machines, private for node comms)
- Managed node group `general`:
  - Instance type: `t3.xlarge`
  - Capacity type: `SPOT`
  - Scaling: min 1 / max 3 / desired 1
  - Disk: 50 GB gp3
- Cluster addons:
  - `vpc-cni` — pod networking
  - `coredns` — cluster DNS
  - `kube-proxy` — service networking
  - `aws-ebs-csi-driver` — persistent volumes (required for CrunchyData PG)

### IAM & IRSA — `iam.tf`

The EKS module creates the OIDC provider automatically. We define stub IRSA roles:

- **EBS CSI Driver** — `AmazonEBSCSIDriverPolicy` attached (functional, needed for PVs)
- **CrunchyData** — namespace `crunchy-system`, empty policy (placeholder until operator deployed)
- **ArgoCD** — namespace `argocd`, empty policy (placeholder until ArgoCD deployed)

Each role's trust policy restricts assumption to the specific K8s service account + namespace.

### Container Registry — `ecr.tf`

- Repository: `trakrf-backend`
- Image tag mutability: immutable (production traceability)
- Scan on push: enabled
- Lifecycle policy: expire untagged images after 14 days, keep last 10 tagged images

### Outputs — `outputs.tf`

- `cluster_name` — EKS cluster name
- `cluster_endpoint` — API server URL
- `cluster_certificate_authority` — CA data for kubeconfig
- `kubectl_config_command` — ready-to-run `aws eks update-kubeconfig` command
- `ecr_repository_url` — for docker push
- `irsa_role_arns` — map of role ARNs for Helm values

### Cost Tags

All resources tagged:

```
Project     = "trakrf"
Environment = "demo"
ManagedBy   = "terraform"
Ticket      = "TRA-352"
```

## File Structure

```
terraform/aws/
├── main.tf          # Provider config, backend
├── vpc.tf           # VPC module call
├── eks.tf           # EKS module call + node group
├── iam.tf           # IRSA stub roles
├── ecr.tf           # Container registry
├── outputs.tf       # Cluster + ECR outputs
├── variables.tf     # Parameterized config
└── versions.tf      # Provider + module version constraints
```

## What Transfers from Reference Projects

| Reference (`eks-ref/`) | EKS Equivalent |
|------------------------|----------------|
| `poc-deploy/vpc/` (manual VPC) | `terraform-aws-modules/vpc/aws` module (simpler) |
| `modules/backend/` (S3+DynamoDB) | Skipped — using R2 backend |
| `poc-deploy/ecr/` | Same pattern, adapted |
| ECS task execution IAM roles | EKS node group role + IRSA |
| ALB + target group | Skipped for demo (port-forward) |
| Security groups (HTTP/container) | EKS module manages SGs |

## Cost Estimate

| Component | Monthly |
|-----------|---------|
| EKS control plane | ~$75 |
| t3.xlarge spot (1 node) | ~$40-60 |
| NAT gateway + data | ~$35 |
| ECR storage | <$1 |
| **Total** | **~$150-170/mo** |

## Out of Scope

- GKE terraform root (M2)
- Multi-AZ node groups (document only)
- AWS Load Balancer Controller (port-forward for demo)
- Crossplane
- Authentik / OIDC for human auth
- S3+DynamoDB state backend migration

## Acceptance Criteria

- `tofu apply` produces a running EKS cluster in us-east-2
- `kubectl get nodes` returns healthy node(s)
- IRSA roles created for CrunchyData and ArgoCD workloads
- ECR repository created and accessible from cluster
- State stored in R2 (existing backend)
- All resources tagged for cost tracking
- No credential conflicts between R2 backend and AWS provider
