# Cloudflare Pages project for trakrf.id website
resource "cloudflare_pages_project" "www" {
  account_id        = var.account_id
  name              = "www"
  production_branch = "main"

  build_config {
    build_command   = "pnpm build"
    destination_dir = "dist"
    root_dir        = ""
  }

  source {
    type = "github"
    config {
      owner                         = "trakrf"
      repo_name                     = "www"
      production_branch             = "main"
      pr_comments_enabled           = true
      deployments_enabled           = true
      production_deployment_enabled = true
      preview_deployment_setting    = "all"
    }
  }

  deployment_configs {
    preview {
      environment_variables = {}
    }
    production {
      environment_variables = {}
    }
  }
}

# Custom domain for the Pages project (production)
resource "cloudflare_pages_domain" "www_custom" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.www.name
  domain       = var.domain_name
}

# Custom domain for preview subdomain
resource "cloudflare_pages_domain" "preview_custom" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.www.name
  domain       = "preview.${var.domain_name}"
}

# Output the Pages URL
output "pages_url" {
  value       = cloudflare_pages_project.www.subdomain
  description = "Cloudflare Pages URL for the www project"
}
