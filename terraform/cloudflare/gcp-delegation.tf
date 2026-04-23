# Read Cloud DNS zone outputs from gcp/ module via remote state
data "terraform_remote_state" "gcp" {
  backend = "s3"

  config = {
    endpoints = {
      s3 = "https://${var.account_id}.r2.cloudflarestorage.com"
    }
    bucket = "tf-state"
    key    = "gcp.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true

    profile = "cloudflare-r2"
  }
}

# Create NS records in Cloudflare to delegate gke.trakrf.app to Cloud DNS.
# Delegation lives on the trakrf.app zone, same as azure-delegation.tf.
# Note: google_dns_managed_zone.name_servers is already list(string) — no tolist()
# needed (Azure's output is a set, hence the tolist() in azure-delegation.tf).
resource "cloudflare_record" "gke_subdomain_ns" {
  count = length(data.terraform_remote_state.gcp.outputs.dns_nameservers)

  zone_id = cloudflare_zone.trakrf_app.id
  name    = "gke"
  type    = "NS"
  content = data.terraform_remote_state.gcp.outputs.dns_nameservers[count.index]
  ttl     = 3600

  comment = "Delegate gke.trakrf.app to GCP Cloud DNS"
}
