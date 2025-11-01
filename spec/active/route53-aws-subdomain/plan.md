# Implementation Plan: AWS Route53 Hosted Zone for aws.trakrf.id

Generated: 2025-11-01
Specification: spec.md

## Understanding

This plan implements DNS delegation for the `aws.trakrf.id` subdomain from Cloudflare to AWS Route53. The Route53 hosted zone will be managed in a new `aws/` directory, following the existing pattern established by `bootstrap/` and `domains/`. Cloudflare will delegate to Route53 using NS records that reference the Route53 nameservers via terraform_remote_state.

**Key architectural decisions:**
- Separate `aws/` directory for AWS resources (clean provider separation)
- Use Cloudflare R2 for Terraform state (consistent with existing setup)
- AWS provider uses CLI profile from `~/.aws/credentials` (no env var conflicts with R2 creds)
- Region: us-east-1 (for ACM/CloudFront compatibility)
- terraform_remote_state for cross-module reference (loose coupling)

## Complexity Assessment

**Score**: 6/10 (MEDIUM-HIGH)
- Files to create: 4 (2pts)
- Files to modify: 1 (0pts)
- Subsystems: 2 (1pt)
- Tasks: ~9 (2pts)
- Dependencies: 1 new provider (0pts)
- Pattern novelty: Adapting existing (1pt)

**Proceeding**: Infrastructure code with clear validation gates and atomic tasks.

## Relevant Files

### Reference Patterns (existing code to follow):

**Backend Configuration:**
- `domains/versions.tf` (lines 10-22) - S3 backend config for R2
  - Pattern: Skip validations, use R2 endpoint, region = "auto"
  - Use for: `aws/provider.tf` backend block

**Cloudflare Records:**
- `domains/main.tf` (lines 9-50) - cloudflare_record resources
  - Pattern: zone_id, name, content, type, proxied
  - Use for: `domains/aws-delegation.tf` NS records

**Variables:**
- `domains/variables.tf` (lines 1-22) - Variable definitions with descriptions
  - Pattern: type, description, optional default
  - Use for: Adding aws_access_key_id and aws_secret_access_key

**Justfile Commands:**
- `justfile` (lines 21-27) - domains command pattern
  - Pattern: init → plan -out=tfplan → apply tfplan
  - Use for: `just aws` command

**Provider Versions:**
- `bootstrap/versions.tf` (lines 1-9) - Terraform and provider versions
  - Pattern: required_providers block, required_version
  - Use for: `aws/provider.tf` versions block

### Files to Create:

- `aws/provider.tf` - Terraform versions, AWS provider, S3 backend for R2
- `aws/main.tf` - Route53 hosted zone resource
- `aws/outputs.tf` - Zone ID, nameservers, zone name outputs
- `aws/variables.tf` - (Optional) Future AWS-specific variables
- `domains/aws-delegation.tf` - Remote state data source + NS delegation records

### Files to Modify:

- `justfile` - Add `just aws` command (after line 27, before s3-ls)
- `domains/variables.tf` - Add aws_access_key_id and aws_secret_access_key variables

## Architecture Impact

- **Subsystems affected**:
  - AWS Route53 (new)
  - Cloudflare DNS (delegation records)
  - Terraform state management (R2 backend)

- **New dependencies**:
  - `hashicorp/aws` provider ~> 5.0

- **Breaking changes**: None
  - Additive changes only
  - No impact on existing DNS records

- **Cross-module dependency**:
  - `domains/` depends on `aws/` outputs via terraform_remote_state
  - Apply order: `just aws` MUST run before `just domains`

## Task Breakdown

### Task 1: Create aws/ directory structure
**Action**: CREATE
**Pattern**: Follow existing bootstrap/ and domains/ structure

**Implementation**:
```bash
mkdir -p aws/
```

**Validation**:
```bash
ls -la aws/
# Should exist and be empty
```

---

### Task 2: Create aws/provider.tf
**File**: `aws/provider.tf`
**Action**: CREATE
**Pattern**: Reference `domains/versions.tf` lines 1-23 and `bootstrap/versions.tf`

**Implementation**:
```hcl
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    endpoints = {
      s3 = "https://44e11a8ed610444ba0026bf7f710355d.r2.cloudflarestorage.com"
    }
    bucket = "tf-state"
    key    = "aws.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}

provider "aws" {
  region = "us-east-1"
  # Uses default profile from ~/.aws/credentials
  # This avoids conflict with AWS_* env vars used for R2 backend
}
```

**Key points**:
- Backend config matches `domains/versions.tf` pattern
- State file key is `aws.tfstate` (separate from domains)
- AWS provider region is us-east-1 (not "auto" like R2)
- Provider uses CLI profile, not env vars

