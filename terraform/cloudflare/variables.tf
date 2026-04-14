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

variable "railway_app_prod_endpoint" {
  type        = string
  description = "Railway endpoint for app subdomain (production)"
  default     = "hlvn5pcb.up.railway.app"
}

variable "eks_nlb_hostname" {
  type        = string
  description = "AWS NLB hostname fronting the EKS Traefik Service (eks.trakrf.app CNAME target)"
}
