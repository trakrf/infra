# Feature: AWS Route53 Hosted Zone for aws.trakrf.id

## Origin
This specification addresses the need to delegate the `aws.trakrf.id` subdomain to AWS Route53 for managing AWS service DNS records, starting with an App Runner instance for the action-spec project.

## Outcome
The subdomain `aws.trakrf.id` will be delegated to AWS Route53, enabling native AWS service integration and supporting a multi-cloud DNS architecture. The Route53 hosted zone will be managed via Terraform in this repository, while individual DNS records will be managed separately (in action-spec or other app-specific repos via `data` source lookups).

## User Story
As a platform engineer
I want to delegate aws.trakrf.id to AWS Route53
So that I can seamlessly integrate AWS services with native DNS management while maintaining infrastructure-as-code for the zone delegation

## Context

**Discovery**:
- Immediate need: App Runner instance for action-spec project
- Future scope: Eventually all AWS services (EC2/ELB, API Gateway, S3/CloudFront, RDS/Database)
- Strategic: Both AWS service integration AND multi-cloud architecture
- Principle: "If you'll want it tomorrow, Terraform it today" - no manual zone creation

**Current**:
- All DNS for trakrf.id is managed in Cloudflare
- Infrastructure is 100% Cloudflare (Pages, DNS, Email Routing)
- No AWS provider in Terraform configuration
- AWS credentials exist in `~/.aws/credentials` (default profile)
- Terraform state stored in Cloudflare R2 bucket

**Desired**:
- Route53 hosted zone for aws.trakrf.id subdomain
- NS delegation from Cloudflare → Route53
- AWS provider added to Terraform
- Zone managed in trakrf-infra, records managed in action-spec (via data source)
- Continue using Cloudflare R2 for Terraform state

## Technical Requirements

### Infrastructure Changes

#### 1. AWS Provider Setup
- Add AWS Terraform provider to project
- Use AWS CLI profile for credentials (`~/.aws/credentials` default profile)
- Override region to `us-east-1` (for ACM compatibility with CloudFront)
- Provider location: new `aws/` directory (separate from `domains/`)

**Rationale for us-east-1**:
- ACM certificates for CloudFront must be in us-east-1
- Convention for global services
- Route53 is global, but consistency matters for future resources

**Credentials approach**:
- Use AWS CLI profile (already configured)
- No additional environment variables needed
- Provider will use default profile from `~/.aws/credentials`

#### 2. Route53 Hosted Zone
- Create `aws_route53_zone.aws_subdomain` resource
- Zone name: `aws.trakrf.id`
- Public hosted zone (not private VPC)
- Export zone ID and nameservers as outputs

#### 3. Cloudflare NS Delegation
- Add `cloudflare_record` resources for NS records in `domains/`
- Type: NS
- Name: `aws` (creates aws.trakrf.id)
- Values: Route53 nameservers (referenced from aws/ outputs)
- TTL: 3600

**Cross-module reference**:
```hcl
# domains/ needs to reference aws/ outputs
# Use terraform_remote_state or move both into single config
```

#### 4. Terraform State Backend
- Continue using Cloudflare R2 for state storage
- Same backend config as existing `bootstrap/` and `domains/`
- State file: `aws.tfstate` (separate from domains.tfstate)

**Rationale**:
- ✅ Consistency with existing setup
- ✅ No need to bootstrap AWS S3/DynamoDB
- ✅ For "just DNS", cross-cloud dependency is negligible
- ❌ Small risk: Cloudflare outage blocks Terraform operations (acceptable)

#### 5. Just Command
- Add `just aws` command for AWS resource management
- Similar to existing `just domains` and `just bootstrap`

### Implementation Approach: Hybrid

**This repo (trakrf-infra)**:
- Route53 zone resource in `aws/`
- Cloudflare NS delegation records in `domains/`

**action-spec (and other projects)**:
- Reference zone via data source:
  ```hcl
  data "aws_route53_zone" "aws_subdomain" {
    name = "aws.trakrf.id"
  }

  resource "aws_route53_record" "app" {
    zone_id = data.aws_route53_zone.aws_subdomain.zone_id
    # ...
  }
  ```

**Benefits**:
- ✅ Loose coupling - no terraform_remote_state dependencies
- ✅ Works even if zone created manually
- ✅ Each app manages own DNS records

### Directory Structure

```
trakrf-infra/
├── bootstrap/          # Cloudflare R2 + API tokens
├── domains/            # Cloudflare resources
│   ├── main.tf         # Zone + DNS records
│   ├── aws-delegation.tf  # NEW: NS records for aws.trakrf.id
│   └── ...
├── aws/                # NEW: AWS resources
│   ├── main.tf         # Route53 zone
│   ├── provider.tf     # AWS provider + backend config
│   ├── outputs.tf      # Zone ID, nameservers
│   └── terraform.tfvars (optional)
├── spec/
└── .env.local
```

**Module separation rationale**:
- Clean separation of cloud providers
- Independent apply cycles (`just domains` vs `just aws`)
- Room for future AWS resources (S3, ECR, etc.)

### Cross-Module Reference Challenge

**Problem**: `domains/` needs NS values from `aws/`

**Options**:
1. **Manual coordination**: Apply aws/, copy NS values, update domains/
2. **terraform_remote_state**: domains/ reads aws/ state from R2
3. **Unified config**: Merge aws/ and domains/ into single Terraform config