**Validation**:
```bash
tofu -chdir=aws init
# Should succeed and show:
# - AWS provider downloaded
# - Backend initialized with R2
```

---

### Task 3: Create aws/main.tf
**File**: `aws/main.tf`
**Action**: CREATE
**Pattern**: Simple resource definition, similar to `domains/main.tf` cloudflare_zone

**Implementation**:
```hcl
resource "aws_route53_zone" "aws_subdomain" {
  name = "aws.trakrf.id"

  tags = {
    ManagedBy = "terraform"
    Project   = "trakrf-infra"
    Purpose   = "aws-service-dns"
  }
}
```

**Key points**:
- Zone name: "aws.trakrf.id" (subdomain of trakrf.id)
- Public hosted zone (default, no VPC config)
- Tags for tracking and identification

**Validation**:
```bash
tofu -chdir=aws validate
# Should show: Success! The configuration is valid.
```

---

### Task 4: Create aws/outputs.tf
**File**: `aws/outputs.tf`
**Action**: CREATE
**Pattern**: Export values needed by other modules

**Implementation**:
```hcl
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

**Key points**:
- `nameservers` output is critical - used by domains/ for NS records
- Route53 provides 4 nameservers automatically
- zone_id useful for other AWS resources later

**Validation**:
After apply, verify outputs exist:
```bash
tofu -chdir=aws output
# Should show zone_id, nameservers (4 values), zone_name
```

---

### Task 5: Add variables to domains/variables.tf
**File**: `domains/variables.tf`
**Action**: MODIFY
**Pattern**: Reference existing variable definitions (lines 1-22)

**Implementation**:
Add to end of file:
```hcl

variable "aws_access_key_id" {
  type        = string
  description = "AWS access key for R2 state backend (Cloudflare R2 credentials)"
  sensitive   = true
}

variable "aws_secret_access_key" {
  type        = string
  description = "AWS secret key for R2 state backend (Cloudflare R2 credentials)"
  sensitive   = true
}
```

**Key points**:
- These are R2 credentials (not AWS IAM)
- Marked sensitive to prevent output leakage
- Used by terraform_remote_state to read aws/ state from R2

**Validation**:
```bash
tofu -chdir=domains validate
# Should succeed (new variables defined but not required yet)
```

---

### Task 6: Create domains/aws-delegation.tf
**File**: `domains/aws-delegation.tf`
**Action**: CREATE
**Pattern**: Reference `domains/main.tf` for cloudflare_record, `domains/versions.tf` for S3 config

**Implementation**:
```hcl
# Read Route53 zone outputs from aws/ module via remote state
data "terraform_remote_state" "aws" {
  backend = "s3"

  config = {
    endpoints = {
      s3 = "https://${var.account_id}.r2.cloudflarestorage.com"
    }
    bucket = "tf-state"
    key    = "aws.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true

    access_key = var.aws_access_key_id
    secret_key = var.aws_secret_access_key
  }
}

# Create NS records in Cloudflare to delegate aws.trakrf.id to Route53
resource "cloudflare_record" "aws_subdomain_ns" {
  count = length(data.terraform_remote_state.aws.outputs.nameservers)

  zone_id = cloudflare_zone.domain.id
  name    = "aws"
  type    = "NS"
  content = data.terraform_remote_state.aws.outputs.nameservers[count.index]
  ttl     = 3600

  comment = "Delegate aws.trakrf.id to AWS Route53"
}
```

**Key points**:
- Remote state reads from same R2 bucket, different key (aws.tfstate)
- count = 4 (Route53 provides 4 nameservers)
- name = "aws" creates aws.trakrf.id subdomain
- TTL = 3600 (1 hour)
- comment explains delegation purpose

**Validation**:
```bash
tofu -chdir=domains validate
# Should succeed

tofu -chdir=domains plan
# Should show 4 NS records to create
```

---

### Task 7: Update justfile
**File**: `justfile`
**Action**: MODIFY
**Pattern**: Reference `justfile` lines 21-27 (domains command)

**Implementation**:
Add after the `domains:` recipe (after line 27), before `s3-ls:`:

```makefile

aws:
    @echo "Planning AWS infrastructure..."
    @tofu -chdir=aws init
    @tofu -chdir=aws plan -out=tfplan
    @tofu -chdir=aws apply tfplan
