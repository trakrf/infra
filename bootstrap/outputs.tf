output "bucket_name" {
  value = cloudflare_r2_bucket.terraform_state.name
}

output "r2_access_key_id" {
  value = cloudflare_api_token.terraform_state.id
}

output "r2_access_key_secret" {
  value     = sha256(cloudflare_api_token.terraform_state.value)
  sensitive = true
}

output "infrastructure_token" {
  value     = cloudflare_api_token.terraform_infrastructure.value
  sensitive = true
}