**Recommendation**: Option 2 (terraform_remote_state)
```hcl
# domains/aws-delegation.tf
data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket = "tf-state"
    key    = "aws.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://${var.account_id}.r2.cloudflarestorage.com"
    }
    # ... other S3-compatible config
  }
}

resource "cloudflare_record" "aws_subdomain_ns" {
  count   = length(data.terraform_remote_state.aws.outputs.nameservers)
  zone_id = cloudflare_zone.domain.id
  name    = "aws"
  type    = "NS"
  content = data.terraform_remote_state.aws.outputs.nameservers[count.index]
  ttl     = 3600
}
```

## Code Examples

### AWS Provider
```hcl
# aws/provider.tf
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "tf-state"
    key    = "aws.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true

    endpoints = {
      s3 = "https://44e11a8ed610444ba0026bf7f710355d.r2.cloudflarestorage.com"
    }
  }
}

provider "aws" {
  region = "us-east-1"  # Override default us-west-2 for Route53/ACM
  # Uses default profile from ~/.aws/credentials
}
```

### Route53 Zone
```hcl
# aws/main.tf
resource "aws_route53_zone" "aws_subdomain" {
  name = "aws.trakrf.id"

  tags = {
    ManagedBy = "terraform"
    Project   = "trakrf-infra"
    Purpose   = "aws-service-dns"
  }
}
```

### Outputs
```hcl
# aws/outputs.tf
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
```

### Cloudflare NS Delegation
```hcl
# domains/aws-delegation.tf
data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket = "tf-state"
    key    = "aws.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true

    endpoints = {
      s3 = "https://${var.account_id}.r2.cloudflarestorage.com"
    }

    access_key = var.aws_access_key_id
    secret_key = var.aws_secret_access_key
  }
}

resource "cloudflare_record" "aws_subdomain_ns" {
  count   = length(data.terraform_remote_state.aws.outputs.nameservers)

  zone_id = cloudflare_zone.domain.id
  name    = "aws"
  type    = "NS"
  content = data.terraform_remote_state.aws.outputs.nameservers[count.index]
  ttl     = 3600

  comment = "Delegate aws.trakrf.id to AWS Route53"
}
```

### Just Command
```makefile
# justfile
# Apply AWS infrastructure
aws:
    @echo "Planning AWS infrastructure..."
    tofu -chdir=aws init
    tofu -chdir=aws plan
    @echo "Apply? (Ctrl+C to cancel)"
    @read
    tofu -chdir=aws apply
```

## Validation Criteria
- [ ] AWS provider configured with us-east-1 region
- [ ] Route53 hosted zone created successfully
- [ ] Zone ID and nameservers exported in Terraform outputs
- [ ] Cloudflare terraform_remote_state can read aws/ outputs
- [ ] NS records added to Cloudflare for aws.trakrf.id
- [ ] DNS delegation verified: `dig NS aws.trakrf.id @8.8.8.8` returns Route53 nameservers
- [ ] DNS propagation complete (check with `dig NS aws.trakrf.id` from multiple resolvers)
- [ ] Test record creation in Route53: `test.aws.trakrf.id A 1.2.3.4`
- [ ] Test record resolution: `dig test.aws.trakrf.id @8.8.8.8` resolves correctly
- [ ] Just command works: `just aws` successfully applies
- [ ] action-spec can reference zone via data source

## Conversation References
- **Use cases**: "EC2/ELB services, API Gateway, S3/CloudFront, RDS/Database, sooner or later all of the above. today i'm adding an app runner instance"
- **Strategy**: Both AWS service integration AND multi-cloud DNS strategy
- **Implementation**: Hybrid approach - zone in Terraform, records managed separately
- **Region choice**: us-east-1 despite preference to avoid it - "ACM being there makes my point, but it also indicates that it's the right choice"
- **Credentials**: AWS CLI default profile in ~/.aws/credentials (exists)
- **State backend**: Cloudflare R2 - "since its just DNS setup i think OK to just cloudflare"
- **Data source pattern**: "all other resources will look up this zone with a `data` from other tf states"

## Decisions Made

1. **Region**: us-east-1 (for ACM/CloudFront compatibility)
2. **Credentials**: Use AWS CLI default profile (no env vars needed)
3. **State backend**: Cloudflare R2 (consistency, simplicity)
4. **Directory structure**: Separate `aws/` directory
5. **Cross-module reference**: terraform_remote_state from domains/ → aws/
6. **Record management**: Data source lookups from other repos (action-spec)

## Open Questions

1. **terraform_remote_state S3 config**: Confirm R2 credentials in domains/ config (use existing vars)
2. **Apply order**: Should `just domains` depend on `just aws` automatically, or manual coordination?
3. **Justfile integration**: Separate `just aws` or combined `just infra` that does both?

## Dependencies

- ✅ AWS account with Route53 access (confirmed via ~/.aws/credentials)
- ✅ AWS CLI configured with default profile
- ✅ Existing Cloudflare zone for trakrf.id
- ✅ Cloudflare R2 state backend (already configured)

## Risks & Considerations

- **Cross-module dependency**: domains/ depends on aws/ outputs
  - Mitigation: Clear apply order documentation, or use `depends_on` metadata
- **DNS propagation delay**: NS delegation takes time (typically <1h, up to 48h)
- **Terraform state coordination**: terraform_remote_state reads from R2
  - Risk: Stale reads if aws/ just applied
  - Mitigation: Add refresh in domains/ or manual wait
- **Cost**: Route53 hosted zone = $0.50/month + query charges (~$0.40/million queries)
- **Credential management**: AWS CLI profile uses access keys
  - Alternative: AWS SSO (more secure, more complex)

## Success Metrics

- [ ] DNS delegation working end-to-end
- [ ] action-spec can create DNS records in aws.trakrf.id
- [ ] No manual DNS configuration required
- [ ] All infrastructure defined in code
- [ ] Documentation complete for cross-repo usage