```

**Key points**:
- Same pattern as `just domains`
- No interactive prompt (consistent with domains)
- Automatic init → plan → apply flow

**Validation**:
```bash
just --list
# Should show "aws" in the list of available commands
```

---

### Task 8: Apply AWS infrastructure
**File**: N/A (execution task)
**Action**: RUN
**Command**: `just aws`

**Implementation**:
```bash
just aws
```

**Expected output**:
- Terraform init: Download AWS provider, initialize R2 backend
- Terraform plan: Show 1 resource to add (aws_route53_zone.aws_subdomain)
- Terraform apply: Create Route53 hosted zone
- Outputs: Display zone_id, 4 nameservers, zone_name

**Validation**:
```bash
# Verify zone created in AWS
aws route53 list-hosted-zones --query "HostedZones[?Name=='aws.trakrf.id.']"
# Should show the zone

# Verify outputs accessible
tofu -chdir=aws output nameservers
# Should show 4 AWS nameservers (e.g., ns-123.awsdns-12.com)
```

---

### Task 9: Apply Cloudflare delegation
**File**: N/A (execution task)
**Action**: RUN
**Command**: `just domains`

**Implementation**:
```bash
just domains
```

**Expected output**:
- Terraform init: Already initialized
- Terraform plan: Show 4 resources to add (cloudflare_record.aws_subdomain_ns[0-3])
- Terraform apply: Create 4 NS records in Cloudflare

**Validation**:
```bash
# Verify NS records in Terraform state
tofu -chdir=domains state list | grep aws_subdomain_ns
# Should show 4 records: cloudflare_record.aws_subdomain_ns[0-3]

# Verify outputs
tofu -chdir=domains plan
# Should show "No changes" (infrastructure up-to-date)
```

---

### Task 10: Validate DNS delegation
**File**: N/A (validation task)
**Action**: TEST
**Pattern**: Reference validation criteria from spec.md

**Implementation**:
Wait 1-5 minutes for DNS propagation, then test:

```bash
# Test 1: Verify NS records exist in Cloudflare
dig NS aws.trakrf.id @1.1.1.1

# Test 2: Verify NS records from public DNS
dig NS aws.trakrf.id @8.8.8.8

# Test 3: Create test record in Route53 (optional)
# Via AWS console or CLI:
# aws route53 change-resource-record-sets --hosted-zone-id <zone_id> ...

# Test 4: Verify test record resolves (if created)
# dig test.aws.trakrf.id @8.8.8.8
```

**Expected results**:
- dig NS should return 4 AWS nameservers (ns-*.awsdns-*.{com,net,org,co.uk})
- Nameservers should match Route53 zone outputs
- DNS resolution should work from multiple resolvers

**Success criteria**:
- [ ] NS records return Route53 nameservers
- [ ] DNS delegation working from public resolvers
- [ ] No SERVFAIL or NXDOMAIN errors

---

## Risk Assessment

### Risk 1: Cross-module dependency timing
**Description**: domains/ terraform_remote_state reads aws/ state from R2. If aws/ just applied, state might not be immediately available.

**Mitigation**:
- R2 has strong consistency, state should be immediately available
- If issues occur, wait 10 seconds and re-run `just domains`
- Document apply order: ALWAYS `just aws` before `just domains`

### Risk 2: DNS propagation delay
**Description**: NS delegation can take minutes to hours to propagate globally.

**Mitigation**:
- Expected: 1-5 minutes for most resolvers
- Maximum: 48 hours (rare)
- Test with multiple DNS resolvers (1.1.1.1, 8.8.8.8, local)
- Don't panic if immediate resolution fails - wait 5 minutes

### Risk 3: AWS credentials conflict
**Description**: AWS provider might use AWS_* env vars meant for R2, causing auth errors.

**Mitigation**:
- AWS provider uses CLI profile by default (takes precedence over env vars)
- Explicitly documented in provider.tf comments
- If issues occur, add `profile = "default"` to provider block

### Risk 4: Terraform state locking
**Description**: R2 backend doesn't support state locking - concurrent applies could corrupt state.

**Mitigation**:
- Solo developer setup - low risk
- Never run `just aws` and `just domains` concurrently
- If state corruption occurs, restore from R2 versioning

## Integration Points

### Terraform State
- New state file: `s3://tf-state/aws.tfstate` in R2
- Accessed by: domains/ via terraform_remote_state
- Backend: Same R2 bucket as bootstrap/ and domains/

### Cloudflare DNS
- New records: 4 NS records for aws.trakrf.id
- Zone: cloudflare_zone.domain (trakrf.id)
- Impact: No changes to existing records

### AWS Route53
- New resource: Hosted zone for aws.trakrf.id
- Outputs: zone_id, nameservers (consumed by domains/)
- Cost: $0.50/month + query charges

### action-spec project
- Will reference zone via data source:
  ```hcl
  data "aws_route53_zone" "aws_subdomain" {
    name = "aws.trakrf.id"
  }
  ```
