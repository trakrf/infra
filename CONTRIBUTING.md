# Contributing to TrakRF Infra

Thank you for your interest in contributing! This repo manages TrakRF's cloud infrastructure across Cloudflare, AWS (EKS), and GCP (GKE). We welcome improvements and feedback.

## Ways to Contribute

### 1. Report Issues
- Found a bug? [Open an issue](https://github.com/trakrf/infra/issues)
- Have a feature request? Describe your use case
- Documentation unclear? Let us know what's confusing

### 2. Submit Pull Requests
- Fix bugs or typos
- Add new infrastructure modules
- Improve documentation
- Enhance security or error handling

### 3. Share Your Experience
- How are you using these patterns?
- What works well? What doesn't?
- Share your custom infrastructure patterns

## Development Setup

### Prerequisites
- Git
- [OpenTofu](https://opentofu.org/docs/intro/) (or Terraform)
- [just](https://github.com/casey/just) command runner
- [direnv](https://direnv.net/) for environment management
- Cloud CLI tools as needed (AWS CLI, gcloud, wrangler)

### Getting Started

1. **Clone and configure**
   ```bash
   git clone https://github.com/trakrf/infra
   cd infra
   cp .env.local.example .env.local  # Add your credentials
   direnv allow
   ```

2. **Validate infrastructure code**
   ```bash
   tofu -chdir=domains validate
   tofu -chdir=aws validate
   ```

3. **Test in isolated environment**
   - Use separate cloud accounts for testing
   - Enable budget alarms to prevent cost surprises
   - Review all infrastructure changes before applying
   - Clean up resources after testing

## Contribution Guidelines

### Code Style
- **Terraform/OpenTofu**: Follow [HashiCorp Style Guide](https://developer.hashicorp.com/terraform/language/style)
- **Helm charts**: Follow [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)
- **Shell scripts**: Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- **YAML**: Consistent 2-space indentation
- **Markdown**: Clear headings, consistent formatting

### Commit Messages
Follow [Conventional Commits](https://www.conventionalcommits.org/):
```
feat: add EKS node group autoscaling
fix: correct IAM policy for ArgoCD
docs: update cluster setup instructions
chore: update provider versions
```

### Pull Request Process

1. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**
   - Keep changes focused and atomic
   - Update documentation as needed
   - Add examples if introducing new features

3. **Test thoroughly**
   - Run `tofu validate` and `tofu fmt -check`
   - Run `tofu plan` to verify expected changes
   - Check for exposed secrets or credentials

4. **Submit PR**
   - Provide clear description of changes
   - Link to related issues
   - Include `tofu plan` output for infrastructure changes
   - PRs are merged with `--merge` (no squash or rebase)

5. **Respond to feedback**
   - Address review comments
   - Be open to suggestions

## Security Considerations

When contributing:
- **Never commit real credentials** (API tokens, keys, passwords)
- **Use `.env.local`** for secrets (gitignored)
- **Review all infrastructure changes** before submitting
- **Report security issues** via [GitHub Security Advisories](https://github.com/trakrf/infra/security/advisories/new)
- See [SECURITY.md](SECURITY.md) for full security policy

## Questions?

- Open a discussion in [GitHub Issues](https://github.com/trakrf/infra/issues)
- Check existing issues for similar questions

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
