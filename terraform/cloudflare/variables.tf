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
  # Last NLB before the EKS stack was destroyed; the records still point here.
  # Defaulted so this root plans without it while EKS is deprovisioned.
  default = "a8b4ab4f6dc1044ab89870ce15163b0d-fb4cf2308b034ba3.elb.us-east-2.amazonaws.com"
}

variable "gke_traefik_lb_ip" {
  type        = string
  description = "GKE Traefik LoadBalancer static IP (terraform/gcp google_compute_address.traefik). CF A-record target for app.preview.trakrf.id; prevent_destroy on the GCP side keeps it stable."
  default     = "34.56.243.51"
}