- No terraform_remote_state needed (loose coupling)

## VALIDATION GATES (MANDATORY)

**Infrastructure validation commands:**

After each Terraform change:
```bash
# Gate 1: Syntax & Validation
tofu -chdir=<module> validate

# Gate 2: Plan Review
tofu -chdir=<module> plan

# Gate 3: Apply Verification
tofu -chdir=<module> apply
tofu -chdir=<module> output
```

**DNS validation:**
```bash
# Gate 4: NS Record Resolution
dig NS aws.trakrf.id @8.8.8.8

# Gate 5: State Consistency
tofu -chdir=domains state list | grep aws_subdomain_ns
tofu -chdir=aws state list | grep aws_route53_zone
```

**Enforcement Rules**:
- If validate fails → Fix syntax immediately
- If plan shows unexpected changes → Review before apply
- If apply fails → Check error, rollback if needed
- After 3 failed attempts → Stop and ask for help

**Do not proceed to next task until current task passes all gates.**

## Validation Sequence

### After each task (1-7):
```bash
# Syntax check
tofu -chdir=<module> validate

# Format check
tofu fmt -check <module>/
```

### After Task 8 (aws/ apply):
```bash
# Verify zone created
aws route53 list-hosted-zones --query "HostedZones[?Name=='aws.trakrf.id.']"

# Verify outputs
tofu -chdir=aws output
```

### After Task 9 (domains/ apply):
```bash
# Verify NS records created
tofu -chdir=domains state list | grep aws_subdomain_ns

# Plan should show no changes
tofu -chdir=domains plan
```

### After Task 10 (DNS validation):
```bash
# Verify delegation
dig NS aws.trakrf.id @8.8.8.8 +short

# Should return 4 AWS nameservers
```

### Final validation:
```bash
# All infrastructure up-to-date
just aws    # Should show "No changes"
just domains # Should show "No changes"

# DNS resolution working
dig NS aws.trakrf.id @1.1.1.1
dig NS aws.trakrf.id @8.8.8.8

# State files exist in R2
just s3-ls  # Should show aws.tfstate
```

## Plan Quality Assessment

**Complexity Score**: 6/10 (MEDIUM-HIGH)
- Well-scoped infrastructure task
- Multiple files but straightforward Terraform
- Cross-module dependency adds complexity

**Confidence Score**: 9/10 (HIGH)

**Confidence Factors**:
✅ Clear requirements from spec
✅ Similar patterns found in codebase (domains/versions.tf, domains/main.tf)
✅ All clarifying questions answered
✅ Existing R2 backend pattern to follow
✅ Simple DNS delegation (not complex logic)
✅ Terraform validation provides clear feedback
✅ AWS CLI credentials already configured
⚠️ terraform_remote_state pattern not currently used in codebase (new pattern)
⚠️ Cross-cloud dependency (Cloudflare R2 + AWS Route53)

**Assessment**: High confidence implementation. Terraform provides excellent validation feedback, existing patterns are clear, and the scope is well-defined. The only novelty is terraform_remote_state, but it's a standard Terraform pattern with good documentation.

**Estimated one-pass success probability**: 85%

**Reasoning**: Infrastructure-as-code with validation gates reduces risk significantly. The terraform_remote_state pattern is well-documented and the R2 S3-compatible backend config is already proven in domains/. Main risk is DNS propagation timing (environmental, not code issue). Very likely to succeed on first execution with minor tweaks possible for timing/validation.

## Apply Order (CRITICAL)

**MUST follow this sequence**:

1. **First**: `just aws` - Create Route53 zone and outputs
2. **Wait**: 10 seconds (ensure R2 state updated)
3. **Second**: `just domains` - Create Cloudflare NS records
4. **Wait**: 1-5 minutes (DNS propagation)
5. **Validate**: `dig NS aws.trakrf.id @8.8.8.8`

**Never run**: `just domains` before `just aws` (will fail - remote state not found)

## Success Criteria

- [ ] `aws/` directory created with 3 files (provider.tf, main.tf, outputs.tf)
- [ ] `domains/aws-delegation.tf` created
- [ ] `domains/variables.tf` updated with R2 credential variables
- [ ] `justfile` updated with `just aws` command
- [ ] `just aws` completes successfully
- [ ] Route53 zone exists with 4 nameservers
- [ ] `just domains` completes successfully
- [ ] 4 NS records created in Cloudflare
- [ ] `dig NS aws.trakrf.id` returns Route53 nameservers
- [ ] DNS delegation working from public resolvers
- [ ] All validation gates passed
- [ ] Documentation complete (this plan)

---

**Ready to build**: `/build`
