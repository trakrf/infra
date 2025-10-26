variable "domain_name" {
  type        = string
  description = "The domain name to manage"
}

variable "account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "railway_app_preview_endpoint" {
  type        = string
  description = "Railway endpoint for app.preview subdomain"
  default     = "f67wu1p6.up.railway.app"
}
