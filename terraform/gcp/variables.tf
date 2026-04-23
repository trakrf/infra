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

variable "node_machine_type" {
  type        = string
  description = "Machine type for the primary GKE node pool. Default is t2a-standard-4 (ARM Ampere, 4 vCPU / 16 GB). Override to t2a-standard-2 via TF_VAR_node_machine_type in .env.local if T2A quota is tight."
  default     = "t2a-standard-4"
}
