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

    profile = "cloudflare-r2"
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
