resource "cloudflare_r2_bucket" "terraform_state" {
  account_id = var.account_id
  name       = var.bucket_name
  location   = "WNAM"  # North America location
}

# Create an R2 API token for the bucket
resource "cloudflare_api_token" "terraform_state" {
  name = "${var.bucket_name}-access-token"

  policy {
    permission_groups = [
      data.cloudflare_api_token_permission_groups.all.r2["Workers R2 Storage Bucket Item Read"],
      data.cloudflare_api_token_permission_groups.all.r2["Workers R2 Storage Bucket Item Write"]
    ]
    resources = {
      "com.cloudflare.edge.r2.bucket.${var.account_id}_default_${var.bucket_name}" = "*"
    }
  }
}

# Token for infrastructure management
resource "cloudflare_api_token" "terraform_infrastructure" {
  name = "terraform-infrastructure"

  policy {
    permission_groups = [
      data.cloudflare_api_token_permission_groups.all.zone[
      "Zone Read"
      ],
      data.cloudflare_api_token_permission_groups.all.zone[
      "Zone Write"
      ],
      data.cloudflare_api_token_permission_groups.all.zone[
      "DNS Read"
      ],
      data.cloudflare_api_token_permission_groups.all.zone[
      "DNS Write"
      ],
      data.cloudflare_api_token_permission_groups.all.account["Email Routing Addresses Read"],
      data.cloudflare_api_token_permission_groups.all.account["Email Routing Addresses Write"],
      data.cloudflare_api_token_permission_groups.all.zone["Email Routing Rules Read"],
      data.cloudflare_api_token_permission_groups.all.zone["Email Routing Rules Write"],
      data.cloudflare_api_token_permission_groups.all.zone[
      "SSL and Certificates Read"
      ],
      data.cloudflare_api_token_permission_groups.all.zone[
      "SSL and Certificates Write"
      ],
      data.cloudflare_api_token_permission_groups.all.zone["Zone Settings Read"],
      data.cloudflare_api_token_permission_groups.all.zone["Zone Settings Write"],
    ]
    resources = {
      "com.cloudflare.api.account.${var.account_id}" = "*"
    }
  }
}

# Get available permission groups
data "cloudflare_api_token_permission_groups" "all" {}
