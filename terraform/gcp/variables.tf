variable "project_id" {
  type        = string
  description = "GCP project ID — injected via TF_VAR_project_id in .env.local"
}

variable "region" {
  type        = string
  description = "GCP region for regional resources"
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "GCP zone for zonal resources (phase-2 single-zone pin for CNPG PV affinity, TRA-364 pattern)"
  default     = "us-central1-a"
}

variable "environment" {
  type        = string
  description = "Environment name for labels"
  default     = "demo"
}

variable "project" {
  type        = string
  description = "Project label value (not the GCP project — see project_id)"
  default     = "trakrf"
}

variable "location" {
  type        = string
  description = "Region short code used in resource names (e.g. usc1 for us-central1)"
  default     = "usc1"
}

variable "cluster_name" {
  type        = string
  description = "Name of the GKE cluster (applied in phase 2)"
  default     = "trakrf-demo"
}
