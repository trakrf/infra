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
  region  = "us-east-1"
  profile = "default"
  # Explicitly use AWS CLI profile to avoid conflict with AWS_* env vars used for R2 backend
}
