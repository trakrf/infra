# Security Policy

## Overview

TrakRF Infra is an open-source infrastructure repository containing Terraform/OpenTofu modules, Helm charts, and GitOps manifests for managing cloud infrastructure across Cloudflare, AWS, and GCP.

## Reporting a Vulnerability

### How to Report

If you discover a security vulnerability, please report it via:

1. **Preferred**: [GitHub Security Advisories](https://github.com/trakrf/infra/security/advisories/new)
2. **Alternative**: Email admin@trakrf.id

**Please do not open public issues for security vulnerabilities.**

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if known)

### Response Timeline

**Best effort** - This is a small-team project:
- We'll acknowledge receipt as soon as possible
- Fixes will be prioritized based on severity
- No guaranteed timeline for patches

### Safe Harbor

We support responsible disclosure and will not take legal action against security researchers who:
- Report vulnerabilities in good faith
- Avoid privacy violations and service disruption
- Give us reasonable time to address issues before public disclosure

## Scope

### In Scope
- Exposed secrets or credentials in code, config, or git history
- Vulnerabilities in Terraform/OpenTofu modules
- Security issues in Helm charts or Kubernetes manifests
- Insecure defaults in infrastructure configuration
- Security issues in GitHub Actions workflows
- Documentation errors that could lead to insecure deployments

### Out of Scope
- Issues in upstream providers (Cloudflare, AWS, GCP)
- Rate limiting on demo/staging endpoints
- Social engineering attempts

## Security Best Practices for Users

When using this repo:
- **Never commit real credentials** - Use `.env.local` (gitignored)
- **Review all infrastructure code** before deploying
- **Use separate cloud accounts** for testing
- **Enable budget alarms** to prevent cost surprises
- **Rotate credentials regularly**
- **Use least-privilege IAM policies**

### Running Security Checks Locally

```bash
# Check for secrets (requires trufflehog)
trufflehog filesystem . --only-verified

# Validate Terraform
tofu fmt -check -recursive
tofu validate

# Check for hardcoded IDs or IPs
grep -r --exclude-dir={.terraform,.git,node_modules} \
  -E "[0-9]{12}" \
  --include="*.tf" --include="*.tfvars"
```

## Security Hall of Fame

We recognize and thank security researchers who responsibly disclose vulnerabilities:

_No entries yet. Be the first to responsibly disclose a security issue!_

---

**Last Updated**: 2026-04-09
