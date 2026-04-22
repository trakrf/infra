# Read Azure DNS zone outputs from azure/ module via remote state
data "terraform_remote_state" "azure" {
  backend = "s3"

  config = {
    endpoints = {
      s3 = "https://${var.account_id}.r2.cloudflarestorage.com"
    }
    bucket = "tf-state"
    key    = "azure.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true

    profile = "cloudflare-r2"
  }
}

# Create NS records in Cloudflare to delegate aks.trakrf.app to Azure DNS.
# Note: delegation lives on the trakrf.app zone (not trakrf.id like aws-delegation.tf).
# tolist() needed because azurerm_dns_zone.name_servers is a set, not a list (differs
# from aws_route53_zone.name_servers which IS a list — hence aws-delegation.tf indexes directly).
locals {
  azure_nameservers = tolist(data.terraform_remote_state.azure.outputs.dns_nameservers)
}

resource "cloudflare_record" "aks_subdomain_ns" {
  count = length(local.azure_nameservers)

  zone_id = cloudflare_zone.trakrf_app.id
  name    = "aks"
  type    = "NS"
  content = local.azure_nameservers[count.index]
  ttl     = 3600

  comment = "Delegate aks.trakrf.app to Azure DNS"
}
