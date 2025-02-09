variable "account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "bucket_name" {
  type        = string
  description = "Name of the R2 bucket for terraform state"
  default     = "tf-state"
}
