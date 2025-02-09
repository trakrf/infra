terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.0.0"

  backend "s3" {
    endpoints = {
      s3 = "https://CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
    }
    bucket = "tf-state"
    key    = "terraform.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}