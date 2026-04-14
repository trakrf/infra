variable "account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "bucket_name" {
  type        = string
  description = "Name of the R2 bucket for terraform state"
  default     = "tf-state"
}

variable "trakrf_app_zone_id" {
  type        = string
  description = "Cloudflare zone ID for trakrf.app, used to scope the cert-manager DNS-01 API token"
}
